# Local models write six scripts through Qark, two ways:
#   raw:  the model writes every file in full
#   spec: the model writes data plus one template and fans it out with each
# Both go through the same warm Qark worker. A refused apply gets one repair turn
# with Qark's error. Then every script is run and its output compared.
param(
    [string[]]$Models = @("granite4.2:3b", "granite4.2:8b", "granite4.1:3b", "granite4.1:8b"),
    [ValidateSet("report", "validate")][string]$Task = "report",
    [string]$Qark = "",
    [string]$Out = "",
    [string[]]$Modes = @("raw", "spec"),
    [switch]$Rescore
)
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Qark) { $Qark = Join-Path $repo "out\windows-x86_64\release\bin\qark.exe" }
if (-not $Out) { $Out = Join-Path $PSScriptRoot ("spec-vs-raw." + $Task + ".results.json") }
$root = Join-Path $env:TEMP ("qark-svr-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory $root | Out-Null

$tables = [ordered]@{
    users = @("id", "name", "email")
    orders = @("id", "user_id", "total")
    events = @("id", "kind")
    payments = @("id", "order_id", "amount", "currency")
    sessions = @("id", "user_id", "started_at", "ended_at", "ip")
    products = @("id", "sku", "title", "price")
}
$tableText = ($tables.Keys | ForEach-Object { "$($_): " + ($tables[$_] -join ", ") }) -join "`n"
if ($Task -eq "report") {
    $prefix = "report"
    $taskText = @"
Task: write one Python 3 script per table. Each script is named report_<table>.py and prints exactly one line: the table name, one space, and the number of columns the table has.
Tables:
$tableText
"@
} else {
    $prefix = "validate"
    $taskText = @"
Task: for each table, write a Python 3 script named validate_<table>.py that:
- takes the path of a CSV file as its first command-line argument and reads it with the csv module,
- if the header row is not exactly the table's columns in order, prints {"table": "<table>", "error": "bad header"} as JSON and exits with status 1,
- otherwise prints one JSON object {"table": "<table>", "rows": <number of data rows>, "empty": {"<column>": <number of empty cells in that column>, ...}} with every column present in "empty", and exits with status 0.
Use only the standard library (csv, json, sys).
Tables:
$tableText
"@
}

$rawRules = @"
Answer with one JSON object and nothing else, in this shape:
{"files": [{"path": "$($prefix)_users.py", "text": "<the whole script>"}]}
Write every one of the six files in full.
"@

$specRules = @"
You write files through Qark. Answer with one JSON object, a Qark spec, and nothing else.
Put the data in "vars" as a list of objects, write the script once under "templates", and fan it out with "each": one file per item of the list. Each item's fields become variables in the template and the path.
Template syntax: {{name}} inserts a variable; {{list|count}} is the length of a list; {{x|py}} writes x as a Python literal (a string, number, list, or dict). Templates are not code: compute in the generated Python, not inside {{ }}.
Example spec for a different task:
{"vars": {"pets": [{"pet": "cat", "legs": ["fl", "fr", "bl", "br"]}, {"pet": "bird", "legs": ["l", "r"]}]},
 "templates": {"t": "LEGS = {{legs|py}}\nprint({{pet|py}}, len(LEGS))\n"},
 "files": [{"each": "pets", "path": "pet_{{pet}}.py", "template": "t"}]}
"@

$libName = if ($Task -eq "report") { "report/columns.py" } else { "csv/validator.py" }
$libRules = @"
You write files through Qark. A template named "$libName" already exists. It reads two variables: table (the table name) and columns (the list of the table's column names).
Answer with one JSON object, a Qark spec, and nothing else, in exactly this shape with all six tables:
{"vars": {"tables": [{"table": "<name>", "columns": ["<column>", "<column>"]}]},
 "files": [{"each": "tables", "path": "$($prefix)_{{table}}.py", "template": "$libName"}]}
"@

function Ask([string]$model, [string]$prompt) {
    $body = @{
        model = $model; prompt = $prompt; stream = $false; think = $false; format = "json"
        options = @{ temperature = 0; num_predict = 5000; num_ctx = 12288 }
    } | ConvertTo-Json -Depth 6
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:11434/api/generate" -Body $body -ContentType "application/json" -TimeoutSec 900
    $sw.Stop()
    return @{
        text = [string]$r.response
        out_tokens = [int]$r.eval_count
        in_tokens = [int]$r.prompt_eval_count
        model_ms = [Math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        gen_ms = [Math]::Round([double]$r.eval_duration / 1e6, 1)
    }
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $Qark
$psi.Arguments = "--headless --stdio --root `"$root`""
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
$q = [System.Diagnostics.Process]::Start($psi)
$drain = $q.StandardError.ReadToEndAsync()
$q.StandardInput.AutoFlush = $true
$script:rid = 0

function Apply([string]$specText, [string]$job) {
    $spec = $null
    try { $spec = $specText | ConvertFrom-Json } catch { return @{ ok = $false; error = @{ code = "not_json"; message = "the answer was not one JSON object" }; qark_ms = 0 } }
    if ($spec -isnot [System.Management.Automation.PSCustomObject]) { return @{ ok = $false; error = @{ code = "not_object"; message = "the answer must be a JSON object" }; qark_ms = 0 } }
    $spec | Add-Member -NotePropertyName job -NotePropertyValue $job -Force
    $script:rid++
    $req = @{ id = $script:rid; op = "apply"; args = $spec } | ConvertTo-Json -Compress -Depth 30
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $q.StandardInput.WriteLine($req)
    $line = $q.StandardOutput.ReadLine()
    $sw.Stop()
    $r = $line | ConvertFrom-Json
    return @{ ok = [bool]$r.ok; result = $r.result; error = $r.error; qark_ms = [Math]::Round($sw.Elapsed.TotalMilliseconds, 1) }
}

$samples = Join-Path $root "samples"
New-Item -ItemType Directory $samples | Out-Null
$expected = @{}
foreach ($t in $tables.Keys) {
    $cols = $tables[$t]
    $header = $cols -join ","
    $reversed = ($cols[($cols.Count - 1)..0]) -join ","
    $r1 = ($cols | ForEach-Object { "v_$_" }) -join ","
    $r2 = (@(0..($cols.Count - 1)) | ForEach-Object { if ($_ -eq 1) { "" } else { "a$_" } }) -join ","
    $r3 = (@(0..($cols.Count - 1)) | ForEach-Object { if ($_ -eq ($cols.Count - 1)) { "" } else { "b$_" } }) -join ","
    Set-Content -Path (Join-Path $samples "$t.csv") -Value @($header, $r1, $r2, $r3)
    Set-Content -Path (Join-Path $samples "$t.bad.csv") -Value @($reversed, $r1, $r2, $r3)
    $empty = [ordered]@{}
    for ($i = 0; $i -lt $cols.Count; $i++) {
        $n = 0
        if ($i -eq 1) { $n++ }
        if ($i -eq ($cols.Count - 1)) { $n++ }
        $empty[$cols[$i]] = $n
    }
    $expected[$t] = $empty
}

function Score([string]$job) {
    $ErrorActionPreference = "Continue"
    $passed = 0
    foreach ($t in $tables.Keys) {
        $f = Join-Path $root "jobs\$job\$($prefix)_$t.py"
        if (-not (Test-Path $f)) { continue }
        if ($Task -eq "report") {
            $got = (& python $f 2>$null | Out-String).Trim()
            if ($got -eq "$t $($tables[$t].Count)") { $passed++ }
            continue
        }
        $good = (& python $f (Join-Path $samples "$t.csv") 2>$null | Out-String).Trim()
        $goodExit = $LASTEXITCODE
        & python $f (Join-Path $samples "$t.bad.csv") 2>$null | Out-Null
        $badExit = $LASTEXITCODE
        try { $j = $good | ConvertFrom-Json } catch { continue }
        $ok = $goodExit -eq 0 -and $badExit -eq 1 -and $j.table -eq $t -and [int]$j.rows -eq 3
        foreach ($c in $tables[$t]) {
            if ($null -eq $j.empty -or [int]$j.empty.$c -ne $expected[$t][$c]) { $ok = $false }
        }
        if ($ok) { $passed++ }
    }
    return $passed
}

$libText = if ($Task -eq "report") { "print({{table|py}}, {{columns|count}})`n" } else { [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "templates\csv-validator.py.tmpl")) }
$script:rid++
$q.StandardInput.WriteLine((@{ id = $script:rid; op = "template.define"; args = @{ name = $libName; text = $libText } } | ConvertTo-Json -Compress -Depth 5))
$defined = $q.StandardOutput.ReadLine() | ConvertFrom-Json
if (-not $defined.ok) { throw ("template.define refused: " + ($defined | ConvertTo-Json -Compress -Depth 8)) }

$results = @()
if ($Rescore) {
    # apply each saved final answer to a fresh root and score it again; model turns and timings are kept
    $old = Get-Content -Raw $Out | ConvertFrom-Json
    foreach ($row in $old) {
        $job = ($row.model -replace '[^a-zA-Z0-9]', '-') + "-" + $row.mode
        $answers = (Get-Content -Raw (Join-Path $PSScriptRoot ("svr-" + $job + ".txt"))) -split "`n----`n"
        $applied = Apply $answers[$answers.Count - 1].Trim() $job
        $row.scripts_correct = if ($applied.ok) { Score $job } else { 0 }
        Write-Host ("{0,-14} {1,-4} applied={2} correct={3}/{4}" -f $row.model, $row.mode, $applied.ok, $row.scripts_correct, $row.of)
        $results += $row
    }
    $q.StandardInput.Close()
    [void]$q.WaitForExit(5000)
    $results | ConvertTo-Json -Depth 5 | Set-Content -Path $Out
    Remove-Item -Recurse -Force $root
    exit 0
}
foreach ($model in $Models) {
    foreach ($mode in $Modes) {
        $job = ($model -replace '[^a-zA-Z0-9]', '-') + "-" + $mode
        $rules = if ($mode -eq "raw") { $rawRules } elseif ($mode -eq "spec") { $specRules } else { $libRules }
        $prompt = "$taskText`n`n$rules"
        Write-Host "== $model $mode"
        $turns = @()
        $a = Ask $model $prompt
        $applied = Apply $a.text $job
        $turns += @{ ask = $a; apply = $applied }
        if (-not $applied.ok) {
            $err = $applied.error | ConvertTo-Json -Compress -Depth 12
            Write-Host "   refused: $err"
            $repair = "$prompt`n`nYour previous answer:`n$($a.text)`n`nQark refused it with this error:`n$err`nFix the problem and answer with the corrected JSON object only."
            $a2 = Ask $model $repair
            $applied = Apply $a2.text $job
            $turns += @{ ask = $a2; apply = $applied }
        }
        Set-Content -Path (Join-Path $PSScriptRoot ("svr-" + $job + ".txt")) -Value (($turns | ForEach-Object { $_.ask.text }) -join "`n----`n")
        $passed = if ($applied.ok) { Score $job } else { 0 }
        $out_tokens = ($turns | ForEach-Object { $_.ask.out_tokens } | Measure-Object -Sum).Sum
        $model_ms = ($turns | ForEach-Object { $_.ask.model_ms } | Measure-Object -Sum).Sum
        $qark_ms = ($turns | ForEach-Object { $_.apply.qark_ms } | Measure-Object -Sum).Sum
        $row = [ordered]@{
            model = $model; mode = $mode; turns = $turns.Count; first_try = [bool]$turns[0].apply.ok
            applied = [bool]$applied.ok; scripts_correct = $passed; of = $tables.Count
            out_tokens = $out_tokens; model_ms = $model_ms; qark_ms = $qark_ms
            files_written = if ($applied.ok) { [int]$applied.result.created + [int]$applied.result.replaced } else { 0 }
            first_error = if (-not $turns[0].apply.ok) { $turns[0].apply.error.code } else { $null }
        }
        $results += $row
        Write-Host ("   turns={0} applied={1} correct={2}/{3} out_tokens={4} model_ms={5} qark_ms={6}" -f $row.turns, $row.applied, $row.scripts_correct, $row.of, $row.out_tokens, $row.model_ms, $row.qark_ms)
        Set-Content -Path (Join-Path $PSScriptRoot ("svr-" + $job + ".txt")) -Value (($turns | ForEach-Object { $_.ask.text }) -join "`n----`n")
    }
}

$q.StandardInput.Close()
[void]$q.WaitForExit(5000)
$results | ConvertTo-Json -Depth 5 | Set-Content -Path $Out
Write-Host ""
Write-Host "results: $Out"
Remove-Item -Recurse -Force $root
