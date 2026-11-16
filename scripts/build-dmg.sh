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

mkdir -p "$scratch/payload" "$scratch/image" "$output_dir"
app="$scratch/payload/PerfMoon.app"
ditto --norsrc --noextattr --noqtn --noacl \
  "$scratch/DerivedData/Build/Products/Release/PerfMoon.app" "$app"
test ! -e "$app/Contents/_CodeSignature"
info="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")" = PerfMoon
test "$(/usr/bin/lipo -archs "$app/Contents/MacOS/PerfMoon")" = arm64

# Let macOS Installer handle approval of the unsigned package. The installed app
# starts directly as a native process so macOS can register its menu bar item.
components="$scratch/components.plist"
/usr/bin/pkgbuild --analyze --root "$scratch/payload" "$components"
test "$(/usr/libexec/PlistBuddy -c 'Print :0:RootRelativeBundlePath' "$components")" = PerfMoon.app
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$components" 2>/dev/null ||
  /usr/libexec/PlistBuddy -c 'Add :0:BundleIsRelocatable bool false' "$components"
/usr/libexec/PlistBuddy -c 'Set :0:BundleHasStrictIdentifier true' "$components"
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsVersionChecked true' "$components"
/usr/libexec/PlistBuddy -c 'Set :0:BundleOverwriteAction upgrade' "$components"

package="$scratch/image/PerfMoon.pkg"
/usr/bin/pkgbuild --root "$scratch/payload" --component-plist "$components" \
  --install-location /Applications --identifier io.github.yosakikugatsu.PerfMoon \
  --version "$version" --min-os-version 27.0 "$package"
signature_status=$(LC_ALL=C /usr/sbin/pkgutil --check-signature "$package" 2>&1) || true
if [[ "$signature_status" != *'Status: no signature'* ]]; then
  print -u2 -r -- "$signature_status"
  exit 1
fi

image="$output_dir/PerfMoon-$version-arm64.dmg"
hdiutil create -volname PerfMoon -fs HFS+ -format UDZO -imagekey zlib-level=9 \
  -noanyowners -nospotlight -srcfolder "$scratch/image" "$image"
hdiutil verify "$image"
shasum -a 256 "$image"
