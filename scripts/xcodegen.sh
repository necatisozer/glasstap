#!/bin/bash
# Runs XcodeGen: the installed one, or else a pinned release that this script downloads once into
# build/tools and checks against its SHA-256. So a clean Mac needs no Homebrew.
set -eu
cd "$(dirname "$0")/.."

if command -v xcodegen > /dev/null; then exec xcodegen "$@"; fi

VERSION=2.46.0
SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
DIR=build/tools/xcodegen-$VERSION
BIN=$DIR/xcodegen/bin/xcodegen
if [ ! -x "$BIN" ]; then
  echo "Downloading XcodeGen $VERSION…" >&2
  # Stage, then move, so that an interrupted download or unzip never looks installed.
  TMP=$DIR.tmp.$$
  trap 'rm -rf "$TMP"' EXIT
  fail() { echo "$1 Install XcodeGen yourself: brew install xcodegen" >&2; exit 1; }
  mkdir -p "$TMP"
  curl -fsSL -o "$TMP/xcodegen.zip" "https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip" ||
    fail "The XcodeGen download failed."
  [ "$(shasum -a 256 "$TMP/xcodegen.zip" | cut -c1-64)" = "$SHA256" ] || fail "The XcodeGen download has the wrong SHA-256."
  unzip -q "$TMP/xcodegen.zip" -d "$TMP" || fail "The XcodeGen download did not unzip."
  rm -rf "$DIR" && mv "$TMP" "$DIR"
fi
exec "$BIN" "$@"
