# Next test, stage 1: one warm Qark process.
# Checks multi-file job.write receipts, on-disk sha256, distinct refusals,
# and that a blank CR-terminated line does not steal the next reply.
# Stage 2 (not this script): the same session with a live model, split into model_ms and qark_ms.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root
$qark = Join-Path $root "out\windows-x86_64\debug\bin\qark.exe"
if (-not (Test-Path $qark)) { throw "missing $qark" }

$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { Write-Host "ok  $name" }
    else {
        Write-Host "FAIL $name  $detail"
        $script:fail = $script:fail + 1
    }
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $qark
$psi.Arguments = "--headless --stdio"
$psi.WorkingDirectory = $root
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$p = New-Object System.Diagnostics.Process
$p.StartInfo = $psi
[void]$p.Start()
$p.StandardInput.AutoFlush = $true

function Send([string]$json, [int]$timeoutMs) {
    $p.StandardInput.WriteLine($json)
    $task = $p.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($timeoutMs)) { return $null }
    return $task.Result
}

function CodeOf([string]$line) {
    if (-not $line) { return "" }
    $o = $line | ConvertFrom-Json
    if ($o.ok) { return "ok" }
    return [string]$o.error.code
}

$info = Send '{"id":1,"op":"session.info"}' 15000
Check "warm session.info" ($info -match '"ok":true' -and $info -match '"version":"0.2.0"') $info

# a blank CRLF must not produce a reply
$p.StandardInput.Write("`r`n")
$eval = Send '{"id":2,"op":"eval","args":{"src":"(+ 20 22)"}}' 15000
Check "blank line ignored, eval is 42" ($eval -match '"value":42' -or $eval -match '"value": 42') $eval

$job = "next-warm-" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$texts = @{
    "a.py" = "print(110)`n"
    "b.js" = "console.log(110)`n"
    "c.txt" = "three`n"
}
$id = 3
foreach ($name in @("a.py", "b.js", "c.txt")) {
    $text = $texts[$name]
    $payload = @{
        id = $id
        op = "job.write"
        args = @{ root = "jobs"; job = $job; path = $name; text = $text }
    } | ConvertTo-Json -Compress -Depth 6
    $line = Send $payload 15000
    $id = $id + 1
    $obj = $null
    if ($line) { $obj = $line | ConvertFrom-Json }
    $wrote = $obj -and $obj.ok -and $obj.result.sha256 -and ($obj.result.bytes -eq $text.Length)
    Check "write $name" ([bool]$wrote) $line
    if ($wrote) {
        $disk = (Get-FileHash -Algorithm SHA256 $obj.result.path).Hash.ToLower()
        Check "sha256 $name" ($disk -eq [string]$obj.result.sha256) "$disk vs $($obj.result.sha256)"
    }
}

$againPayload = @{
    id = 10
    op = "job.write"
    args = @{ root = "jobs"; job = $job; path = "a.py"; text = "nope" }
} | ConvertTo-Json -Compress -Depth 6
$again = Send $againPayload 15000
Check "second write is job_exists" ((CodeOf $again) -eq "job_exists") $again

$escapePayload = @{
    id = 11
    op = "job.write"
    args = @{ root = "jobs"; job = $job; path = "../x"; text = "no" }
} | ConvertTo-Json -Compress -Depth 6
$escape = Send $escapePayload 15000
Check "escape is job_path" ((CodeOf $escape) -eq "job_path") $escape

$lines = @()
foreach ($i in 1..4097) { $lines += '"a"' }
$many = '{"id":12,"op":"buf.set_lines","args":{"buf":1,"start":0,"end":-1,"lines":[' + ($lines -join ",") + ']}}'
$manyReply = Send $many 20000
Check "4097 lines is too_many_lines" ((CodeOf $manyReply) -eq "too_many_lines") $manyReply

$longLine = "x" * 65537
$longPayload = @{
    id = 13
    op = "buf.set_lines"
    args = @{ buf = 1; start = 0; end = -1; lines = @($longLine) }
} | ConvertTo-Json -Compress -Depth 6
$longReply = Send $longPayload 20000
Check "65537-byte line is line_too_long" ((CodeOf $longReply) -eq "line_too_long") $longReply

$huge = "y" * 262145
$hugePayload = @{
    id = 14
    op = "eval"
    args = @{ src = $huge }
} | ConvertTo-Json -Compress -Depth 6
$hugeReply = Send $hugePayload 20000
Check "262145-byte field is too_long" ((CodeOf $hugeReply) -eq "too_long") $hugeReply

$mid = "(+ 1 2)" + (" " * 5000)
$midPayload = @{ id = 15; op = "eval"; args = @{ src = $mid } } | ConvertTo-Json -Compress -Depth 6
$midReply = Send $midPayload 15000
Check "5000-byte eval is not too_long" ((CodeOf $midReply) -ne "too_long" -and $midReply) $midReply

try { $p.StandardInput.Close() } catch {}
if (-not $p.WaitForExit(3000)) { $p.Kill() }

if ($fail -gt 0) {
    Write-Host "$fail check(s) failed"
    exit 1
}
Write-Host "next-warm stage 1 passed"
exit 0
