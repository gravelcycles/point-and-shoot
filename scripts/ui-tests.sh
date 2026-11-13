#!/bin/bash
# Runs the simulator UI tests on this Mac — same tests as CI, no queue (a few minutes).
#
#   scripts/ui-tests.sh                                   # all UI tests
#   scripts/ui-tests.sh -only-testing:PointAndShootUITests/ControlHitTargetTests/testControlStripOpensDialFromTheEdgeOfTheCell
#
# Full log: build/ui-tests.log. Failure screenshots: open build/UITests.xcresult in Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

# Use Xcode even if xcode-select still points at the Command Line Tools (no sudo needed).
if ! xcodebuild -version >/dev/null 2>&1; then
  XCODE_APP=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$XCODE_APP" ] || { echo "Xcode isn't installed." >&2; exit 1; }
  export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
fi

SIM=$(python3 .github/scripts/pick-simulator.py)
xcrun simctl boot "$SIM" 2>/dev/null || true   # warm it up while we build
mkdir -p build
rm -rf build/UITests.xcresult

set +e
xcodebuild test \
  -project PointAndShoot.xcodeproj -scheme PointAndShoot \
  -destination "id=$SIM" -derivedDataPath build/ui \
  -resultBundlePath build/UITests.xcresult \
  CODE_SIGNING_ALLOWED=NO "$@" 2>&1 | tee build/ui-tests.log \
  | grep -E --line-buffered "error:|Test [Cc]ase .*(passed|failed)|TEST (SUCCEEDED|FAILED)"
set -e
grep -q "TEST SUCCEEDED" build/ui-tests.log
