#!/bin/bash
# Compile check for one longevity worktree: build-for-testing of the app scheme and the package
# scheme against the generic simulator, into one reused DerivedData per worker.
# Run it through the compile queue:
#   ops/ios-build-queue.sh (the Mac's shared compile queue) submit lv-<pkg> \
#     --log /private/tmp/loopr-lv-<pkg>/build.log -- scripts/lv-compile.sh <pkg>
# The lead's focused test phase runs test-without-building against the same DerivedData.
set -euo pipefail
pkg="${1:?usage: scripts/lv-compile.sh <pkg>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
derived="${LOOPR_DERIVED_DATA_PATH:-/private/tmp/loopr-lv-$pkg/dd}"
mkdir -p "$(dirname "$derived")"
common=(-derivedDataPath "$derived" -destination 'generic/platform=iOS Simulator'
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO COMPILER_INDEX_STORE_ENABLE=NO 'OTHER_LDFLAGS=$(inherited) -framework AppIntents' CODE_SIGNING_ALLOWED=NO)
echo "lv-compile: app scheme, DerivedData $derived"
cd "$root"
xcodebuild build-for-testing -project Loopr/Loopr.xcodeproj -scheme Loopr "${common[@]}"
echo "lv-compile: package scheme"
cd "$root/LooprPackages"
xcodebuild build-for-testing -scheme LooprPackages-Package "${common[@]}" ENABLE_APP_INTENTS_METADATA_EXTRACTION=NO
echo "lv-compile: passed"
