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
# `main`, `std.debug`, or `std.Io.Threaded` (see docs/SIZE.md).

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

# Per-target regression budgets: the size measured when they were last set,
# plus about 5%. They are a ratchet, not a goal: a change that goes over
# either earns the bytes (and moves the number here and in check-size.sh,
# saying why) or loses them. The hard ceiling is 1 MB.
#
# Last set for 0.1.0, the rebuilt editor: mouse, focus and bracketed paste on
# Unix, the Pike regex engine, per-pane views, the command table and the
# session format are new code the old budgets (160 to 224 KB) never carried.
#
# aarch64-macos carries one 16 KB page of slack: Apple Silicon links `__TEXT`
# on 16 KB pages, so a few hundred bytes of new code can step the file up by a
# whole page (adding the Unix file stamp moved it 200,616 from 184,200 while
# the x86_64-macos build grew 65 bytes for the same change).
#
# wasm32 is the browser build (`zig build web`), set at 201,252 bytes when
# the web platform was reworked for 0.2.0.
$targets = [ordered]@{
    'x86_64-linux-gnu'   = @{ budget = 208 * $KB; exe = 'mibi' }
    'aarch64-linux-gnu'  = @{ budget = 184 * $KB; exe = 'mibi' }
    'x86_64-macos'       = @{ budget = 220 * $KB; exe = 'mibi' }
    'aarch64-macos'      = @{ budget = 232 * $KB; exe = 'mibi' }
    'x86_64-windows'     = @{ budget = 264 * $KB; exe = 'mibi.exe' }
    'x86_64-windows-gnu' = @{ budget = 264 * $KB; exe = 'mibi.exe' }
    'wasm32'             = @{ budget = 208 * $KB; exe = '..\web\mibi.wasm'; build = @('web') }
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
        $buildArgs = @(if ($spec.build) { $spec.build } else { "-Dtarget=$t" })
        $out = & $Zig build @buildArgs 2>&1
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
