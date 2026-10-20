#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
    printf '%s\n' "These Foundation/runtime tests require macOS." >&2
    exit 1
fi
output="$(mktemp -d)"
trap 'rm -f -- "$output/probe-tests"; rmdir -- "$output"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter \
    -IHeaders -ISources -framework Foundation \
    Tests/ProbeTests.m Sources/AxsAiSiriTrigger.m Sources/AxsAiSiriTranscript.m Sources/AxsAiSiriProbeManager.m \
    -o "$output/probe-tests"
"$output/probe-tests"
