# Run a script and sample the memory of its whole process tree until it exits.
# Prints each process's peak private bytes, peak working set, and peak thread count.
param([Parameter(Mandatory = $true)][string]$Script, [string[]]$ScriptArgs = @(), [int]$IntervalMs = 250)
$ErrorActionPreference = "Stop"
$argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Script) + $ScriptArgs
$top = Start-Process -FilePath "powershell" -ArgumentList $argList -NoNewWindow -PassThru
$peaks = @{}
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$timeline = New-Object System.Collections.Generic.List[string]
while (-not $top.HasExited) {
    $all = Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine
    $tree = @{ $top.Id = $true }
    $grew = $true
    while ($grew) {
        $grew = $false
        foreach ($p in $all) {
            if (-not $tree.ContainsKey([int]$p.ProcessId) -and $tree.ContainsKey([int]$p.ParentProcessId)) {
                $tree[[int]$p.ProcessId] = $true
                $grew = $true
            }
        }
    }
    $total = 0
    foreach ($id in @($tree.Keys)) {
        $gp = Get-Process -Id $id -ErrorAction SilentlyContinue
        if (-not $gp) { continue }
        $total += $gp.PrivateMemorySize64
        $cmd = ($all | Where-Object { $_.ProcessId -eq $id } | Select-Object -First 1).CommandLine
        if (-not $peaks.ContainsKey($id)) { $peaks[$id] = @{ name = $gp.ProcessName; cmd = $cmd; priv = 0; ws = 0; threads = 0 } }
        $e = $peaks[$id]
        if ($gp.PrivateMemorySize64 -gt $e.priv) { $e.priv = $gp.PrivateMemorySize64 }
        if ($gp.WorkingSet64 -gt $e.ws) { $e.ws = $gp.WorkingSet64 }
        if ($gp.Threads.Count -gt $e.threads) { $e.threads = $gp.Threads.Count }
    }
    $timeline.Add(("{0,7:N1}s  tree={1,3} procs  private={2,9:N1} MB" -f $sw.Elapsed.TotalSeconds, $tree.Count, ($total / 1MB)))
    Start-Sleep -Milliseconds $IntervalMs
}
$timeline | Select-Object -Last 1 | Out-Null
Write-Host ""
Write-Host "peak tree total over time (every ~10th sample):"
for ($i = 0; $i -lt $timeline.Count; $i += [Math]::Max(1, [int]($timeline.Count / 25))) { Write-Host $timeline[$i] }
Write-Host ""
Write-Host "per-process peaks:"
$peaks.GetEnumerator() | Sort-Object { $_.Value.priv } -Descending | Select-Object -First 25 | ForEach-Object {
    $c = [string]$_.Value.cmd
    if ($c.Length -gt 90) { $c = $c.Substring(0, 90) }
    Write-Host ("{0,7} {1,-11} private={2,9:N1} MB  ws={3,8:N1} MB  threads={4,4}  {5}" -f $_.Key, $_.Value.name, ($_.Value.priv / 1MB), ($_.Value.ws / 1MB), $_.Value.threads, $c)
}
