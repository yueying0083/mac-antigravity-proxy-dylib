#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-1.0.0}"
VERSION="${VERSION#v}"
ARCH="${ARCH:-$(uname -m)}"
APP="$ROOT/build/Antigravity-Proxy.app"
DIST="$ROOT/dist"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/antigravity-proxy-dmg.XXXXXX")"

cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT

if [[ ! -d "$APP" ]]; then
  echo "Missing $APP. Run ./build.sh first." >&2
  exit 1
fi

mkdir -p "$DIST"
rm -f "$DIST"/*

ZIP_NAME="Antigravity-Proxy-${VERSION}-macos-${ARCH}.zip"
DMG_NAME="Antigravity-Proxy-${VERSION}-macos-${ARCH}.dmg"

ditto -c -k --keepParent "$APP" "$DIST/$ZIP_NAME"

cp -R "$APP" "$STAGE/Antigravity-Proxy.app"
ln -s /Applications "$STAGE/Applications"

created=0
for _ in 1 2 3; do
  if hdiutil create \
    -volname "Antigravity-Proxy" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DIST/$DMG_NAME"; then
    created=1
    break
  fi
  rm -f "$DIST/$DMG_NAME"
  sleep 2
done
if [[ "$created" -ne 1 ]]; then
  echo "Failed to create DMG" >&2
  exit 1
fi

(
  cd "$DIST"
  shasum -a 256 "$ZIP_NAME" "$DMG_NAME" >SHA256SUMS.txt
)

printf 'Packaged:\n'
printf '  %s\n' "$DIST/$ZIP_NAME" "$DIST/$DMG_NAME" "$DIST/SHA256SUMS.txt"
