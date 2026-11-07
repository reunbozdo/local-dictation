"""Local speech-to-text server for Hark. Listens on 127.0.0.1 only: audio never leaves the Mac.

The app starts it with the model picked in Settings and restarts it when the model changes:
    python asr_server.py --engine whisper --repo mlx-community/whisper-large-v3-turbo --terms PATH

POST /transcribe  body: 16 kHz mono 16-bit WAV
                  headers: X-Language (ISO code or "auto"), X-History-Dir (optional: save wav + text there)
                  -> {"text", "raw", "sec", "audio_sec"}
GET  /health      -> {"model": repo} once the model is loaded and warmed up
"""
import argparse, io, json, os, re, sys, threading, time, wave
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

os.environ.setdefault("HF_HUB_OFFLINE", "1")  # the app downloads models; the server never touches the network
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from terms import Terms  # noqa: E402

# MLX is not thread-safe and its streams belong to the thread that made them: the model is loaded
# and every transcription runs on this one worker thread (also queues requests one at a time).
WORKER = ThreadPoolExecutor(max_workers=1)
HISTORY_KEEP = 200

# Whisper's classic inventions on silence/noise (it was trained on subtitled video).
HALLUCINATIONS = re.compile(
    r"(продолжение следует|субтитр\w* (сделал|создавал|делал)|редактор субтитров|спасибо за просмотр|"
    r"подписывайтесь на канал|dimatorzok|thanks? (you )?for watching|subtitles by|"
    r"please subscribe|amara\.org)[^.!?]*[.!?…]*", re.I)


def load_engine(engine, repo):
    """-> run(audio float32 16 kHz, language code or None, prompt str) -> text"""
    if engine == "whisper":
        import mlx_whisper

        def run(audio, lang, prompt):
            return mlx_whisper.transcribe(
                audio, path_or_hf_repo=repo, language=lang, initial_prompt=prompt or None,
                condition_on_previous_text=False,  # long takes: no repetition loops
            )["text"]
        return run
    if engine == "parakeet":
        import mlx.core as mx
        from parakeet_mlx import from_pretrained
        from parakeet_mlx.audio import get_logmel
        model = from_pretrained(repo)

        def run(audio, lang, prompt):  # detects the language itself and takes no prompt
            mel = get_logmel(mx.array(audio), model.preprocessor_config)  # float32: a bf16 input breaks its STFT view
            return model.generate(mel)[0].text
        return run
    if engine == "qwen":
        import mlx_qwen3_asr as q
        model, _ = q.load_model(repo)

        def run(audio, lang, prompt):
            try:
                return q.transcribe(audio, model=model, context=prompt, language=lang).text
            except ValueError:  # a language code Qwen does not know: let it detect
                return q.transcribe(audio, model=model, context=prompt).text
        return run
    raise SystemExit(f"unknown engine {engine}")


def trim_silence(a, sr=16000, frame=0.03, pad=0.5):
    """Cut leading/trailing silence: Whisper tends to invent text in it.
    Threshold sits just above the noise floor: a peak-relative one ate quiet last words."""
    n = int(sr * frame)
    if len(a) < n * 4:
        return a
    rms = np.sqrt(np.mean(a[: len(a) // n * n].reshape(-1, n) ** 2, axis=1))
    loud = np.where(rms > max(0.002, np.percentile(rms, 10) * 3, np.percentile(rms, 95) * 0.02))[0]
    if not len(loud):
        return a[:0]
    s, e = max(0, (loud[0] - int(pad / frame)) * n), min(len(a), (loud[-1] + 1 + int(pad / frame)) * n)
    return a[s:e]


def save_history(folder, wav_bytes, result):
    os.makedirs(folder, exist_ok=True)
    stamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    open(os.path.join(folder, stamp + ".wav"), "wb").write(wav_bytes)
    json.dump(result, open(os.path.join(folder, stamp + ".json"), "w"), ensure_ascii=False, indent=1)
    files = sorted(os.listdir(folder))
    for old in files[: max(0, len(files) - 2 * HISTORY_KEEP)]:
        os.remove(os.path.join(folder, old))


def transcribe(engine, terms, wav_bytes, lang):
    with wave.open(io.BytesIO(wav_bytes)) as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1, "need 16 kHz mono"
        audio = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768
    audio = trim_silence(audio)
    if len(audio) < 16000 * 0.3:
        return dict(text="", raw="", sec=0.0)
    t = time.time()
    lang = None if lang in (None, "", "auto") else lang
    raw = WORKER.submit(engine, audio, lang, terms.prompt()).result().strip()
    text = terms.fix(HALLUCINATIONS.sub("", raw)).strip()
    return dict(text=text, raw=raw, sec=round(time.time() - t, 3), audio_sec=round(len(audio) / 16000, 2))


def make_handler(engine, terms, repo):
    class Handler(BaseHTTPRequestHandler):
        def _json(self, code, obj):
            body = json.dumps(obj, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/health":
                return self._json(200, dict(model=repo))
            self._json(404, {})

        def do_POST(self):
            if self.path != "/transcribe":
                return self._json(404, {})
            data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            try:
                result = transcribe(engine, terms, data, self.headers.get("X-Language"))
            except Exception as e:  # keep the server alive; the app shows the error
                print("transcribe failed:", repr(e), flush=True)
                return self._json(500, dict(error=str(e)))
            print(f"{result['sec']}s for {result.get('audio_sec')}s audio, {len(result['text'])} chars", flush=True)
            self._json(200, result)  # answer first: the user is waiting for the paste
            if result["text"] and self.headers.get("X-History-Dir"):
                save_history(self.headers["X-History-Dir"], data, result)

        def log_message(self, *a):
            pass
    return Handler


def exit_with_parent(parent):
    """The app starts us; if it dies without stopping us, don't sit in memory with a multi-GB model."""
    while os.getppid() == parent:
        time.sleep(2)
    os._exit(0)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--terms", required=True)
    ap.add_argument("--port", type=int, default=47620)
    args = ap.parse_args()
    # Bind before loading the model: a taken port fails in a second, and requests sent
    # during loading wait in the socket backlog instead of failing.
    terms = Terms(args.terms)
    try:
        httpd = ThreadingHTTPServer(("127.0.0.1", args.port), None)
    except OSError as e:
        print("port busy:", e, flush=True)
        sys.exit(3)
    threading.Thread(target=exit_with_parent, args=(os.getppid(),), daemon=True).start()
    engine = WORKER.submit(load_engine, args.engine, args.repo).result()
    WORKER.submit(engine, np.zeros(16000, np.float32), None, "").result()  # warm-up: compiles Metal kernels
    httpd.RequestHandlerClass = make_handler(engine, terms, args.repo)
    print("ready:", args.repo, flush=True)
    httpd.serve_forever()
