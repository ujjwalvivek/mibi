# Builds mibi with the project-local Zig. Arguments go straight to `zig build`.
#   .\build.ps1                      -> zig-out\bin\mibi.exe (ReleaseSmall)
#   .\build.ps1 run                  -> build and start mibi
#   .\build.ps1 -Doptimize=Debug     -> debug build
#   .\build.ps1 -Dtarget=x86_64-linux-gnu
# Zig's caches are kept inside the project too (.zig-cache, .zig-cache-global).

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Zig = Join-Path $Root 'tools\zig\zig.exe'
if (-not (Test-Path $Zig)) {
    Write-Host 'Zig is not installed in tools\zig yet; fetching it first.'
    & (Join-Path $Root 'tools\get-zig.ps1')
}
$env:ZIG_GLOBAL_CACHE_DIR = Join-Path $Root '.zig-cache-global'
Push-Location $Root
try {
    & $Zig build @args
    if ($LASTEXITCODE -ne 0) { throw "zig build failed with exit code $LASTEXITCODE" }
} catch {
    if ($args -notcontains 'test') {
        $exe = Join-Path $Root 'zig-out\bin\mibi.exe'
        if (Test-Path $exe) {
            try {
                [System.IO.File]::OpenWrite($exe).Close()
            } catch {
                Write-Host "note: $exe is in use (mibi is running). Close mibi, then rebuild." -ForegroundColor Yellow
            }
        }
    }
    throw
} finally {
    Pop-Location
}
