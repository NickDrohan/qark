# Time the write layer the way an agent uses it: one warm worker, many applies.
param([string]$Qark = "", [string]$Out = "")
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Qark) { $Qark = Join-Path $repo "out\windows-x86_64\release\bin\qark.exe" }
$root = Join-Path $env:TEMP ("qark-bench-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory $root | Out-Null

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $Qark
$psi.Arguments = "--headless --stdio --root `"$root`""
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$p = [System.Diagnostics.Process]::Start($psi)
$drain = $p.StandardError.ReadToEndAsync()
$p.StandardInput.AutoFlush = $true
$script:id = 0

function Call([string]$op, $argsObj) {
    $script:id++
    $req = @{ id = $script:id; op = $op; args = $argsObj } | ConvertTo-Json -Compress -Depth 20
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p.StandardInput.WriteLine($req)
    $line = $p.StandardOutput.ReadLine()
    $sw.Stop()
    $r = $line | ConvertFrom-Json
    if (-not $r.ok) { throw ("refused: " + $line) }
    return @{ wall = $sw.Elapsed.TotalMilliseconds; r = $r }
}

function Stats([string]$name, [object[]]$runs) {
    $walls = @($runs | ForEach-Object { $_.wall } | Sort-Object)
    $checks = @($runs | ForEach-Object { if ($_.r.result.ms) { [double]$_.r.result.ms.check } else { 0 } } | Sort-Object)
    $commits = @($runs | ForEach-Object { if ($_.r.result.ms) { [double]$_.r.result.ms.commit } else { 0 } } | Sort-Object)
    $n = $walls.Count
    $p50 = $walls[[int][Math]::Floor(($n - 1) * 0.5)]
    $p95 = $walls[[int][Math]::Floor(($n - 1) * 0.95)]
    $row = [ordered]@{
        case = $name; n = $n
        wall_p50 = [Math]::Round($p50, 2); wall_p95 = [Math]::Round($p95, 2)
        check_p50 = [Math]::Round($checks[[int][Math]::Floor(($n - 1) * 0.5)], 2)
        commit_p50 = [Math]::Round($commits[[int][Math]::Floor(($n - 1) * 0.5)], 2)
    }
    Write-Host ("{0,-34} n={1,3}  wall p50={2,8} p95={3,8}  check p50={4,8}  commit p50={5,7} ms" -f $row.case, $row.n, $row.wall_p50, $row.wall_p95, $row.check_p50, $row.commit_p50)
    return $row
}

$rows = @()
[void](Call "session.info" @{})

$runs = 1..30 | ForEach-Object { Call "apply" @{ path = "txt/n$_.txt"; text = "note $_`n" } }
$rows += Stats "create 1 text file" $runs
$runs = 1..30 | ForEach-Object { Call "apply" @{ path = "txt/n$_.txt"; text = "note $_`n" } }
$rows += Stats "same apply again (unchanged)" $runs
$runs = 1..20 | ForEach-Object { Call "apply" @{ path = "py/m$_.py"; text = "def f$_(x):`n    return x * $_`n" } }
$rows += Stats "create 1 python file, checked" $runs
$runs = 1..10 | ForEach-Object { Call "apply" @{ path = "js/m$_.js"; text = "module.exports = (x) => x * $_;`n" } }
$rows += Stats "create 1 node file, checked" $runs
$runs = 1..5 | ForEach-Object { Call "apply" @{ path = "ps/m$_.ps1"; text = "Write-Output $_`n" } }
$rows += Stats "create 1 powershell file, checked" $runs
$runs = 1..10 | ForEach-Object { $k = $_; Call "apply" @{ files = @(1..10 | ForEach-Object { @{ path = "batch$k/f$_.py"; text = "X = $_`n" } }) } }
$rows += Stats "create 10 python files in one apply" $runs
$tables = @(1..50 | ForEach-Object { @{ table = "t$_"; key = "id" } })
$tmpl = "TABLE = {{table|py}}`nKEY = {{key|py}}`n`n`ndef rows(conn):`n    return conn.execute(`"select * from `" + TABLE).fetchall()`n"
$runs = 1..5 | ForEach-Object { $k = $_; Call "apply" @{ vars = @{ tables = $tables }; templates = @{ t = $tmpl }; files = @(@{ each = "tables"; path = "fan$k/{{table}}.py"; template = "t" }) } }
$rows += Stats "fan 1 template to 50 python files" $runs
$runs = 1..5 | ForEach-Object { $k = $_; Call "apply" @{ check = $false; vars = @{ tables = $tables }; templates = @{ t = $tmpl }; files = @(@{ each = "tables"; path = "nofan$k/{{table}}.py"; template = "t" }) } }
$rows += Stats "fan to 50 files, check off" $runs
$runs = 1..20 | ForEach-Object { Call "apply" @{ path = "py/m1.py"; edits = @(@{ find = "x * 1"; replace = "x * 1 + $_" }) } }
$rows += Stats "find/replace edit, checked" $runs
$runs = 1..30 | ForEach-Object { Call "read" @{ path = "py/m$((($_ - 1) % 20) + 1).py" } }
$rows += Stats "read 1 file with sha256" $runs
$big = ("x = 1`n" * 20000)
$runs = 1..5 | ForEach-Object { Call "apply" @{ check = $false; path = "big/b$_.py"; text = $big } }
$rows += Stats "create 117 KB file, check off" $runs

$p.StandardInput.Close()
[void]$p.WaitForExit(5000)
Remove-Item -Recurse -Force $root
if ($Out) { $rows | ConvertTo-Json -Depth 4 | Set-Content -Path $Out }
