"""Dictionary file -> spelling hint for the model + post-fix of the recognised text.

Two mechanisms, both driven by the same file:
1. Every term goes into the model prompt, so the model already leans to the right spelling.
2. Latin terms (GitHub, PS5, macOS) are normalised after recognition: any case, Cyrillic
   look-alike letters and stray spaces/hyphens ("Git Hub", "ps-5", "РS5") collapse to the
   spelling in the file. "a => b" lines are plain replacements on top.
"""
import os
import re

# Latin letter -> Cyrillic letters a model may write instead (look-alikes; for codes also by sound).
# Matters for Russian/Ukrainian speech with English terms; harmless for other languages.
LOOKALIKE = {"a": "а", "b": "в", "c": "с", "e": "е", "h": "н", "k": "к", "m": "м", "o": "о",
             "p": "р", "t": "т", "x": "х", "y": "у"}
SOUND = {"a": "аэ", "b": "б", "d": "д", "f": "ф", "g": "г", "i": "иа", "k": "к", "l": "л",
         "n": "н", "p": "п", "q": "к", "r": "р", "s": "с", "t": "т", "u": "ю", "v": "в",
         "w": "в", "z": "з"}
LATIN = re.compile(r"[A-Za-z]")
CODE = re.compile(r"^[A-Za-z]+\d+$")  # PS5, app1


def _letter(ch, code):
    alts = {ch.lower(), ch.upper(), *LOOKALIKE.get(ch.lower(), "")}
    if code:
        alts.update(SOUND.get(ch.lower(), ""))
    alts = {a for c in alts for a in (c.lower(), c.upper())}
    return "[" + "".join(sorted(alts)) + "]"


def _pattern(term):
    code = bool(CODE.match(term))
    parts = []
    for i, ch in enumerate(term):
        if ch == " ":
            parts.append(r"[\s\-]*")  # "Git Hub" / "GitHub", "level-editor"
            continue
        if i and term[i - 1].isalpha() != ch.isalpha() and term[i - 1] != " ":
            parts.append(r"[\s\-]?")  # "PS 5", "app-1"
        elif i and ch.isupper() and term[i - 1].islower():
            parts.append(r"[\s\-]?")  # camel case: "Git Hub" -> GitHub
        parts.append(_letter(ch, code) if ch.isalpha() else re.escape(ch))
    return re.compile(r"(?<!\w)" + "".join(parts) + r"(?!\w)")


class Terms:
    def __init__(self, path):
        self.path = path
        self.mtime = None
        self.terms, self.rules, self.fixers = [], [], []
        self.load()

    def load(self):
        try:
            mtime = os.path.getmtime(self.path)
        except OSError:
            self.terms, self.rules, self.fixers, self.mtime = [], [], [], None
            return
        if mtime == self.mtime:
            return
        self.mtime = mtime
        self.terms, self.rules = [], []
        for line in open(self.path, encoding="utf-8"):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=>" in line:
                src, dst = (s.strip() for s in line.split("=>", 1))
                self.rules.append((re.compile(r"(?<!\w)" + re.escape(src) + r"(?!\w)", re.I), dst))
            else:
                self.terms.append(line)
        self.fixers = [(_pattern(t), t) for t in self.terms if LATIN.search(t)]

    def prompt(self):
        """Plain comma list: a language-neutral hint (a prefix like "Terms:" would push Whisper to English)."""
        self.load()
        return ", ".join(self.terms) + "." if self.terms else ""

    def fix(self, text):
        self.load()
        for rx, dst in self.rules:
            text = rx.sub(dst, text)
        for rx, term in self.fixers:
            text = rx.sub(term, text)
        return text


if __name__ == "__main__":  # quick self-check: python server/terms.py
    t = Terms(os.path.join(os.path.dirname(__file__), "..", "terms.example.txt"))
    for s in ["Push it to git hub and check Github Actions.", "Залей на Гит Хаб и GITHUB.",
              "Run cube control get pods on kubernetes.", "Обнови МacOS и postgresql."]:
        print(s, "->", t.fix(s))
    print(t.prompt())
