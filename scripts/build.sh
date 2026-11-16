#!/bin/zsh
# SPDX-FileCopyrightText: 2026 YosakiKugatsu
# SPDX-License-Identifier: GPL-3.0-only

# Builds PerfMoon with Xcode and copies the app to build/.
# Usage: scripts/build.sh [debug|release]   (default: release)
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIG_NAME="${1:-release}"
case "$CONFIG_NAME" in
  debug|Debug) CONFIG=Debug ;;
  release|Release) CONFIG=Release ;;
  *) echo "usage: scripts/build.sh [debug|release]" >&2; exit 64 ;;
esac

DERIVED="$ROOT/build/DerivedData"
PRODUCT="$DERIVED/Build/Products/$CONFIG/PerfMoon.app"
if [[ "$CONFIG" == Release ]]; then
  DEST="$ROOT/build/PerfMoon.app"
else
  DEST="$ROOT/build/Debug/PerfMoon.app"
fi

mkdir -p "$ROOT/build/logs"
BUILD_LOG="$ROOT/build/logs/$CONFIG.log"
if xcodebuild \
  -project "$ROOT/PerfMoon.xcodeproj" \
  -scheme PerfMoon \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS,arch=arm64' \
  build > "$BUILD_LOG" 2>&1; then
  grep -E "error:|warning:|\*\* BUILD" "$BUILD_LOG" || true
else
  BUILD_STATUS=$?
  tail -n 100 "$BUILD_LOG"
  exit "$BUILD_STATUS"
fi

if [[ ! -d "$PRODUCT" ]]; then
  echo "Build failed: $PRODUCT not found" >&2
  exit 1
fi

# Only ever replaces the copy inside build/, never an installed app.
mkdir -p "${DEST:h}"
rm -rf "$DEST"
ditto "$PRODUCT" "$DEST"
if [[ "${PERFMOON_QA_PROFILE:-0}" == 1 ]]; then
  python3 - "$DEST/Contents/Info.plist" "$ROOT/build/logs/$CONFIG-runtime.jsonl" <<'PY'
import plistlib,sys
from pathlib import Path
path=Path(sys.argv[1])
info=plistlib.loads(path.read_bytes())
info['LSEnvironment']={'PERFMOON_DIAGNOSTICS_PATH':sys.argv[2]}
path.write_bytes(plistlib.dumps(info))
PY
fi
# Sign the final copied bundle in both normal and QA builds.
codesign --force --sign - "$DEST"
codesign --verify --deep "$DEST"
echo "Built $CONFIG: $DEST"
