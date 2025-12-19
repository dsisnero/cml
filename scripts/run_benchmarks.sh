#!/usr/bin/env bash
set -euo pipefail

# Simple benchmark runner that executes all Crystal benchmarks under benchmarks/
# and saves outputs under perf/baseline-<timestamp>/.

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTDIR="perf/baseline-${TIMESTAMP}"
mkdir -p "$OUTDIR"

# Environment for lower-noise runs
export CRYSTAL_WORKERS=1

# Crystal build flags for more realistic performance
CR_FLAGS=(--release --no-debug)

shopt -s nullglob
for file in benchmarks/*.cr; do
  name=$(basename "$file" .cr)
  outfile="$OUTDIR/${name}.txt"
  echo "Running $file -> $outfile"
  { time crystal run "$file" "${CR_FLAGS[@]}"; } |& tee "$outfile"
  echo
  echo "Saved: $outfile"
  echo "----------------------------------------"
  echo
done

# Summarize outputs
ls -la "$OUTDIR"
