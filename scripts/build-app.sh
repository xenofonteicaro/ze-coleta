#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
release_version="${VERSION:-0.1.0-alpha.1}"
if [[ ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9][a-zA-Z0-9.-]*)?$ ]]; then
  echo "Invalid VERSION." >&2
  exit 64
fi
architecture="${COLETA_ARCHS:-universal}"
if [[ "$architecture" == "native" ]]; then architecture="$(uname -m)"; fi
case "$architecture" in
  universal) arch_args=(--arch arm64 --arch x86_64) ;;
  arm64|x86_64) arch_args=(--arch "$architecture") ;;
  *) echo "COLETA_ARCHS must be native, universal, arm64 or x86_64." >&2; exit 64 ;;
esac
# Extra SwiftPM arguments remain an argv array. Homebrew passes --disable-sandbox
# for SwiftPM's nested manifest sandbox; Homebrew's outer sandbox stays active.
swift build --configuration release --product ZeColeta --jobs 2 "${arch_args[@]}" "$@"
binary_directory="$(swift build --configuration release --show-bin-path "${arch_args[@]}" "$@")"
mkdir -p "$project_root/build"
staging="$(mktemp -d "$project_root/build/stage.XXXXXX")"
app="$staging/Zé Coleta.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/ZeColeta" "$app/Contents/MacOS/ZeColeta"
strip -S "$app/Contents/MacOS/ZeColeta"
cp packaging/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${release_version%%-*}" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :ZeColetaReleaseVersion $release_version" "$app/Contents/Info.plist"
swift scripts/GenerateIcon.swift "$staging/AppIcon.iconset"
iconutil -c icns "$staging/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  if [[ "$DEVELOPER_ID_APPLICATION" != "Developer ID Application:"* ]]; then
    echo "Distribution requires a Developer ID Application identity." >&2
    exit 64
  fi
  codesign --force --sign "$DEVELOPER_ID_APPLICATION" --options runtime --timestamp "$app"
else
  codesign --force --sign - --timestamp=none "$app"
fi
codesign --verify --strict "$app"
if [[ -e "$project_root/build/Zé Coleta.app" ]]; then
  mv "$project_root/build/Zé Coleta.app" "$project_root/build/Zé Coleta.previous.$(date +%s).app"
fi
mv "$app" "$project_root/build/Zé Coleta.app"
archive="$project_root/build/Ze-Coleta-$release_version-$architecture.zip"
if [[ -e "$archive" ]]; then mv "$archive" "$archive.previous.$(date +%s)"; fi
ditto -c -k --sequesterRsrc --keepParent "$project_root/build/Zé Coleta.app" "$archive"
(cd "$project_root/build" && shasum -a 256 "$(basename "$archive")") > "$archive.sha256"
"$project_root/build/Zé Coleta.app/Contents/MacOS/ZeColeta" --version
printf 'App: %s\nArchive: %s\n' "$project_root/build/Zé Coleta.app" "$archive"
