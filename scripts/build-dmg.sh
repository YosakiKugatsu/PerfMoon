#!/bin/zsh
# SPDX-FileCopyrightText: 2026 YosakiKugatsu
# SPDX-License-Identifier: GPL-3.0-only

# Usage: build-dmg.sh <PerfMoon source directory> [output directory]
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
  print -u2 'Usage: build-dmg.sh <PerfMoon source directory> [output directory]'
  exit 64
fi

source_dir=${1:A}
output_dir=${2:-$PWD/build}
test -f "$source_dir/PerfMoon.xcodeproj/project.pbxproj"

scratch=$(mktemp -d /tmp/perfmoon-dmg-build.XXXXXXXX)
trap 'rm -rf -- "$scratch"' EXIT
if ! xcodebuild -project "$source_dir/PerfMoon.xcodeproj" -scheme PerfMoon \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$scratch/DerivedData" CODE_SIGNING_ALLOWED=NO build \
  > "$scratch/build.log" 2>&1; then
  tail -n 80 "$scratch/build.log"
  exit 1
fi

mkdir -p "$scratch/image" "$output_dir"
app="$scratch/image/PerfMoon.app"
ditto --norsrc --noextattr --noqtn --noacl \
  "$scratch/DerivedData/Build/Products/Release/PerfMoon.app" "$app"
test ! -e "$app/Contents/_CodeSignature"

# Apple silicon needs the native executable's link-time signature. An unsigned
# launcher lets Gatekeeper treat the unsigned bundle as from an unidentified
# developer rather than as a signed bundle with a missing resource seal.
cat > "$app/Contents/MacOS/LaunchPerfMoon" <<'EOF'
#!/bin/sh
exec "${0%/*}/PerfMoon" "$@"
EOF
chmod 755 "$app/Contents/MacOS/LaunchPerfMoon"
info="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable LaunchPerfMoon' "$info"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")
ln -s /Applications "$scratch/image/Applications"

image="$output_dir/PerfMoon-$version-arm64.dmg"
hdiutil create -volname PerfMoon -fs HFS+ -format UDZO -imagekey zlib-level=9 \
  -noanyowners -nospotlight -srcfolder "$scratch/image" "$image"
hdiutil verify "$image"
shasum -a 256 "$image"
