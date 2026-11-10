#!/bin/bash
# ------------------------------------------------------------------
#  SPEED APP - one-click LIVE APK
#  Double-click this file in Finder (or run ./build-apk.command).
#
#  Builds a release APK that talks to the live Railway server,
#  saves it in the "apk" folder with the version and date in the
#  name, and shows it in Finder.
# ------------------------------------------------------------------

API_URL="https://speedapp-production.up.railway.app"
OUT_DIR="apk"

cd "$(dirname "$0")" || exit 1

step()  { echo; echo "==> $1"; }
pause() { echo; read -r -p "Press Enter to close..." _; }
fail()  { echo; echo "FAILED: $1"; pause; exit 1; }

echo "SPEED APP - build the live APK"
echo "Server: $API_URL"

# --- Flutter SDK ---------------------------------------------------
FLUTTER="$(command -v flutter 2>/dev/null)"
if [ -z "$FLUTTER" ]; then
  SDK="$(grep '^flutter.sdk=' android/local.properties 2>/dev/null | cut -d= -f2-)"
  for f in "$SDK/bin/flutter" "$HOME/flutter/bin/flutter" "$HOME/development/flutter/bin/flutter" \
           "/opt/homebrew/bin/flutter" "/usr/local/bin/flutter"; do
    if [ -x "$f" ]; then FLUTTER="$f"; break; fi
  done
fi
[ -n "$FLUTTER" ] || fail "Flutter was not found. Install it or add it to your PATH."
echo "Flutter: $FLUTTER"

# --- Checks (warnings only) ----------------------------------------
if ! grep -qE '^MAPS_API_KEY=.+' android/local.properties 2>/dev/null; then
  echo "WARNING: MAPS_API_KEY is missing in android/local.properties - the map will be grey."
fi
if curl -fsS -m 8 "$API_URL/health" 2>/dev/null | grep -q '"ok":true'; then
  echo "Live server: OK"
else
  echo "WARNING: the live server did not answer $API_URL/health right now."
  echo "         The APK will still be built; the app works offline and syncs later."
fi

# --- Build ---------------------------------------------------------
step "Building the release APK (this takes a few minutes)"
"$FLUTTER" build apk --release --dart-define=API_URL="$API_URL" \
  || fail "flutter build apk failed - read the log above."

SRC="build/app/outputs/flutter-apk/app-release.apk"
[ -f "$SRC" ] || fail "The APK was not found at $SRC"

VERSION="$(grep '^version:' pubspec.yaml | awk '{print $2}')"
VERSION="${VERSION/+/-build}"
NAME="SpeedAlert-v${VERSION}-live-$(date '+%Y%m%d-%H%M').apk"
mkdir -p "$OUT_DIR"
cp "$SRC" "$OUT_DIR/$NAME" || fail "Could not copy the APK."

echo
echo "DONE - live APK ready:"
echo "  $(pwd)/$OUT_DIR/$NAME  ($(du -h "$OUT_DIR/$NAME" | cut -f1))"
[ "$(uname)" = "Darwin" ] && open -R "$OUT_DIR/$NAME"
pause
