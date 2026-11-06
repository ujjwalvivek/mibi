# mibi size gate.
#
# Builds the editor for every release target and fails when an artifact grows
# past its budget. This is the Phase 0 promise ("measure everything") turned
# into something that runs on demand and in CI.
#
#   .\tools\check-size.ps1              # build every target, then check
#   .\tools\check-size.ps1 -NoBuild     # check whatever is already in zig-out
#
# A budget jump almost always means a size trap crept back in: a fallible
# `main`, `std.debug`, or `std.Io.Threaded` (see experiments/README.md).

[CmdletBinding()]
param([switch]$NoBuild)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Zig = Join-Path $Root 'tools\zig\zig.exe'
$env:ZIG_GLOBAL_CACHE_DIR = Join-Path $Root '.zig-cache-global'
$KB = 1024
$HardCeiling = 1024 * $KB

if (-not (Test-Path $Zig)) {
    & (Join-Path $Root 'tools\get-zig.ps1')
}

# Per-target regression budgets, re-measured after Phase 4 (splits) with ~15%
# headroom. Phase gates from PLAN.md: Phase 1 <= 80 KB, Phase 2 <= 150 KB,
# Phase 3 <= 350 KB, Phase 4 <= 700 KB, hard ceiling 1 MB (every target is far
# below it).
$targets = [ordered]@{
    'x86_64-linux-gnu'   = @{ budget = 144 * $KB; exe = 'mibi' }
    'aarch64-linux-gnu'  = @{ budget = 144 * $KB; exe = 'mibi' }
    'x86_64-macos'       = @{ budget = 176 * $KB; exe = 'mibi' }
    'aarch64-macos'      = @{ budget = 176 * $KB; exe = 'mibi' }
    'x86_64-windows'     = @{ budget = 208 * $KB; exe = 'mibi.exe' }
    'x86_64-windows-gnu' = @{ budget = 208 * $KB; exe = 'mibi.exe' }
}

$rows = @()
$failed = $false
foreach ($t in $targets.Keys) {
    $spec = $targets[$t]
    $exe = Join-Path $Root (Join-Path 'zig-out\bin' $spec.exe)

    if (-not $NoBuild) {
        # Never measure a stale artifact from an earlier target.
        if (Test-Path $exe) {
            try {
                Remove-Item $exe -Force
            } catch {
                Write-Host "cannot remove $exe (is mibi running?)" -ForegroundColor Red
                $failed = $true
                continue
            }
        }
        $out = & $Zig build "-Dtarget=$t" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "BUILD FAILED: $t" -ForegroundColor Red
            $out | Select-Object -Last 8 | ForEach-Object { Write-Host "  $_" }
            $failed = $true
            continue
        }
    }

    if (-not (Test-Path $exe)) {
        Write-Host "MISSING: $exe (run without -NoBuild)" -ForegroundColor Red
        $failed = $true
        continue
    }

    $size = (Get-Item $exe).Length
    $over = ($size -gt $spec.budget) -or ($size -gt $HardCeiling)
    if ($over) { $failed = $true }
    $rows += [pscustomobject]@{
        Target   = $t
        Bytes    = $size
        KB       = [math]::Round($size / $KB, 1)
        BudgetKB = [math]::Round($spec.budget / $KB, 0)
        Status   = if ($over) { 'OVER' } else { 'ok' }
    }
}

if ($rows.Count -gt 0) {
    $rows | Format-Table -AutoSize | Out-String | Write-Host
}

if ($failed) {
    Write-Host "size gate: FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "size gate: ok - every artifact is under its budget (hard ceiling $([math]::Round($HardCeiling / $KB, 0)) KB)" -ForegroundColor Green
exit 0
