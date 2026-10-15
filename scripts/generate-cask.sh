#!/bin/bash
set -euo pipefail
if [[ "$#" -ne 2 ]]; then echo "Usage: generate-cask.sh VERSION UNIVERSAL_ZIP" >&2; exit 64; fi
release_version="$1"
if [[ ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9][a-zA-Z0-9.-]*)?$ ]]; then
  echo "Invalid version." >&2; exit 64
fi
archive="$2"
if [[ "$(basename "$archive")" != "Ze-Coleta-$release_version-universal.zip" ]]; then
  echo "The input must be the universal ZIP for this exact release." >&2; exit 64
fi
digest="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
cat <<RUBY
cask "ze-coleta" do
  version "$release_version"
  sha256 "$digest"

  url "https://github.com/xenofonteicaro/ze-coleta/releases/download/v#{version}/Ze-Coleta-#{version}-universal.zip"
  name "Zé Coleta"
  desc "Local cleanup and application uninstaller"
  homepage "https://github.com/xenofonteicaro/ze-coleta"

  depends_on macos: :sonoma

  app "Zé Coleta.app"
end
RUBY
