#!/bin/bash
set -euo pipefail
if [[ "$#" -ne 2 ]]; then echo "Usage: generate-formula.sh VERSION SOURCE_ARCHIVE" >&2; exit 64; fi
release_version="$1"
if [[ ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9][a-zA-Z0-9.-]*)?$ ]]; then
  echo "Invalid version." >&2; exit 64
fi
digest="$(shasum -a 256 "$2" | cut -d ' ' -f 1)"
source_url="https://github.com/xenofonteicaro/ze-coleta/archive/refs/tags/v$release_version.tar.gz"
if [[ -n "${SOURCE_REVISION:-}" ]]; then
  if [[ ! "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]]; then echo "Invalid SOURCE_REVISION." >&2; exit 64; fi
  source_url="https://github.com/xenofonteicaro/ze-coleta/archive/$SOURCE_REVISION.tar.gz"
fi
cat <<RUBY
class ZeColeta < Formula
  desc "Local macOS cleanup and application uninstaller"
  homepage "https://github.com/xenofonteicaro/ze-coleta"
  url "$source_url"
  version "$release_version"
  sha256 "$digest"
  license "MIT"

  depends_on xcode: ["16.0", :build]
  depends_on macos: :sonoma

  def install
    ENV["COLETA_ARCHS"] = "native"
    ENV["VERSION"] = version.to_s
    system "bash", "scripts/build-app.sh"
    prefix.install "build/Zé Coleta.app"
    (bin/"ze-coleta").write <<~SH
      #!/bin/bash
      set -e
      if [ "\$#" -gt 0 ]; then
        exec "#{prefix}/Zé Coleta.app/Contents/MacOS/ZeColeta" "\$@"
      fi
      exec /usr/bin/open "#{prefix}/Zé Coleta.app"
    SH
  end

  def caveats
    <<~EOS
      Run ze-coleta to open Zé Coleta.
      The app is built locally from source; no Developer ID certificate is required.
      Files move to macOS Trash only after you review and confirm your selection.
    EOS
  end

  test do
    assert_match "Zé Coleta #{version}", shell_output("#{bin}/ze-coleta --version")
    assert_path_exists prefix/"Zé Coleta.app/Contents/Info.plist"
  end
end
RUBY
