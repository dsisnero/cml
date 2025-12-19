#!/usr/bin/env pwsh
# Cross-platform benchmark runner for Windows PowerShell
# - Enumerates benchmarks/*.cr
# - Runs each with --release --no-debug and CRYSTAL_WORKERS=1
# - Writes output to perf/baseline-<timestamp>/<name>.txt and mirrors to console

$ErrorActionPreference = "Stop"

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outdir = Join-Path "perf" ("baseline-" + $stamp)
New-Item -ItemType Directory -Force -Path $outdir | Out-Null

$env:CRYSTAL_WORKERS = "1"

Write-Host "Benchmark run: $stamp"
Write-Host "CRYSTAL_WORKERS=$($env:CRYSTAL_WORKERS)"
Write-Host "Output dir: $outdir"
Write-Host

$files = Get-ChildItem -Path "benchmarks" -Filter "*.cr" -ErrorAction Stop | Sort-Object Name
if ($files.Count -eq 0) {
  Write-Error "No benchmarks found under benchmarks/."
  exit 1
}

foreach ($f in $files) {
  $name = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
  $outfile = Join-Path $outdir ("$name.txt")
  Write-Host "Running $($f.FullName) -> $outfile"

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  # Use Tee-Object to mirror to file and console
  $cmd = "crystal run `"$($f.FullName)`" --release --no-debug"
  try {
    # Start-Process with redirection loses console output; prefer Invoke-Expression and Tee-Object
    Invoke-Expression $cmd 2>&1 | Tee-Object -FilePath $outfile
    $sw.Stop()
    Add-Content -Path $outfile -Value ("`n-- elapsed: {0} ms" -f [math]::Round($sw.Elapsed.TotalMilliseconds, 3))
    Write-Host "Saved: $outfile"
    Write-Host "----------------------------------------"
  }
  catch {
    Write-Error "Benchmark failed: $($f.FullName)"
    throw
  }
}

Write-Host
Write-Host "Artifacts in $outdir:"
Get-ChildItem $outdir | ForEach-Object { Write-Host "- $($_.Name)" }
