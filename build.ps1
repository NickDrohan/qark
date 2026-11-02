# build both profiles, run the unit tests and the write-layer suite, and refresh the reference dumps
$ErrorActionPreference = "Stop"
$env:PATH = "$env:LOCALAPPDATA\mach\bin;" + $env:PATH
Set-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)

foreach ($dir in @("out\windows-x86_64\debug\bin", "out\windows-x86_64\release\bin")) {
    Get-ChildItem -Path $dir -Filter "*.old" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    foreach ($bin in @("qark.exe", "qa.exe")) {
        $exe = Join-Path $dir $bin
        if (Test-Path $exe) {
            Move-Item $exe "$exe.$PID.old" -Force -ErrorAction SilentlyContinue
            Remove-Item "$exe.$PID.old" -Force -ErrorAction SilentlyContinue
        }
    }
}

mach build . -a qark -a qa
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
mach build . -a qark -a qa --profile release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
mach test .
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$qark = ".\out\windows-x86_64\release\bin\qark.exe"
New-Item -ItemType Directory -Force -Path "agent\reference" | Out-Null
& $qark --dump ops  | Set-Content -Encoding utf8 "agent\reference\ops.txt"
& $qark --dump keys | Set-Content -Encoding utf8 "agent\reference\keys.txt"
& $qark --dump lisp | Set-Content -Encoding utf8 "agent\reference\lisp.txt"

Get-Content "agent\examples\smoke.ndjson" | & $qark --headless --stdio
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& powershell -NoProfile -ExecutionPolicy Bypass -File "agent\eval\apply-suite.ps1" -Qark $qark
exit $LASTEXITCODE