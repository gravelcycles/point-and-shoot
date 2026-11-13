#!/bin/bash
# Builds Point & Shoot (app + Control/Lock Screen extensions), signs it with your Apple ID,
# installs it on a USB/Wi-Fi-connected iPhone and launches it.
#
#   scripts/deploy-iphone.sh                     # auto-detects team and the one connected iPhone
#   TEAM=ABCDE12345 DEVICE=<udid> scripts/deploy-iphone.sh
#   BUNDLE_ID=com.yourname.pointandshoot scripts/deploy-iphone.sh   # if the default ID is taken
#   CONFIG=Debug scripts/deploy-iphone.sh        # default Release (what "smooth" should feel like)
#
# BUNDLE_ID sets the project's APP_BUNDLE_ID, so the extensions become $BUNDLE_ID.widgets and
# $BUNDLE_ID.lockedcapture. Never override PRODUCT_BUNDLE_IDENTIFIER: the extensions would get the app's ID.
#
# One-time, by hand (Claude can't do these):
#   • Xcode → Settings → Accounts → add your Apple ID (free works; apps then expire after 7 days).
#   • iPhone: Settings → Privacy & Security → Developer Mode → On (it restarts). Trust this Mac when asked.
#   • After the first install: iPhone Settings → General → VPN & Device Management → trust your developer cert.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-Release}"
BUNDLE_ID="${BUNDLE_ID:-io.github.gravelcycles.pointandshoot}"
DERIVED="build/device"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Use Xcode even if xcode-select still points at the Command Line Tools (no sudo needed).
if ! xcodebuild -version >/dev/null 2>&1; then
  XCODE_APP=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$XCODE_APP" ] || die "Xcode isn't installed. Get it from the Mac App Store, open it once, then re-run."
  export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
  xcodebuild -version >/dev/null 2>&1 || die "Xcode at $XCODE_APP isn't set up yet. Open it once (it installs components
and asks you to accept the license), then re-run."
fi
XCV=$(xcodebuild -version | head -1 | awk '{print $2}')
[ "${XCV%%.*}" -ge 16 ] || die "Xcode $XCV is too old; the project needs Xcode 16 or newer."
say "Xcode $XCV"

# --- Team ID -------------------------------------------------------------------------------------
if [ -z "${TEAM:-}" ]; then
  # Teams of the Apple IDs added in Xcode → Settings → Accounts (prefers a paid team).
  TEAM=$(defaults export com.apple.dt.Xcode - 2>/dev/null | python3 -c '
import plistlib, sys
try:
    prefs = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit()
teams = []
for key in ("IDEProvisioningTeamByIdentifier", "IDEProvisioningTeams"):
    for account in (prefs.get(key) or {}).values():
        teams += [t for t in account if isinstance(t, dict) and t.get("teamID")]
teams.sort(key=lambda t: bool(t.get("isFreeProvisioningTeam")))
print(teams[0]["teamID"] if teams else "")' || true)
fi
if [ -z "${TEAM:-}" ]; then
  # Fallback: the OU field of an "Apple Development" certificate is the team ID.
  TEAM=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)
fi
if [ -z "${TEAM:-}" ]; then
  die "No signing team found. Add your Apple ID in Xcode → Settings → Accounts and re-run.
Or pass it explicitly: TEAM=ABCDE12345 $0"
fi
say "Team $TEAM"

# --- Device --------------------------------------------------------------------------------------
if [ -z "${DEVICE:-}" ]; then
  JSON=$(mktemp)
  xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || true
  DEVICE=$(python3 - "$JSON" <<'PY'
import json, sys
try:
    devs = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devs = []
phones = [d for d in devs
          if d.get("hardwareProperties", {}).get("platform") == "iOS"
          and d.get("connectionProperties", {}).get("pairingState") == "paired"]
connected = [d for d in phones if d.get("connectionProperties", {}).get("tunnelState") in ("connected", "available")] or phones
for d in connected:
    print(d["hardwareProperties"]["udid"], d.get("deviceProperties", {}).get("name", "?"), sep="\t", file=sys.stderr)
print(connected[0]["hardwareProperties"]["udid"] if len(connected) == 1 else "")
PY
)
  rm -f "$JSON"
  [ -n "$DEVICE" ] || die "Couldn't pick exactly one paired iPhone (see list above, if any). Plug it in, unlock it,
tap Trust, enable Developer Mode, or pass DEVICE=<udid> (xcrun devicectl list devices)."
fi
say "Device $DEVICE"

# --- Build & sign --------------------------------------------------------------------------------
say "Building PointAndShoot ($CONFIG) as $BUNDLE_ID"
mkdir -p "$DERIVED"
LOG="$DERIVED/deploy-build.log"
xcodebuild -project PointAndShoot.xcodeproj -scheme PointAndShoot -configuration "$CONFIG" \
  -destination "id=$DEVICE" -derivedDataPath "$DERIVED" \
  DEVELOPMENT_TEAM="$TEAM" APP_BUNDLE_ID="$BUNDLE_ID" CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates build 2>&1 | tee "$LOG" | scripts/pretty.sh \
  || die "Build failed (full log: $LOG)"

APP="$DERIVED/Build/Products/$CONFIG-iphoneos/PointAndShoot.app"
[ -d "$APP" ] || die "Build produced no app at $APP"

# --- Install & launch ----------------------------------------------------------------------------
say "Installing"
xcrun devicectl device install app --device "$DEVICE" "$APP"
say "Launching"
if ! xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"; then
  echo
  echo "Installed, but iOS refused to launch it. If this is the first install from this Apple ID:"
  echo "  iPhone → Settings → General → VPN & Device Management → (your Apple ID) → Trust, then open Point & Shoot."
fi
say "Done. Allow Camera, Microphone, Photos and Location when asked."
say "Lock Screen camera: hold the Lock Screen → Customize → Lock Screen → tap a bottom button → Point & Shoot."
