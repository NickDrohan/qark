# Ask local Ollama models for scripts, write them through Qark, then run them.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root
$qark = Join-Path $root "out\windows-x86_64\debug\bin\qark.exe"
$py = "C:\Program Files\Python37\python.exe"

function Get-Script([string]$model, [string]$prompt) {
    $body = @{
        model = $model
        prompt = $prompt
        stream = $false
        think = $false
        options = @{ temperature = 0; num_predict = 500 }
    } | ConvertTo-Json -Depth 5
    $r = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:11434/api/generate" -Body $body -ContentType "application/json"
    $text = [string]$r.response
    $text = $text -replace '(?s)^.*?```(?:python|py|powershell|ps1|javascript|js)?\s*', ''
    $text = $text -replace '(?s)```.*$', ''
    return $text.Trim()
}

$pyPrompt = @"
Write a Python 3 script and nothing else. No markdown, no explanation.
Define double_sum(n) that returns 2 * sum(range(1, n + 1)).
End with:
if __name__ == '__main__':
    print(double_sum(10))
"@

$psPrompt = @"
Write a PowerShell script and nothing else. No markdown, no explanation.
It must print only the integer 110, which is 2 * (1+2+...+10).
Use Write-Output.
"@

$jsPrompt = @"
Write a Node.js script and nothing else. No markdown, no explanation.
Define function doubleSum(n) that returns 2 * the sum of integers from 1 through n.
End with: console.log(doubleSum(10));
"@

$jobs = @(
    @{ model = "granite4.2:3b"; id = "granite42-3b"; file = "double_sum.py"; kind = "python"; prompt = $pyPrompt },
    @{ model = "granite4.2:8b"; id = "granite42-8b"; file = "double_sum.py"; kind = "python"; prompt = $pyPrompt },
    @{ model = "granite4.1:3b"; id = "granite41-3b"; file = "print_total.ps1"; kind = "powershell"; prompt = $psPrompt },
    @{ model = "granite4.1:8b"; id = "granite41-8b"; file = "double_sum.js"; kind = "javascript"; prompt = $jsPrompt }
)

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('{"id":1,"op":"session.info"}')
$lines.Add('{"id":2,"op":"eval","args":{"src":"(* 2 55)"}}')
$lines.Add('{"id":3,"op":"validate.ident","args":{"lang":"python","name":"double_sum"}}')

$i = 4
$meta = @()
foreach ($job in $jobs) {
    Write-Host "MODEL $($job.model)"
    $src = Get-Script $job.model $job.prompt
    $srcPath = Join-Path $root ("agent\eval\raw-" + $job.id + ".txt")
    Set-Content -Encoding utf8 -Path $srcPath -Value $src
    Write-Host $src
    Write-Host "----"
    $req = @{
        id = $i
        op = "job.write"
        args = @{
            root = "jobs"
            job = $job.id
            path = $job.file
            text = $src
        }
    }
    $lines.Add(($req | ConvertTo-Json -Compress -Depth 6))
    $meta += @{ id = $job.id; file = $job.file; kind = $job.kind; req = $i }
    $i = $i + 1
}

$nd = Join-Path $root "agent\eval\ollama-qark.ndjson"
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllLines($nd, $lines.ToArray(), $utf8)

Write-Host "QARK"
$reply = Get-Content -Raw $nd | & $qark --headless --stdio
$reply | Set-Content -Encoding utf8 (Join-Path $root "agent\eval\ollama-qark.reply.ndjson")
Write-Host $reply

Write-Host "RUN"
foreach ($m in $meta) {
    $path = Join-Path $root ("jobs\" + $m.id + "\" + $m.file)
    Write-Host "FILE $path"
    if (-not (Test-Path $path)) {
        Write-Host "MISSING"
        continue
    }
    if ($m.kind -eq "python") {
        & $py -m py_compile $path
        Write-Host "py_compile $LASTEXITCODE"
        & $py $path
        Write-Host "run $LASTEXITCODE"
    } elseif ($m.kind -eq "powershell") {
        powershell -NoProfile -File $path
        Write-Host "run $LASTEXITCODE"
    } else {
        node --check $path
        Write-Host "node_check $LASTEXITCODE"
        node $path
        Write-Host "run $LASTEXITCODE"
    }
}
