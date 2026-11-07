#!/bin/bash
# Build Local Dictation.app into build/ and install it to ~/Applications.
# The app remembers this repo path (Info.plist AppRoot) to find .venv, server/ and models.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Local Dictation.app"

# Signing identity: a local self-signed cert in its own keychain (not the login one).
# macOS ties Accessibility/Microphone grants to the designated requirement; with an ad-hoc
# signature that is the cdhash, so every rebuild lost the grant. With this cert it is
# `identifier "io.github.localdictation" and certificate leaf = <cert>`, the same for every build.
SIGN_DIR="$HOME/Library/Application Support/Local Dictation/signing"
KC="$SIGN_DIR/signing.keychain-db"
CERT_NAME="Local Dictation Signing"

make_identity() {
    echo "Creating local signing identity in $KC"
    mkdir -p "$SIGN_DIR"; chmod 700 "$SIGN_DIR"
    local tmp; tmp="$(mktemp -d)"
    # The password only guards this keychain; the file is readable by this user only.
    (umask 077; /usr/bin/openssl rand -hex 24 > "$SIGN_DIR/password")
    cat > "$tmp/req.cnf" <<EOF
[req]
distinguished_name=dn
prompt=no
[dn]
CN=$CERT_NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
    # /usr/bin/openssl (LibreSSL): its PKCS#12 is what `security import` understands.
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$tmp/req.cnf" -extensions ext \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout pass:p
    security create-keychain -p "$(cat "$SIGN_DIR/password")" "$KC"
    security set-keychain-settings "$KC"  # no auto-lock
    security unlock-keychain -p "$(cat "$SIGN_DIR/password")" "$KC"
    security import "$tmp/id.p12" -k "$KC" -P p -T /usr/bin/codesign >/dev/null
    # Let codesign use the key without a "codesign wants to access…" dialog.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat "$SIGN_DIR/password")" "$KC" >/dev/null
    rm -rf "$tmp"
}

[ -f "$KC" ] || make_identity
security unlock-keychain -p "$(cat "$SIGN_DIR/password")" "$KC"
CERT_SHA1="$(security find-certificate -c "$CERT_NAME" -Z "$KC" | awk '/SHA-1/ {print $3}')"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -o "$APP/Contents/MacOS/LocalDictation" "$ROOT"/app/*.swift
cp "$ROOT"/assets/compiled/{Assets.car,AppIcon.icns} "$APP/Contents/Resources/"  # from assets/compile_icon.sh
sed "s#__ROOT__#$ROOT#" "$ROOT/app/Info.plist" > "$APP/Contents/Info.plist"

# codesign only finds identities in the user's keychain search list: add ours for the
# duration of the signing and put the original list back (even on failure).
ORIG_LIST=()
while IFS= read -r k; do ORIG_LIST+=("$k"); done < <(security list-keychains -d user | sed -E 's/^ *"(.*)"$/\1/')
restore_list() { security list-keychains -d user -s "${ORIG_LIST[@]}"; }
trap restore_list EXIT
security list-keychains -d user -s "${ORIG_LIST[@]}" "$KC"
codesign --force --sign "$CERT_SHA1" --identifier io.github.localdictation "$APP"
restore_list; trap - EXIT

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Local Dictation.app"
cp -R "$APP" "$HOME/Applications/Local Dictation.app"
echo "Installed: $HOME/Applications/Local Dictation.app ($(codesign -d -r- "$APP" 2>&1 | tail -1 | sed 's/^designated => //'))"
