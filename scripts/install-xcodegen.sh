#!/bin/bash
set -euo pipefail
archive="$RUNNER_TEMP/meea-xcodegen.zip"
tool_dir="$RUNNER_TEMP/meea-xcodegen-tool"
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --connect-timeout 20 --max-time 180 --retry 2 --output "$archive" \
  https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip
echo "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806  $archive" | shasum -a 256 --check
unzip -q "$archive" -d "$tool_dir"
"$tool_dir/xcodegen/bin/xcodegen" generate
