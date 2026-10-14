# Confirm a warm checker answers one line, then exits when left idle with stdin still open.
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$py = "C:\Program Files\Python37\python.exe"
$node = "C:\Program Files\nodejs\node.exe"
$payload = '[{"name":"a","text":"x = 1\n"}]'

function Test-Idle([string]$name, [string]$file, [string]$argLine) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $file
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.AutoFlush = $true
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p.StandardInput.WriteLine($payload)
    $task = $p.StandardOutput.ReadLineAsync()
    $got = $task.Wait(8000)
    $reply = if ($got) { $task.Result } else { "NO REPLY" }
    $exited = $p.WaitForExit(6000)
    Write-Host ("{0,-12} reply={1} idle_exit={2} {3:N1}s" -f $name, $reply.Substring(0, [Math]::Min(20, $reply.Length)), $exited, $sw.Elapsed.TotalSeconds)
    if (-not $exited) { $p.Kill(); [void]$p.WaitForExit(2000) }
    if (-not $got -or -not $exited) { exit 1 }
}

Test-Idle "python" $py "scripts\checkers\check.py --serve 1"
Test-Idle "node" $node "scripts\checkers\check.js --serve 1"
Test-Idle "powershell" "powershell" "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File scripts\checkers\check.ps1 -serve -idle 1"

$scratch = Join-Path $env:TEMP "qark-idle"
if (Test-Path $scratch) { Remove-Item -Recurse -Force $scratch }
New-Item -ItemType Directory $scratch | Out-Null
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "d:\Dev\Qark\out\windows-x86_64\debug\bin\qark.exe"
$psi.Arguments = "--headless --stdio --root `"$scratch`""
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$q = [System.Diagnostics.Process]::Start($psi)
$q.StandardInput.AutoFlush = $true
$q.StandardInput.WriteLine('{"id":1,"op":"apply","args":{"path":"a.py","text":"print(1)\n"}}')
$line = $q.StandardOutput.ReadLine()
Write-Host "apply $($line.Contains('"ok":true'))"
Start-Sleep -Seconds 4
$kids = @(Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $q.Id })
Write-Host ("children after idle: " + (($kids | ForEach-Object { $_.Name }) -join ", "))
$q.StandardInput.WriteLine('{"id":2,"op":"apply","args":{"path":"b.js","text":"module.exports = 1\n"}}')
$line2 = $q.StandardOutput.ReadLine()
Write-Host "second $($line2.Contains('"ok":true'))"
$q.StandardInput.Close()
if (-not $q.WaitForExit(8000)) { $q.Kill() }
Start-Sleep -Seconds 3
$left = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'check\.(py|js|ps1)' })
Write-Host "checkers left: $($left.Count)"
Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
if ($kids.Count -ne 0 -or $left.Count -ne 0) { exit 1 }
exit 0
