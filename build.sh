#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
app_path="${1:-"$project_dir/dist/Lid Angle Recorder.app"}"

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
xcrun --sdk macosx clang \
  -fobjc-arc -Wall -Werror -mmacosx-version-min=12.0 \
  -arch x86_64 -arch arm64 \
  "-ffile-prefix-map=$project_dir=." \
  "$project_dir/src/main.m" \
  -framework Cocoa -framework IOKit \
  -o "$app_path/Contents/MacOS/LidAngleRecorder"
cp "$project_dir/assets/Info.plist" "$app_path/Contents/Info.plist"
cp "$project_dir/assets/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
cp "$project_dir/LICENSE" "$app_path/Contents/Resources/LICENSE"
codesign --force --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
printf 'Built: %s\n' "$app_path"
