# Time the operations an agent waits on. One warm Qark process, plus cold starts.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root
$qark = Join-Path $root "out\windows-x86_64\debug\bin\qark.exe"

function Start-Qark {
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
    return $p
}

function Invoke-Qark([System.Diagnostics.Process]$p, [string]$json, [int]$timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p.StandardInput.WriteLine($json)
    $task = $p.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($timeoutMs)) {
        $sw.Stop()
        return @{ ms = $sw.Elapsed.TotalMilliseconds; line = "TIMEOUT"; ok = $false }
    }
    $sw.Stop()
    $line = $task.Result
    $ok = $line -match '"ok":true'
    return @{ ms = $sw.Elapsed.TotalMilliseconds; line = $line; ok = $ok }
}

function Get-Stats([double[]]$xs) {
    $sorted = @($xs | Sort-Object)
    $n = $sorted.Count
    if ($n -eq 0) { return $null }
    function At([double]$q) {
        $i = [Math]::Min($n - 1, [Math]::Max(0, [int][Math]::Ceiling($q * $n) - 1))
        return $sorted[$i]
    }
    $sum = 0.0
    foreach ($x in $sorted) { $sum += $x }
    return @{
        n = $n
        min = [Math]::Round($sorted[0], 2)
        p50 = [Math]::Round((At 0.50), 2)
        p95 = [Math]::Round((At 0.95), 2)
        max = [Math]::Round($sorted[$n - 1], 2)
        mean = [Math]::Round($sum / $n, 2)
    }
}

function Show-Stats([string]$name, $stats) {
    Write-Host ("{0,-28} n={1,3}  min={2,8}  p50={3,8}  p95={4,8}  max={5,8}  mean={6,8} ms" -f $name, $stats.n, $stats.min, $stats.p50, $stats.p95, $stats.max, $stats.mean)
}

$cold = @()
foreach ($i in 1..8) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Qark
    $r = Invoke-Qark $p '{"id":1,"op":"session.info"}' 15000
    $sw.Stop()
    $cold += $sw.Elapsed.TotalMilliseconds
    try { $p.StandardInput.Close() } catch {}
    if (-not $p.WaitForExit(3000)) { $p.Kill() }
    if (-not $r.ok) { Write-Host "COLD FAIL $($r.line)" }
}
Show-Stats "cold session.info" (Get-Stats $cold)

$p = Start-Qark
$warmStart = Invoke-Qark $p '{"id":1,"op":"session.info"}' 15000
Write-Host ("warm process first reply {0} ms ok={1}" -f ([Math]::Round($warmStart.ms, 2)), $warmStart.ok)

function Sample([string]$name, [string]$json, [int]$n, [int]$timeoutMs) {
    $xs = @()
    $fails = 0
    foreach ($i in 1..$n) {
        $r = Invoke-Qark $p $json $timeoutMs
        $xs += $r.ms
        if (-not $r.ok) { $fails++; if ($fails -eq 1) { Write-Host "FAIL $name $($r.line)" } }
    }
    Show-Stats $name (Get-Stats $xs)
    if ($fails -gt 0) { Write-Host "  failures $fails / $n" }
}

Sample "session.info" '{"id":10,"op":"session.info"}' 80 5000
Sample "validate.ident" '{"id":11,"op":"validate.ident","args":{"lang":"python","name":"double_sum"}}' 40 5000
Sample "eval (* 2 55)" '{"id":12,"op":"eval","args":{"src":"(* 2 55)"}}' 40 5000

$create = Invoke-Qark $p '{"id":20,"op":"buf.create","args":{"name":"bench.py","filetype":"python"}}' 5000
Write-Host "buf.create $($create.ms) ms $($create.line)"

$small = '{"id":21,"op":"buf.set_lines","args":{"buf":2,"start":0,"end":-1,"lines":["def double_sum(n):","    return n * 2",""]}}'
Sample "set_lines 3" $small 30 5000

$many = @()
foreach ($i in 1..60) { $many += "line $i = $i" }
$payload = @{ id = 22; op = "buf.set_lines"; args = @{ buf = 2; start = 0; end = -1; lines = $many } } | ConvertTo-Json -Compress -Depth 5
Sample "set_lines 60" $payload 15 8000

$tooMany = @()
foreach ($i in 1..80) { $tooMany += "x" }
$payload80 = @{ id = 23; op = "buf.set_lines"; args = @{ buf = 2; start = 0; end = -1; lines = $tooMany } } | ConvertTo-Json -Compress -Depth 5
$cap = Invoke-Qark $p $payload80 8000
Write-Host ("set_lines 80 (cap 64) {0} ms {1}" -f ([Math]::Round($cap.ms, 2)), $cap.line)

$long = "x" * 5000
$bigField = @{ id = 24; op = "eval"; args = @{ src = $long } } | ConvertTo-Json -Compress -Depth 4
$big = Invoke-Qark $p $bigField 8000
Write-Host ("eval 5000-byte src {0} ms {1}" -f ([Math]::Round($big.ms, 2)), $big.line.Substring(0, [Math]::Min(120, $big.line.Length)))

$keys = '{"id":30,"op":"keys.feed","args":{"keys":"ggdGiprint(110)<Esc>"}}'
Sample "keys.feed short" $keys 15 8000

$stamp = Get-Date -Format "HHmmss"
foreach ($n in @(200, 3000)) {
    $text = "print(110)`n" + ("# pad`n" * [Math]::Floor($n / 7))
    $req = @{ id = 40; op = "job.write"; args = @{ root = "jobs"; job = "bench-$stamp-$n"; path = "main.py"; text = $text } } | ConvertTo-Json -Compress -Depth 5
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Qark $p $req 8000
    $sw.Stop()
    Write-Host ("job.write ~{0} bytes {1} ms ok={2} {3}" -f $text.Length, ([Math]::Round($r.ms, 2)), $r.ok, $r.line)
}

try { $p.StandardInput.Close() } catch {}
if (-not $p.WaitForExit(3000)) { $p.Kill() }
Write-Host "done"
