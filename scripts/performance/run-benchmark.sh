#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h:h}"
PERF_TEMP="$(mktemp -d /private/tmp/pasteboard-performance.XXXXXX)"
trap 'rm -rf "$PERF_TEMP"' EXIT
cd "$ROOT"
swiftc -O -module-cache-path "$PERF_TEMP/ModuleCache" Sources/PasteCore/*.swift scripts/performance/FingerprintBenchmark.swift -o "$PERF_TEMP/benchmark"
"$PERF_TEMP/benchmark"
