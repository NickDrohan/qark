# Deterministic checks of the write layer, through one warm ndjson worker and one mcp server.
# Each check prints ok or FAIL with the reply; the script exits 1 if any check failed.
param([string]$Qark = "")
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Qark) { $Qark = Join-Path $repo "out\windows-x86_64\debug\bin\qark.exe" }
$root = Join-Path $env:TEMP ("qark-suite-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory $root | Out-Null

$script:fail = 0
$script:count = 0
$script:drains = @()
function Check([string]$name, [bool]$ok, $detail) {
    $script:count++
    if ($ok) { Write-Host "ok   $name" }
    else {
        Write-Host "FAIL $name"
        Write-Host ("     " + ($detail | ConvertTo-Json -Compress -Depth 12))
        $script:fail++
    }
}

function Start-Worker([string[]]$argv) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Qark
    $psi.Arguments = ($argv -join " ")
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $script:drains += $p.StandardError.ReadToEndAsync()
    $p.StandardInput.AutoFlush = $true
    return $p
}

function Read-Reply($proc, [string]$sent) {
    $task = $proc.StandardOutput.ReadLineAsync()
    if (-not $task.Wait(60000)) { throw "no reply within 60 s to: $sent" }
    return $task.Result
}

$w = Start-Worker @("--headless", "--stdio", "--root", "`"$root`"")
$script:id = 0
function Q([string]$op, $argsObj) {
    $script:id++
    $req = @{ id = $script:id; op = $op; args = $argsObj } | ConvertTo-Json -Compress -Depth 20
    $w.StandardInput.WriteLine($req)
    return ((Read-Reply $w $req) | ConvertFrom-Json)
}

$info = Q "session.info" @{}
Check "session.info is 0.3.0 at the root" ($info.ok -and $info.result.version -eq "0.3.0" -and ($info.result.features -contains "ast_symbol_edits") -and $info.result.root -like "*qark-suite-*") $info

$r = Q "apply" @{ path = "notes/a.txt"; text = "alpha`n" }
Check "single file create" ($r.ok -and $r.result.created -eq 1 -and $r.result.files[0].status -eq "created") $r
$sha_a = $r.result.files[0].sha256
$disk = (Get-FileHash -Algorithm SHA256 (Join-Path $root "notes\a.txt")).Hash.ToLower()
Check "receipt sha256 matches disk" ($disk -eq $sha_a) @{ disk = $disk; receipt = $sha_a }

$r = Q "apply" @{ path = "notes/a.txt"; text = "alpha`n" }
Check "same request again is unchanged" ($r.ok -and $r.result.unchanged -eq 1) $r

$r = Q "apply" @{ path = "notes/a.txt"; text = "beta`n" }
Check "create over different content is a conflict" ((-not $r.ok) -and $r.error.code -eq "conflict" -and $r.error.files[0].reason -eq "exists" -and $r.error.files[0].current_sha256 -eq $sha_a) $r

$r = Q "apply" @{ path = "notes/a.txt"; text = "beta`n"; mode = "replace"; expect = ("0" * 64) }
Check "stale expect is refused" ((-not $r.ok) -and $r.error.files[0].reason -eq "stale") $r

$rd = Q "read" @{ path = "notes/a.txt" }
Check "read returns text and sha256" ($rd.ok -and $rd.result.files[0].text -eq "alpha`n" -and $rd.result.files[0].sha256 -eq $sha_a) $rd

$r = Q "apply" @{ path = "notes/a.txt"; text = "beta`n"; mode = "replace"; expect = $sha_a }
Check "replace with the read sha256" ($r.ok -and $r.result.replaced -eq 1 -and $r.result.files[0].prev_sha256 -eq $sha_a) $r

$code = "def total(xs):`n    s = 0`n    for x in xs:`n        s = s + x`n    return s`n`n`ndef count(xs):`n    return len(xs)`n"
$r = Q "apply" @{ path = "src/calc.py"; text = $code }
Check "python file passes its check" ($r.ok -and $r.result.files[0].check -eq "ok") $r

$r = Q "apply" @{ path = "src/calc.py"; edits = @(@{ find = "s = s + x"; replace = "s += x" }) }
Check "exact find/replace edit" ($r.ok -and $r.result.replaced -eq 1) $r
$r = Q "apply" @{ path = "src/calc.py"; edits = @(@{ find = "return"; replace = "yield" }) }
Check "ambiguous find names its lines" ((-not $r.ok) -and $r.error.code -eq "edit_ambiguous" -and $r.error.message -like "*lines 5 9*") $r
$r = Q "apply" @{ path = "src/calc.py"; edits = @(@{ find = "  for x in xs:`n      s += x"; replace = "x" }) }
Check "near miss points at the first line" ((-not $r.ok) -and $r.error.code -eq "edit_not_found" -and $r.error.line -eq 3) $r
$r = Q "apply" @{ path = "src/calc.py"; edits = @(@{ find = "s  += x"; replace = "s = s + x" }) }
Check "an extra space still names the line" ((-not $r.ok) -and $r.error.code -eq "edit_not_found" -and $r.error.line -eq 4 -and $r.error.message -like "*extra spaces*") $r
$r = Q "apply" @{ path = "src/calc.py"; edits = @(@{ lines = @(8, 9); with = @("def count(xs):", "    return sum(1 for _ in xs)") }, @{ insert_after = 0; with = "`"`"`"Small math helpers.`"`"`"" }) }
Check "line range and insert edits" ($r.ok -and $r.result.files[0].check -eq "ok") $r
$r = Q "apply" @{ path = "src/calc.py"; edits = @(@{ ex = "%s/xs/items/g" }, @{ keys = "Gdd" }) }
Check "an edit that breaks the syntax is refused" ((-not $r.ok) -and $r.error.code -eq "check_failed" -and $r.error.files[0].check_message -like "*EOF*") $r
$r = Q "apply" @{ path = "src/calc.py"; edits = @(@{ ex = "%s/xs/items/g" }, @{ keys = "ggdd" }) }
Check "vim ex and keys edits" ($r.ok) $r
$now = [System.IO.File]::ReadAllText((Join-Path $root "src\calc.py"))
Check "edits produced the expected file" ($now.StartsWith("def total(items):") -and $now.Contains("s += x") -and $now.Contains("return sum(1 for _ in items)")) @{ text = $now }
$r = Q "apply" @{ path = "src/calc.py"; edits = @(@{ ex = "w C:\escape.txt" }) }
Check "ex write is refused inside an edit" ((-not $r.ok) -and $r.error.code -eq "edit_ex") $r
$r = Q "apply" @{ path = "src/calc.py"; edits = @(@{ keys = ":e C:\Windows\win.ini<CR>" }) }
Check "keys cannot reach :e" ((-not $r.ok) -or ((Get-Content -Raw (Join-Path $root "src\calc.py")) -notlike "*fonts*")) $r

$r = Q "apply" @{ path = "count.txt"; text = "ab`n" }
$r = Q "apply" @{ path = "count.txt"; edits = @(@{ keys = "3ix<Esc>" }) }
$countText = [System.IO.File]::ReadAllText((Join-Path $root "count.txt"))
Check "a count repeats the insert" ($r.ok -and $countText -eq "xxxab`n") @{ text = $countText }
$r = Q "apply" @{ path = "count.txt"; edits = @(@{ keys = "10001x" }) }
$afterHuge = [System.IO.File]::ReadAllText((Join-Path $root "count.txt"))
Check "a count above 10000 is refused" ((-not $r.ok) -and $r.error.code -eq "edit_count" -and $afterHuge -eq $countText) $r

$gate = "param([string]`$Path)`n`$t = Get-Content -Raw -LiteralPath `$Path`nif (`$t -match 'BAD') { [Console]::Error.WriteLine('rejected'); exit 1 }`nexit 0`n"
$r = Q "apply" @{ path = "gate.ps1"; text = $gate }
Check "the project gate script is accepted" ($r.ok) $r
New-Item -ItemType Directory -Force -Path (Join-Path $root ".qark") | Out-Null
@{ dat = @("powershell", "-NoProfile", "-File", "gate.ps1") } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $root ".qark\checks.json")
$r = Q "apply" @{ path = "sample.dat"; text = "BAD`n" }
Check "a project checker can refuse a write" ((-not $r.ok) -and $r.error.code -eq "check_failed" -and -not (Test-Path (Join-Path $root "sample.dat"))) $r
$r = Q "apply" @{ path = "sample.dat"; text = "ok`n" }
Check "a project checker can accept a write" ($r.ok -and $r.result.files[0].check -eq "ok" -and $r.result.files[0].lang -eq "dat") $r
$gateRoot = "param([string]`$Root)`n`$p = Join-Path `$Root 'staged.mach'`n`$t = ''`nif (Test-Path -LiteralPath `$p) { `$t = Get-Content -Raw -LiteralPath `$p }`nif (`$t -match 'BAD') { [Console]::Error.WriteLine('rejected'); exit 1 }`nexit 0`n"
$r = Q "apply" @{ path = "gate-root.ps1"; text = $gateRoot }
Check "the staged gate script is accepted" ($r.ok) $r
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $root ".qark\checks.json"), '{"dat":["powershell","-NoProfile","-File","gate.ps1"],"mach":["powershell","-NoProfile","-File","gate-root.ps1","{root}"]}', $utf8)
$r = Q "apply" @{ path = "staged.mach"; text = "OLD`n"; mode = "upsert" }
Check "a root checker accepts a write" ($r.ok -and ([System.IO.File]::ReadAllText((Join-Path $root "staged.mach")) -eq "OLD`n")) $r
$r = Q "apply" @{ path = "staged.mach"; text = "BAD`n"; mode = "upsert" }
$stagedNow = [System.IO.File]::ReadAllText((Join-Path $root "staged.mach"))
Check "a root checker restores the previous file" ((-not $r.ok) -and $r.error.code -eq "check_failed" -and $stagedNow -eq "OLD`n") $r
$r = Q "apply" @{ path = "staged.mach"; text = "NEW`n"; mode = "upsert" }
Check "a root checker then publishes the new bytes" ($r.ok -and ([System.IO.File]::ReadAllText((Join-Path $root "staged.mach")) -eq "NEW`n")) $r

$r = Q "apply" @{ files = @(@{ path = "ok.py"; text = "print(1)`n" }, @{ path = "bad.py"; text = "def f(:`n    pass`n" }) }
Check "a failed check writes nothing" ((-not $r.ok) -and $r.error.code -eq "check_failed" -and $r.error.files[0].path -eq "bad.py" -and $r.error.files[0].line -eq 1 -and -not (Test-Path (Join-Path $root "ok.py"))) $r
$r = Q "apply" @{ files = @(@{ path = "bad.js"; text = "function f( {`n}`n" }, @{ path = "bad.ps1"; text = "function f {`n" }, @{ path = "bad.json"; text = "{`"a`": [1,}`n" }) }
Check "node, powershell, and json failures all report" ((-not $r.ok) -and $r.error.files.Count -eq 3) $r

foreach ($bad in @(@("../x.txt", "path_dots"), @("C:\Windows\x.txt", "path_absolute"), @("logs/NUL.txt", "path_reserved"), @(".git/hooks/pre-commit", "path_internal"), @("a/b:c.txt", "path_char"), @("x/name.", "path_trailing"))) {
    $r = Q "apply" @{ path = $bad[0]; text = "x" }
    Check ("refuses " + $bad[0]) ((-not $r.ok) -and $r.error.code -eq $bad[1]) $r
}

$r = Q "apply" @{ files = @(@{ each = @("a", "b"); path = "same.txt"; text = "x" }) }
Check "each with a fixed path is refused" ((-not $r.ok) -and $r.error.code -eq "spec_each_path") $r
$r = Q "apply" @{ files = @(@{ path = "Dup.txt"; text = "a" }, @{ path = "dup.txt"; text = "b" }) }
Check "paths that differ only by case are a duplicate" ((-not $r.ok) -and $r.error.code -eq "duplicate_path") $r
$r = Q "apply" @{ vars = @{ k = "v" }; files = @(@{ path = "brace.py"; tmpl = "D = \{{'k': {{k|py}}}}`nprint(D)`n" }) }
Check "escaped braces stay literal" ($r.ok -and ([System.IO.File]::ReadAllText((Join-Path $root "brace.py")) -eq "D = {{'k': `"v`"}}`nprint(D)`n")) $r
$r = Q "apply" @{ vars = @{ cols = @("a") }; files = @(@{ path = "code.py"; tmpl = "n = {{len(cols)}}`n" }) }
Check "code inside a tag is tmpl_code" ((-not $r.ok) -and $r.error.code -eq "tmpl_code") $r
$r = Q "apply" @{ vars = @{ name = "x" }; files = @(@{ path = "t.txt"; tmpl = "line one`n{{nmae}}`n" }) }
Check "unknown template variable names its line" ((-not $r.ok) -and $r.error.code -eq "tmpl_var" -and $r.error.line -eq 2 -and $r.error.message -like "*visible here: name*") $r
$r = Q "apply" @{ files = @(@{ path = "t.txt"; template = "no/such" }) }
Check "unknown template name" ((-not $r.ok) -and $r.error.code -eq "tmpl_unknown") $r

$d = Q "template.define" @{ name = "greet.py"; text = "print({{who|py}})`n"; description = "print a greeting" }
Check "define a session template" ($d.ok -and $d.result.vars[0] -eq "who") $d
$r = Q "apply" @{ files = @(@{ each = @(@{ who = "Ada" }, @{ who = "it's Bob" }); path = "hi/{{who|snake}}.py"; template = "greet.py" }) }
Check "fan a session template out" ($r.ok -and $r.result.created -eq 2 -and $r.result.files[1].path -eq "hi/it_s_bob.py") $r
$t = Q "template.list" @{}
Check "template.list shows session and builtin templates" ($t.ok -and ($t.result.templates | Where-Object { $_.name -eq "greet.py" }) -and ($t.result.templates | Where-Object { $_.name -eq "py/script" }) -and (($t.result.templates | Where-Object { $_.name -eq "js/script" }).description -like "*--name value flags*")) $t
$d = Q "template.define" @{ name = "row.py"; path = "gen/{{who|snake}}.py"; text = "print({{who|py}})`n" }
Check "define a macro with a path pattern" ($d.ok) $d
$r = Q "apply" @{ expand = "@row.py`nwho`nAda`nit's Bob`n" }
$ada = ""
$bob = ""
if (Test-Path (Join-Path $root "gen\ada.py")) { $ada = [System.IO.File]::ReadAllText((Join-Path $root "gen\ada.py")) }
if (Test-Path (Join-Path $root "gen\it_s_bob.py")) { $bob = [System.IO.File]::ReadAllText((Join-Path $root "gen\it_s_bob.py")) }
Check "a macro table expands to one file per row" ($r.ok -and $r.result.created -eq 2 -and $ada -eq "print(`"Ada`")`n" -and $bob -eq "print(`"it's Bob`")`n") @{ ada = $ada; bob = $bob; reply = $r }
$again = Q "apply" @{ expand = "@row.py`nwho`nAda`nit's Bob`n" }
Check "the same table again is unchanged" ($again.ok -and $again.result.unchanged -eq 2) $again
$bad = Q "apply" @{ expand = "@row.py`nwho|city`nAda`n" }
Check "a short row is expand_row and writes nothing" ((-not $bad.ok) -and $bad.error.code -eq "expand_row" -and $bad.error.line -eq 3 -and ([System.IO.File]::ReadAllText((Join-Path $root "gen\ada.py")) -eq $ada)) $bad
$r = Q "apply" @{ expand = "@row.py`npath|who`ncustom/a.py|Cara`n" }
$cara = ""
if (Test-Path (Join-Path $root "custom\a.py")) { $cara = [System.IO.File]::ReadAllText((Join-Path $root "custom\a.py")) }
Check "a path column wins over the pattern" ($r.ok -and $cara -eq "print(`"Cara`")`n" -and -not (Test-Path (Join-Path $root "gen\cara.py"))) @{ cara = $cara; reply = $r }
$d = Q "template.define" @{ name = "bundle.txt"; path = "bundle.txt"; text = "{{#each rows}}{{name}} {{n}}`n{{/each}}" }
$r = Q "apply" @{ expand = "@bundle.txt`nname|n`nusers|3`norders|2`n" }
$bundle = ""
if (Test-Path (Join-Path $root "bundle.txt")) { $bundle = [System.IO.File]::ReadAllText((Join-Path $root "bundle.txt")) }
Check "a fixed path gathers every row into one file" ($r.ok -and $r.result.created -eq 1 -and $bundle -eq "users 3`norders 2`n") @{ bundle = $bundle; reply = $r }
$rn = Q "template.render" @{ template = "py/script"; vars = @{ description = "demo"; body = "print(args.name)"; args = @(@{ name = "name"; help = "who" }) } }
Check "render the builtin py/script" ($rn.ok -and $rn.result.text -like "*parser.add_argument(`"--name`", help=`"who`")*print(args.name)*") $rn

$r = Q "apply" @{ job = "j1"; files = @(@{ path = "a.py"; text = "print('a')`n" }, @{ path = "b.py"; text = "print('b')`n" }) }
Check "job writes a manifest" ($r.ok -and $r.result.manifest -eq "jobs/j1/manifest.json" -and $r.result.created -eq 3) $r
$r = Q "apply" @{ job = "j1"; prune = $true; files = @(@{ path = "a.py"; text = "print('a')`n" }) }
Check "prune deletes what the new spec dropped" ($r.ok -and $r.result.deleted -eq 1 -and $r.result.replaced -eq 1 -and -not (Test-Path (Join-Path $root "jobs\j1\b.py"))) $r
$v = Q "job.verify" @{ dir = "jobs/j1" }
Check "job.verify passes" ($v.ok -and $v.result.ok -and $v.result.clean) $v
Set-Content -NoNewline -Path (Join-Path $root "jobs\j1\a.py") -Value "tampered"
$v = Q "job.verify" @{ dir = "jobs/j1" }
Check "job.verify catches a changed file" ($v.ok -and (-not $v.result.ok) -and $v.result.files[0].reason -like "sha256 differs*") $v

$r = Q "apply" @{ path = "notes/a.txt"; delete = $true }
Check "delete" ($r.ok -and $r.result.deleted -eq 1 -and -not (Test-Path (Join-Path $root "notes\a.txt"))) $r
$r = Q "apply" @{ path = "notes/a.txt"; delete = $true }
Check "delete of a missing file is a conflict" ((-not $r.ok) -and $r.error.files[0].reason -eq "missing") $r

$r = Q "apply" @{ dry_run = $true; preview = $true; files = @(@{ path = "p.py"; template = "py/script"; with = @{ description = "x" } }) }
Check "dry run previews without writing" ($r.ok -and $r.result.ready -and $r.result.files[0].status -eq "would_create" -and $r.result.files[0].text -like "#!/usr/bin/env python3*" -and -not (Test-Path (Join-Path $root "p.py"))) $r

$ls = Q "read" @{ path = "." }
Check "read lists the root" ($ls.ok -and ($ls.result.files[0].entries | Where-Object { $_.name -eq "src" -and $_.kind -eq "dir" })) $ls

# search, outline, and the regex/scoped/anchored edit forms
$r = Q "search" @{ pattern = "s += x"; glob = "src/*.py" }
Check "search finds literal matches with the file sha256" ($r.ok -and $r.result.files[0].path -eq "src/calc.py" -and $r.result.files[0].sha256.Length -eq 64 -and $r.result.files[0].matches[0].line -gt 0) $r
$r = Q "search" @{ pattern = "^def "; regex = $true; glob = "*.py" }
Check "search regex over a basename glob" ($r.ok -and ($r.result.files | Where-Object { $_.path -eq "src/calc.py" -and $_.matches.Count -ge 2 })) $r
$r = Q "search" @{ glob = "src/**" }
Check "search without a pattern lists files" ($r.ok -and ($r.result.paths -contains "src/calc.py")) $r
$rd = Q "read" @{ path = "src/calc.py"; outline = $true; content = $false }
Check "read outline lists function symbols" ($rd.ok -and (-not $rd.result.files[0].text) -and ($rd.result.files[0].symbols | Where-Object { $_.name -eq "total" -and $_.kind -eq "function" })) $rd

$r = Q "apply" @{ path = "regex.txt"; text = "alpha(1) beta(2) gamma(3)`n" }
$r = Q "apply" @{ path = "regex.txt"; edits = @(@{ find_re = "(\w+)\((\d)\)"; replace = "\2:\1"; count = 3 }) }
Check "find_re expands captures and count" ($r.ok -and ([System.IO.File]::ReadAllText((Join-Path $root "regex.txt")) -eq "1:alpha 2:beta 3:gamma`n")) @{ r = $r; text = [System.IO.File]::ReadAllText((Join-Path $root "regex.txt")) }
$r = Q "apply" @{ path = "regex.txt"; edits = @(@{ find_re = "\d:(\w+)"; replace = "<\1>"; occurrence = -1 }) }
Check "find_re occurrence counts back" ($r.ok -and ([System.IO.File]::ReadAllText((Join-Path $root "regex.txt")) -eq "1:alpha 2:beta <gamma>`n")) $r
$r = Q "apply" @{ path = "regex.txt"; edits = @(@{ find_re = "\w+"; replace = "X"; within = "1:alpha"; all = $true }) }
Check "within scopes an edit to a span" ($r.ok -and ([System.IO.File]::ReadAllText((Join-Path $root "regex.txt")) -eq "X:X 2:beta <gamma>`n")) @{ text = [System.IO.File]::ReadAllText((Join-Path $root "regex.txt")) }
$r = Q "apply" @{ path = "regex.txt"; edits = @(@{ find = "X" }) }
Check "ambiguous find still refuses" ((-not $r.ok) -and $r.error.code -eq "edit_ambiguous") $r

$r = Q "apply" @{ path = "anchor.txt"; text = "one`ntwo`nthree`n" }
$r = Q "apply" @{ path = "anchor.txt"; edits = @(@{ insert_after = @{ find = "two" }; with = "after-two" }, @{ insert_before = @{ find_re = "^thr" }; with = "before-three" }) }
Check "find and find_re anchors insert on the right lines" ($r.ok -and ([System.IO.File]::ReadAllText((Join-Path $root "anchor.txt")) -eq "one`ntwo`nafter-two`nbefore-three`nthree`n")) @{ text = [System.IO.File]::ReadAllText((Join-Path $root "anchor.txt")) }
$r = Q "apply" @{ path = "anchor.txt"; edits = @(@{ insert_after = @{ find_re = "^three" } }) }
Check "an insert without with is refused" ((-not $r.ok) -and $r.error.code -eq "edit_bad") $r

$r = Q "apply" @{ path = "mv-src.txt"; text = "payload`n" }
$mvsha = $r.result.files[0].sha256
$r = Q "apply" @{ files = @(@{ path = "mv-dst.txt"; move = "mv-src.txt"; expect = ("0" * 64) }) }
Check "move with a stale expect is refused" ((-not $r.ok) -and $r.error.code -eq "stale" -and (Test-Path (Join-Path $root "mv-src.txt")) -and -not (Test-Path (Join-Path $root "mv-dst.txt"))) $r
$r = Q "apply" @{ files = @(@{ path = "mv-dst.txt"; move = "mv-src.txt"; expect = $mvsha }) }
Check "move renames atomically" ($r.ok -and $r.result.created -eq 1 -and $r.result.deleted -eq 1 -and -not (Test-Path (Join-Path $root "mv-src.txt")) -and ([System.IO.File]::ReadAllText((Join-Path $root "mv-dst.txt")) -eq "payload`n")) $r
$r = Q "apply" @{ files = @(@{ path = "mv-src.txt"; move = "mv-src.txt" }) }
Check "move onto itself is refused" ((-not $r.ok) -and $r.error.code -eq "move_same") $r

$r = Q "apply" @{ diff = $true; files = @(@{ path = "regex.txt"; edits = @(@{ find = "<gamma>"; replace = "4:gamma" }) }) }
Check "diff receipts carry unified hunks" ($r.ok -and $r.result.files[0].diff -like "*@@*" -and $r.result.files[0].diff -like "*<gamma>*" -and $r.result.files[0].diff -like "*4:gamma*") $r
$r = Q "apply" @{ dry_run = $true; diff = $true; files = @(@{ path = "anchor.txt"; delete = $true }) }
Check "dry run diff previews a delete" ($r.ok -and $r.result.files[0].status -eq "would_delete" -and $r.result.files[0].diff -like "*-one*") $r


# line endings never need to match the file's
[System.IO.File]::WriteAllText((Join-Path $root "eol.txt"), "alpha`r`nbeta`r`ngamma`r`n")
$r = Q "apply" @{ files = @(@{ path = "eol.txt"; edits = @(@{ find = "beta`ngamma"; replace = "B`nG" }) }) }
Check "lf find matches a crlf file with a note" ($r.ok -and $r.result.files[0].status -eq "replaced" -and ($r.result.files[0].notes -match "normalized")) $r
$disk = [System.IO.File]::ReadAllText((Join-Path $root "eol.txt"))
Check "crlf endings preserved in output" ($disk -eq "alpha`r`nB`r`nG`r`n") $disk
$r = Q "apply" @{ files = @(@{ path = "eol.txt"; edits = @(@{ find = "G"; replace = "GG"; within = "B`nG" }, @{ insert_after = "B"; with = "mid`n" }) }) }
Check "within scope and anchor normalize too" ($r.ok -and $r.result.files[0].status -eq "replaced") $r
$disk = [System.IO.File]::ReadAllText((Join-Path $root "eol.txt"))
Check "anchor insert keeps crlf" ($disk -eq "alpha`r`nB`r`nmid`r`nGG`r`n") $disk

# unchanged explains itself
$r = Q "apply" @{ files = @(@{ path = "eol.txt"; edits = @(@{ find = "GG"; replace = "GG" }) }) }
Check "no-op edit reports no_change" ($r.ok -and $r.result.files[0].status -eq "unchanged" -and $r.result.files[0].reason -eq "no_change") $r
$r = Q "apply" @{ path = "same.txt"; mode = "upsert"; text = "x`n" }
$r = Q "apply" @{ path = "same.txt"; mode = "upsert"; text = "x`n" }
Check "same bytes report same_content" ($r.ok -and $r.result.files[0].status -eq "unchanged" -and $r.result.files[0].reason -eq "same_content") $r

# unrecognized keys warn instead of vanishing
$r = Q "apply" @{ path = "warn.txt"; mode = "upsert"; text = "w`n"; expct = "0" }
Check "misspelled file key warns in notes" ($r.ok -and ($r.result.files[0].notes -match "expct")) $r
$r = Q "apply" @{ path = "warn2.txt"; mode = "upsert"; text = "w`n"; bogus = 1 }
Check "unknown top-level key warns" ($r.ok -and ($r.result.warnings -match "bogus")) $r
$r = Q "apply" @{ path = "warn3.txt"; mode = "upsert"; text = "y`n" }
$r = Q "apply" @{ files = @(@{ path = "warn3.txt"; edits = @(@{ find = "y"; replace = "z"; relpace = "q" }) }) }
Check "unknown edit key warns in notes" ($r.ok -and ($r.result.files[0].notes -match "relpace")) $r

# near misses name the line and column
[System.IO.File]::WriteAllText((Join-Path $root "nm.txt"), "hello world`nbye`n")
$r = Q "apply" @{ files = @(@{ path = "nm.txt"; edits = @(@{ find = "hello worlD`nbye"; replace = "z" }) }) }
Check "near miss names line and column" ((-not $r.ok) -and $r.error.code -eq "edit_not_found" -and $r.error.line -eq 1 -and $r.error.message -match "column 11") $r

# find_re names the crlf fix
$r = Q "apply" @{ files = @(@{ path = "eol.txt"; edits = @(@{ find_re = "alpha\nB"; replace = "z" }) }) }
Check "find_re failure suggests crlf" ((-not $r.ok) -and $r.error.code -eq "edit_not_found" -and $r.error.message -match "CRLF") $r

# symbol-scoped read, symbol-scoped edits, and single-pass ex %s/.../.../g
$rds = Q "read" @{ path = "src/calc.py"; symbol = "total" }
Check "read symbol returns only that symbol's span" ($rds.ok -and $rds.result.files[0].symbol -eq "total" -and $rds.result.files[0].first_line -eq 1 -and $rds.result.files[0].text.StartsWith("def total(items):") -and (-not $rds.result.files[0].text.Contains("def count"))) $rds
$r = Q "apply" @{ path = "src/calc.py"; edits = @(@{ within = @{ symbol = "total" }; ex = "%s/\bs\b/acc/g" }, @{ symbol = "count"; with = "def count(items):`n    return len(items)" }) }
$calcAfter = [System.IO.File]::ReadAllText((Join-Path $root "src\calc.py"))
Check "symbol-scoped ex and symbol replacement" ($r.ok -and $calcAfter.Contains("acc += x") -and $calcAfter.Contains("return len(items)")) @{ r = $r; text = $calcAfter }
$r = Q "apply" @{ path = "exsub.txt"; mode = "upsert"; text = "sandbox a a a`n" }
$r = Q "apply" @{ path = "exsub.txt"; edits = @(@{ ex = "%s/sandbox/verified sandbox/g" }, @{ ex = "%s/\ba\b/b/g" }) }
$exsub = [System.IO.File]::ReadAllText((Join-Path $root "exsub.txt"))
Check "ex /g does not re-match replacement and replaces 3+ hits" ($r.ok -and $exsub -eq "verified sandbox b b b`n") @{ r = $r; text = $exsub }

# read fold view and multi-symbol spans
$rfold = Q "read" @{ path = "src/calc.py"; fold = $true; symbols = @("count") }
Check "read fold folds function bodies and keeps requested symbols expanded" ($rfold.ok -and $rfold.result.files[0].folded -eq $true -and $rfold.result.files[0].text.Contains("folded: total]") -and $rfold.result.files[0].text.Contains("return len(items)")) $rfold
$rmulti = Q "read" @{ path = "src/calc.py"; symbols = @("total", "count") }
Check "read symbols returns multiple symbol spans" ($rmulti.ok -and $rmulti.result.files[0].spans.Count -eq 2 -and $rmulti.result.files[0].spans[0].symbol -eq "total" -and $rmulti.result.files[0].spans[1].symbol -eq "count") $rmulti

# workspace-wide glob refactor and atomic undo
$r = Q "apply" @{ files = @(
    @{ path = "pkg/m1.py"; mode = "upsert"; text = "def legacy_call(x):`n    return x + 1`n" },
    @{ path = "pkg/m2.py"; mode = "upsert"; text = "from pkg.m1 import legacy_call`nval = legacy_call(5)`n" },
    @{ path = "pkg/m3.py"; mode = "upsert"; text = "unrelated = 42`n" }
)}
$rglob = Q "apply" @{ glob = "pkg/*.py"; edits = @(@{ find = "legacy_call"; replace = "modern_call"; all = $true }) }
$m1After = [System.IO.File]::ReadAllText((Join-Path $root "pkg\m1.py"))
$m2After = [System.IO.File]::ReadAllText((Join-Path $root "pkg\m2.py"))
Check "glob apply edits only matching files across workspace" ($rglob.ok -and $rglob.result.replaced -eq 2 -and $m1After.Contains("def modern_call") -and $m2After.Contains("modern_call(5)")) $rglob

$rundo = Q "undo" @{}
$m1Reverted = [System.IO.File]::ReadAllText((Join-Path $root "pkg\m1.py"))
$m2Reverted = [System.IO.File]::ReadAllText((Join-Path $root "pkg\m2.py"))
Check "undo atomically reverts the latest multi-file transaction" ($rundo.ok -and $rundo.result.reverted_txn -eq $rglob.result.txn -and $m1Reverted.Contains("def legacy_call") -and $m2Reverted.Contains("legacy_call(5)")) $rundo

$rtxn = Q "apply" @{ path = "pkg/m3.py"; mode = "replace"; text = "unrelated = 99`n" }
[System.IO.File]::WriteAllText((Join-Path $root "pkg\m3.py"), "concurrent edit`n")
$rstaleUndo = Q "undo" @{ txn = $rtxn.result.txn }
Check "undo refuses when a file was modified after the transaction" ((-not $rstaleUndo.ok) -and $rstaleUndo.error.code -eq "conflict") $rstaleUndo

# search reports enclosing symbol on matches
$rsymSearch = Q "search" @{ pattern = "return len"; path = "src/calc.py" }
Check "search match reports enclosing symbol" ($rsymSearch.ok -and $rsymSearch.result.files[0].matches[0].symbol -eq "count") $rsymSearch

# auto_indent on insert_before and insert_after
$rind = Q "apply" @{
    path = "src/calc.py"; dry_run = $true; preview = $true;
    edits = @(
        @{ insert_before = "return len(items)"; auto_indent = $true; with = "n = len(items)`nm = n" }
    )
}
Check "insert_before with auto_indent matches anchor indentation" ($rind.ok -and $rind.result.files[0].text.Contains("    n = len(items)`n    m = n`n    return len(items)")) $rind

# multi-step undo stack and undo list
$ru1 = Q "apply" @{ path = "pkg/u_multi.py"; mode = "upsert"; text = "v = 1`n" }
$ru2 = Q "apply" @{ path = "pkg/u_multi.py"; edits = @(@{ find = "v = 1"; with = "v = 2" }) }
$ru3 = Q "apply" @{ path = "pkg/u_multi.py"; edits = @(@{ find = "v = 2"; with = "v = 3" }) }
$rulist = Q "undo" @{ list = $true }
Check "undo list returns transaction stack with prev_txn" ($rulist.ok -and $rulist.result.count -ge 2 -and $rulist.result.txns[0].txn -eq $ru3.result.txn -and $rulist.result.txns[0].prev_txn -eq $ru2.result.txn) $rulist
$rundoA = Q "undo" @{}
$rundoB = Q "undo" @{}
$rmultiRead = Q "read" @{ path = "pkg/u_multi.py" }
Check "consecutive undo calls walk back through transaction history" ($rundoA.ok -and $rundoB.ok -and $rmultiRead.result.files[0].text -eq "v = 1`n") $rmultiRead

# 1. AST-aware symbol edits (body, signature, rename, and Python trailing top-level code boundary)
$astSrc = "@trace`ndef compute(x):`n    return x + 1`n`ndef helper(y):`n    return y * 2`n`nif __name__ == '__main__':`n    print(compute(10))`n"
$rAst0 = Q "apply" @{ path = "pkg/ast_demo.py"; mode = "upsert"; text = $astSrc; check = $false }
$rAstRead = Q "read" @{ path = "pkg/ast_demo.py"; symbol = "helper" }
Check "AST-aware Python symbol boundary stops before top-level if __name__" ($rAstRead.ok -and (-not $rAstRead.result.files[0].text.Contains("__name__"))) $rAstRead
$rAstBody = Q "apply" @{ path = "pkg/ast_demo.py"; check = $false; edits = @(
    @{ symbol = "compute"; body = "step = x + 10`nreturn step" }
)}
$rAstSig = Q "apply" @{ path = "pkg/ast_demo.py"; check = $false; edits = @(
    @{ symbol = "compute"; signature = "def compute(x, bonus=0):" }
)}
$rAstRen = Q "apply" @{ path = "pkg/ast_demo.py"; check = $false; edits = @(
    @{ symbol = "compute"; rename = "compute_v2" }
)}
$astAfter = [System.IO.File]::ReadAllText((Join-Path $root "pkg\ast_demo.py"))
Check "AST-aware symbol body, signature, and rename edits preserve decorators and trailing code" ($rAstBody.ok -and $rAstSig.ok -and $rAstRen.ok -and $astAfter.Contains("@trace`ndef compute_v2(x, bonus=0):`n    step = x + 10`n    return step") -and $astAfter.Contains("if __name__ == '__main__':")) @{ text = $astAfter; sig = $rAstSig }

# 2. Enforced method and line scope contracts
$rContractBadSym = Q "apply" @{
    path = "pkg/ast_demo.py"; check = $false;
    contract = @{ symbols = @("compute_v2"); preserve_signatures = $true };
    edits = @(@{ find = "return y * 2"; with = "return y * 3" })
}
Check "scope contract refuses edit outside permitted symbols" ((-not $rContractBadSym.ok) -and $rContractBadSym.error.code -eq "contract_violation") $rContractBadSym
$rContractBadSig = Q "apply" @{
    path = "pkg/ast_demo.py"; check = $false;
    contract = @{ symbols = @("compute_v2"); preserve_signatures = $true };
    edits = @(@{ symbol = "compute_v2"; signature = "def compute_v2(x):" })
}
Check "scope contract with preserve_signatures refuses signature change" ((-not $rContractBadSig.ok) -and $rContractBadSig.error.code -eq "contract_violation") $rContractBadSig
$rContractOk = Q "apply" @{
    path = "pkg/ast_demo.py"; check = $false;
    contract = @{ symbols = @("compute_v2"); preserve_signatures = $true; max_lines_changed = 10 };
    edits = @(@{ symbol = "compute_v2"; body = "step = x + bonus`nreturn step" })
}
Check "scope contract accepts in-scope body edit with preserved signature" ($rContractOk.ok -and $rContractOk.result.replaced -eq 1) $rContractOk

# 3. Semantic change previews
Check "receipt carries semantic change preview with modified symbols and signature_changed" ($rContractOk.result.files[0].semantic.modified.Count -eq 1 -and $rContractOk.result.files[0].semantic.modified[0].name -eq "compute_v2" -and $rContractOk.result.files[0].semantic.modified[0].signature_changed -eq $false -and $rAstSig.result.files[0].semantic.modified[0].signature_changed -eq $true) @{ body = $rContractOk.result.files[0].semantic; sig = $rAstSig.result.files[0].semantic }

# 4. Project validation before commit
$valGate = "param([string]`$Root)`n`$p = Join-Path `$Root 'pkg\val_target.py'`nif ((Test-Path `$p) -and ((Get-Content -Raw `$p) -match 'FORBIDDEN')) { [Console]::Error.WriteLine('forbidden token'); exit 1 }`nexit 0`n"
[void](Q "apply" @{ path = "val_gate.ps1"; mode = "upsert"; text = $valGate })
$rValFail = Q "apply" @{
    path = "pkg/val_target.py"; mode = "upsert"; text = "x = 'FORBIDDEN'`n";
    validate = @("powershell", "-NoProfile", "-File", "val_gate.ps1", "{root}")
}
Check "project validation before commit refuses and rolls back staged files" ((-not $rValFail.ok) -and $rValFail.error.code -eq "check_failed" -and (-not (Test-Path (Join-Path $root "pkg\val_target.py")))) $rValFail
$rValPass = Q "apply" @{
    path = "pkg/val_target.py"; mode = "upsert"; text = "x = 'ALLOWED'`n";
    validate = @("powershell", "-NoProfile", "-File", "val_gate.ps1", "{root}")
}
Check "project validation before commit accepts valid staged changes" ($rValPass.ok -and $rValPass.result.validation -eq "ok") $rValPass

# 5. Streaming transaction events and journal events op
$rStream = Q "apply" @{ path = "pkg/streamed.py"; mode = "upsert"; text = "s = 1`n"; stream = $true }
Check "apply with stream:true emits per-phase events in receipt" ($rStream.ok -and $rStream.result.events.Count -ge 3 -and $rStream.result.events[0].phase -eq "compile") $rStream
$rEvents = Q "events" @{ since_offset = 0; limit = 10 }
Check "events op reads transaction journal with next_offset" ($rEvents.ok -and $rEvents.result.count -ge 1 -and $rEvents.result.next_offset -gt 0) $rEvents

# 6. Persistent multi-file undo & redo + multi-step undo
$rpr1 = Q "apply" @{ path = "pkg/redo_demo.py"; mode = "upsert"; text = "state = 10`n" }
$rpr2 = Q "apply" @{ path = "pkg/redo_demo.py"; edits = @(@{ find = "state = 10"; with = "state = 20" }) }
$rprUndo = Q "undo" @{}
$rprRedo = Q "redo" @{}
$redoText = [System.IO.File]::ReadAllText((Join-Path $root "pkg\redo_demo.py"))
Check "persistent undo followed by redo restores the transaction" ($rprUndo.ok -and $rprRedo.ok -and $rprRedo.result.redone_txn -eq $rpr2.result.txn -and $redoText -eq "state = 20`n") @{ undo = $rprUndo; redo = $rprRedo; text = $redoText }
$rpr3 = Q "apply" @{ path = "pkg/redo_demo.py"; edits = @(@{ find = "state = 20"; with = "state = 30" }) }
$rprSteps = Q "undo" @{ steps = 2 }
$stepsText = [System.IO.File]::ReadAllText((Join-Path $root "pkg\redo_demo.py"))
Check "undo with steps:2 reverts two transactions in one call" ($rprSteps.ok -and $rprSteps.result.steps_reverted -eq 2 -and $stepsText -eq "state = 10`n") @{ res = $rprSteps; text = $stepsText }

# 7. Three-way proposal rebasing
$rebInit = Q "apply" @{ path = "pkg/rebase_demo.py"; mode = "upsert"; text = "a = 1`nb = 2`nc = 3`nd = 4`ne = 5`n" }
$baseSha = $rebInit.result.files[0].sha256
$rebConcurrent = Q "apply" @{ path = "pkg/rebase_demo.py"; edits = @(@{ find = "a = 1"; with = "a = 100" }) }
$rebMerged = Q "apply" @{
    path = "pkg/rebase_demo.py"; expect = $baseSha; rebase = $true;
    edits = @(@{ find = "e = 5"; with = "e = 500" })
}
$rebText = [System.IO.File]::ReadAllText((Join-Path $root "pkg\rebase_demo.py"))
Check "3-way proposal rebasing merges non-overlapping edits against stale expect sha256" ($rebMerged.ok -and $rebMerged.result.files[0].rebased -eq $true -and $rebMerged.result.files[0].base_sha256 -eq $baseSha -and $rebText -eq "a = 100`nb = 2`nc = 3`nd = 4`ne = 500`n") @{ merged = $rebMerged; text = $rebText }
$rebConflict = Q "apply" @{
    path = "pkg/rebase_demo.py"; expect = $baseSha; rebase = $true;
    edits = @(@{ find = "a = 1"; with = "a = 999" })
}
Check "3-way proposal rebasing refuses overlapping concurrent edits with rebase_conflict" ((-not $rebConflict.ok) -and $rebConflict.error.code -eq "rebase_conflict") $rebConflict

# 8. Resolved reference and impact graphs
[void](Q "apply" @{ files = @(
    @{ path = "pkg/ig_def.py"; mode = "upsert"; text = "def calc_metric(v):`n    return v * 10`n" },
    @{ path = "pkg/ig_use.py"; mode = "upsert"; text = "from pkg.ig_def import calc_metric`n`ndef run_report():`n    return calc_metric(7)`n" }
)})
$rImpact = Q "impact" @{ symbol = "calc_metric"; path = "pkg/ig_def.py" }
Check "impact op returns resolved definitions, references with enclosing symbol, dependents, and affected_symbols" ($rImpact.ok -and $rImpact.result.definitions.Count -ge 1 -and $rImpact.result.references.Count -ge 1 -and ($rImpact.result.affected_symbols -contains "pkg/ig_use.py:run_report") -and ($rImpact.result.dependents -contains "pkg/ig_use.py")) $rImpact

# 9. Discoverable capabilities and schemas
$rCaps = Q "capabilities" @{}
$rSchema = Q "schema" @{ op = "apply" }
Check "capabilities and schema ops return machine-readable metadata" ($rCaps.ok -and ($rCaps.result.symbol_edit_modes -contains "body") -and ($rCaps.result.contract_fields -contains "preserve_signatures") -and $rSchema.ok -and ($rSchema.result.schemas.apply.fields -contains "rebase")) @{ caps = $rCaps; schema = $rSchema }

# 10. Signed releases and update verification
New-Item -ItemType Directory -Force -Path (Join-Path $root "rel_test") | Out-Null
[System.IO.File]::WriteAllText((Join-Path $root "rel_test\artifact.txt"), "qark 0.3.0 binary payload`n")
$rSign = Q "release.sign" @{ dir = "rel_test"; version = "0.3.0" }
$rVerifyOk = Q "release.verify" @{ dir = "rel_test" }
Check "release.sign and release.verify sign and validate release artifacts" ($rSign.ok -and $rSign.result.files -eq 1 -and $rVerifyOk.ok -and $rVerifyOk.result.verified -eq $true) @{ sign = $rSign; verify = $rVerifyOk }
[System.IO.File]::WriteAllText((Join-Path $root "rel_test\artifact.txt"), "tampered payload`n")
$rVerifyBad = Q "release.verify" @{ dir = "rel_test" }
Check "release.verify detects tampered release artifact" ((-not $rVerifyBad.ok) -and $rVerifyBad.error.code -eq "release_tampered") $rVerifyBad

$w.StandardInput.Close()
[void]$w.WaitForExit(5000)

# two processes race to create one file with different content: exactly one wins
$race = Join-Path $root "race"
New-Item -ItemType Directory $race | Out-Null
$specs = @(1, 2) | ForEach-Object {
    $f = Join-Path $race "spec$_.json"
    (@{ path = "won.txt"; text = "writer $_`n"; check = $false } | ConvertTo-Json -Compress) | Set-Content -NoNewline -Path $f
    $f
}
$procs = $specs | ForEach-Object { Start-Process -FilePath $Qark -ArgumentList @("apply", "`"$_`"", "--root", "`"$race`"") -NoNewWindow -PassThru -RedirectStandardOutput ($_ + ".out") }
$procs | ForEach-Object { $_.WaitForExit() }
$outs = $specs | ForEach-Object { Get-Content -Raw ($_ + ".out") | ConvertFrom-Json }
$wins = @($outs | Where-Object { $_.ok }).Count
$conf = @($outs | Where-Object { -not $_.ok -and $_.error.code -eq "conflict" }).Count
Check "racing creators: one wins, one conflicts" ($wins -eq 1 -and $conf -eq 1) $outs

# qark apply - reads the spec from stdin
$stdinDir = Join-Path $root "stdin"
New-Item -ItemType Directory $stdinDir | Out-Null
$spec = @{ path = "pipe.txt"; mode = "upsert"; text = "p`n" } | ConvertTo-Json -Compress
$pipeOut = $spec | & $Qark apply "-" --root $stdinDir
$pipe = $pipeOut | ConvertFrom-Json
Check "apply - reads the spec from stdin" ($pipe.ok -and $pipe.result.files[0].status -eq "created") $pipe

# mcp
$m = Start-Worker @("mcp", "--root", "`"$root`"")
function M([string]$method, $params, $mid) {
    $msg = @{ jsonrpc = "2.0"; id = $mid; method = $method; params = $params } | ConvertTo-Json -Compress -Depth 20
    $m.StandardInput.WriteLine($msg)
    return ((Read-Reply $m $msg) | ConvertFrom-Json)
}
$init = M "initialize" @{ protocolVersion = "2025-06-18"; capabilities = @{}; clientInfo = @{ name = "suite"; version = "1" } } 1
Check "mcp initialize advertises tools, resources, and prompts" ($init.result.protocolVersion -eq "2025-06-18" -and $init.result.serverInfo.name -eq "qark" -and $init.result.capabilities.tools -and $init.result.capabilities.resources -and $init.result.capabilities.prompts) $init
$m.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
$tl = M "tools/list" @{} 2
Check "mcp tools/list has nine ergonomic tools with schemas" ($tl.result.tools.Count -eq 9 -and $tl.result.tools[0].inputSchema.type -eq "object" -and ($tl.result.tools | Where-Object { $_.name -eq "qark_edit" }) -and ($tl.result.tools | Where-Object { $_.name -eq "qark_impact" }) -and ($tl.result.tools | Where-Object { $_.name -eq "qark_undo" }) -and ($tl.result.tools | Where-Object { $_.name -eq "qark_check" })) $tl
$call = M "tools/call" @{ name = "qark_apply"; arguments = @{ path = "mcp/hello.py"; text = "def greet(who):`n    return 'hi ' + who`n"; check = $false } } 3
Check "mcp qark_apply" ((-not $call.result.isError) -and $call.result.structuredContent.created -eq 1 -and $call.result.content[0].type -eq "text") $call
$call = M "tools/call" @{ name = "qark_apply"; arguments = @{ path = "../x"; text = "x" } } 4
Check "mcp refusal sets isError" ($call.result.isError -and $call.result.structuredContent.code -eq "path_dots") $call
$fullHello = (Join-Path $root "mcp\hello.py")
$callEdit = M "tools/call" @{ name = "qark_edit"; arguments = @{ path = $fullHello; symbol = "greet"; body = "return 'hello ' + who"; check = $false } } 5
Check "mcp qark_edit supports flat AST symbol edit and strips workspace root from full paths" ((-not $callEdit.result.isError) -and $callEdit.result.structuredContent.replaced -eq 1 -and $callEdit.result.structuredContent.files[0].semantic.modified[0].name -eq "greet") $callEdit
$call = M "tools/call" @{ name = "qark_read"; arguments = @{ path = $fullHello } } "five"
Check "mcp string ids echo and read strips workspace root prefix" ($call.id -eq "five" -and $call.result.structuredContent.files[0].text -eq "def greet(who):`n    return 'hello ' + who`n") $call
$callImp = M "tools/call" @{ name = "qark_impact"; arguments = @{ symbol = "greet"; glob = "mcp/*.py" } } 8
Check "mcp qark_impact traces symbol definitions" ((-not $callImp.result.isError) -and $callImp.result.structuredContent.definitions.Count -eq 1 -and $callImp.result.structuredContent.definitions[0].path -eq "mcp/hello.py") $callImp
$callUndo = M "tools/call" @{ name = "qark_undo"; arguments = @{} } 9
$callRedo = M "tools/call" @{ name = "qark_undo"; arguments = @{ redo = $true } } 10
Check "mcp qark_undo reverts and redoes transactions" ((-not $callUndo.result.isError) -and (-not $callRedo.result.isError) -and $callRedo.result.structuredContent.redone_txn -eq $callEdit.result.structuredContent.txn) @{ undo = $callUndo; redo = $callRedo }
$callCheck = M "tools/call" @{ name = "qark_check"; arguments = @{ capabilities = $true } } 11
Check "mcp qark_check inspects capabilities" ((-not $callCheck.result.isError) -and ($callCheck.result.structuredContent.features -contains "ast_symbol_edits")) $callCheck
$resList = M "resources/list" @{} 12
$resRead = M "resources/read" @{ uri = "qark://capabilities" } 13
Check "mcp resources/list and resources/read expose live workspace resources" ($resList.result.resources.Count -eq 4 -and $resRead.result.contents[0].uri -eq "qark://capabilities") @{ list = $resList; read = $resRead }
$prList = M "prompts/list" @{} 14
$prGet = M "prompts/get" @{ name = "qark-edit-symbol"; arguments = @{ path = "mcp/hello.py"; symbol = "greet" } } 15
Check "mcp prompts/list and prompts/get return guided workflows" ($prList.result.prompts.Count -eq 2 -and $prGet.result.messages[0].content.text.Contains("qark_edit")) @{ list = $prList; get = $prGet }
$call = M "tools/call" @{ name = "qark_search"; arguments = @{ glob = "mcp/*.py" } } 7
Check "mcp qark_search lists matching paths" ((-not $call.result.isError) -and ($call.result.structuredContent.paths -contains "mcp/hello.py")) $call
$bad = M "nope/method" @{} 6
Check "mcp unknown method is -32601" ($bad.error.code -eq -32601) $bad
$m.StandardInput.Close()
[void]$m.WaitForExit(5000)

# ==============================================================================
# AutoCode Regression Matrix (9 cases)
# ==============================================================================

# Case 1: Valid and invalid JS under a default/CommonJS workspace
$cjsRoot = Join-Path $root "autocode-cjs"
New-Item -ItemType Directory -Force -Path $cjsRoot | Out-Null
$wcjs = Start-Worker @("--headless", "--stdio", "--root", "`"$cjsRoot`"")
function QCjs([string]$op, $argsObj) {
    $script:id++
    $req = @{ id = $script:id; op = $op; args = $argsObj } | ConvertTo-Json -Compress -Depth 20
    $wcjs.StandardInput.WriteLine($req)
    return ((Read-Reply $wcjs $req) | ConvertFrom-Json)
}
$rCjsOk = QCjs "apply" @{ path = "src/good.js"; text = "const x = 1;`nmodule.exports = { x };`n" }
Check "AutoCode #1a: valid JS in CommonJS workspace passes with validation_complete:true" ($rCjsOk.ok -and $rCjsOk.result.validation_complete -eq $true -and $rCjsOk.result.check_policy -eq "strict" -and $rCjsOk.result.checks.ok -eq 1 -and $rCjsOk.result.files[0].check -eq "ok") $rCjsOk
$rCjsBad = QCjs "apply" @{ path = "src/bad.js"; text = "const x = ;`n" }
Check "AutoCode #1b: invalid JS in CommonJS workspace is refused with check_failed" ((-not $rCjsBad.ok) -and $rCjsBad.error.code -eq "check_failed" -and $rCjsBad.error.validation_complete -eq $false -and $rCjsBad.error.files[0].check -eq "failed" -and (-not (Test-Path (Join-Path $cjsRoot "src\bad.js")))) $rCjsBad
$wcjs.StandardInput.Close()
[void]$wcjs.WaitForExit(5000)

# Case 2: Valid and invalid JS under an ESM workspace (package.json with "type":"module") via NDJSON and MCP
$esmRoot = Join-Path $root "autocode-esm"
New-Item -ItemType Directory -Force -Path $esmRoot | Out-Null
[System.IO.File]::WriteAllText((Join-Path $esmRoot "package.json"), '{"type":"module"}', $utf8)
$wesm = Start-Worker @("--headless", "--stdio", "--root", "`"$esmRoot`"")
function QEsm([string]$op, $argsObj) {
    $script:id++
    $req = @{ id = $script:id; op = $op; args = $argsObj } | ConvertTo-Json -Compress -Depth 20
    $wesm.StandardInput.WriteLine($req)
    return ((Read-Reply $wesm $req) | ConvertFrom-Json)
}
$rEsmReproDry = QEsm "apply" @{
    dry_run = $true
    files = @(
        @{ path = "repro/invalid.mjs"; text = "export const broken = ;`n" },
        @{ path = "repro/duplicate.js"; text = "const maze = 1;`nconst maze = 2;`n" }
    )
}
Check "AutoCode #2a: ESM workspace dry_run refuses invalid.mjs and duplicate.js (ready:false, check:failed)" ($rEsmReproDry.ok -and $rEsmReproDry.result.ready -eq $false -and $rEsmReproDry.result.validation_complete -eq $false -and $rEsmReproDry.result.files[0].check -eq "failed" -and $rEsmReproDry.result.files[1].check -eq "failed" -and (Test-Path (Join-Path $esmRoot ".qark\checkers\check.cjs"))) $rEsmReproDry
$rEsmReproApply = QEsm "apply" @{
    files = @(
        @{ path = "repro/invalid.mjs"; text = "export const broken = ;`n" },
        @{ path = "repro/duplicate.js"; text = "const maze = 1;`nconst maze = 2;`n" }
    )
}
Check "AutoCode #2b: ESM workspace real apply refuses invalid JS and writes nothing" ((-not $rEsmReproApply.ok) -and $rEsmReproApply.error.code -eq "check_failed" -and (-not (Test-Path (Join-Path $esmRoot "repro\invalid.mjs"))) -and (-not (Test-Path (Join-Path $esmRoot "repro\duplicate.js")))) $rEsmReproApply
$rEsmValid = QEsm "apply" @{ path = "src/mod.js"; text = "export const answer = 42;`n" }
Check "AutoCode #2c: ESM workspace accepts valid ES module syntax in .js with validation_complete:true" ($rEsmValid.ok -and $rEsmValid.result.validation_complete -eq $true -and $rEsmValid.result.files[0].check -eq "ok") $rEsmValid
$wesm.StandardInput.Close()
[void]$wesm.WaitForExit(5000)

$mesm = Start-Worker @("mcp", "--root", "`"$esmRoot`"")
function MEsm([string]$method, $params, $mid) {
    $msg = @{ jsonrpc = "2.0"; id = $mid; method = $method; params = $params } | ConvertTo-Json -Compress -Depth 20
    $mesm.StandardInput.WriteLine($msg)
    return ((Read-Reply $mesm $msg) | ConvertFrom-Json)
}
[void](MEsm "initialize" @{ protocolVersion = "2025-06-18"; capabilities = @{}; clientInfo = @{ name = "esm"; version = "1" } } 1)
$mesm.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
$mcpEsmDry = MEsm "tools/call" @{
    name = "qark_apply"
    arguments = @{
        dry_run = $true
        files = @(
            @{ path = "repro/invalid.mjs"; text = "export const broken = ;`n" },
            @{ path = "repro/duplicate.js"; text = "const maze = 1;`nconst maze = 2;`n" }
        )
    }
} 2
Check "AutoCode #2d: MCP qark_apply in ESM workspace sets ready:false on invalid JS dry_run" ((-not $mcpEsmDry.result.isError) -and $mcpEsmDry.result.structuredContent.ready -eq $false -and $mcpEsmDry.result.structuredContent.validation_complete -eq $false -and $mcpEsmDry.result.structuredContent.files[0].check -eq "failed") $mcpEsmDry
$mcpEsmApply = MEsm "tools/call" @{
    name = "qark_apply"
    arguments = @{
        path = "tests/game-smoke.test.mjs"
        text = "export function bad() { return ); }`n"
    }
} 3
Check "AutoCode #2e: MCP qark_apply in ESM workspace refuses invalid .mjs write with isError:true" ($mcpEsmApply.result.isError -eq $true -and $mcpEsmApply.result.structuredContent.code -eq "check_failed" -and (-not (Test-Path (Join-Path $esmRoot "tests\game-smoke.test.mjs")))) $mcpEsmApply
$mesm.StandardInput.Close()
[void]$mesm.WaitForExit(5000)

# Case 3: Nested repository inheriting "type":"module" from an ancestor directory
$nestedRoot = Join-Path $esmRoot "packages\nested-repo"
New-Item -ItemType Directory -Force -Path $nestedRoot | Out-Null
$wnest = Start-Worker @("--headless", "--stdio", "--root", "`"$nestedRoot`"")
function QNest([string]$op, $argsObj) {
    $script:id++
    $req = @{ id = $script:id; op = $op; args = $argsObj } | ConvertTo-Json -Compress -Depth 20
    $wnest.StandardInput.WriteLine($req)
    return ((Read-Reply $wnest $req) | ConvertFrom-Json)
}
$rNestValid = QNest "apply" @{ path = "index.js"; text = "export const nested = true;`n" }
$rNestInvalid = QNest "apply" @{ path = "broken.js"; text = "export const broken = ;`n" }
Check "AutoCode #3: nested repo inheriting ancestor ESM package.json validates without loader failure and rejects broken JS" ($rNestValid.ok -and $rNestValid.result.validation_complete -eq $true -and (-not $rNestInvalid.ok) -and $rNestInvalid.error.code -eq "check_failed") @{ valid = $rNestValid; invalid = $rNestInvalid }
$wnest.StandardInput.Close()
[void]$wnest.WaitForExit(5000)

# Case 4: .js, .mjs, and .cjs input module semantics stay separate from helper format
$wesm2 = Start-Worker @("--headless", "--stdio", "--root", "`"$esmRoot`"")
function QEsm2([string]$op, $argsObj) {
    $script:id++
    $req = @{ id = $script:id; op = $op; args = $argsObj } | ConvertTo-Json -Compress -Depth 20
    $wesm2.StandardInput.WriteLine($req)
    return ((Read-Reply $wesm2 $req) | ConvertFrom-Json)
}
$rCjsInEsmBad = QEsm2 "apply" @{ path = "lib/legacy.cjs"; text = "export const nope = 1;`n" }
$rCjsInEsmGood = QEsm2 "apply" @{ path = "lib/legacy.cjs"; text = "const fs = require('fs');`nmodule.exports = { fs };`n" }
$rMjsInEsmGood = QEsm2 "apply" @{ path = "lib/modern.mjs"; text = "export const ok = 123;`n" }
Check "AutoCode #4: .cjs rejects export syntax in ESM workspace while .cjs require and .mjs export succeed" ((-not $rCjsInEsmBad.ok) -and $rCjsInEsmBad.error.code -eq "check_failed" -and $rCjsInEsmGood.ok -and $rMjsInEsmGood.ok) @{ cjsBad = $rCjsInEsmBad; cjsGood = $rCjsInEsmGood; mjsGood = $rMjsInEsmGood }

# Case 5: Duplicate let/const declarations report line and column
$rDupConst = QEsm2 "apply" @{ path = "lib/dup.js"; text = "const maze = 1;`nconst maze = 2;`n" }
$rDupLet = QEsm2 "apply" @{ path = "lib/dup_let.mjs"; text = "let score = 0;`nlet score = 1;`n" }
Check "AutoCode #5: duplicate const/let declarations are rejected with line 2 and column > 0" ((-not $rDupConst.ok) -and $rDupConst.error.code -eq "check_failed" -and $rDupConst.error.files[0].line -eq 2 -and $rDupConst.error.files[0].col -gt 0 -and $rDupConst.error.files[0].check_message -match "maze" -and (-not $rDupLet.ok) -and $rDupLet.error.files[0].line -eq 2 -and $rDupLet.error.files[0].check_message -match "score") @{ dupConst = $rDupConst; dupLet = $rDupLet }
$wesm2.StandardInput.Close()
[void]$wesm2.WaitForExit(5000)

# Case 6: Checker infrastructure failures (crash, empty stdout, malformed JSON, count mismatch) fail closed with checker_error
$failRoot = Join-Path $root "autocode-checker-fail"
New-Item -ItemType Directory -Force -Path $failRoot | Out-Null
$crashScript = Join-Path $failRoot "fake-crash.cjs"
$emptyScript = Join-Path $failRoot "fake-empty.cjs"
$malformedScript = Join-Path $failRoot "fake-malformed.cjs"
$mismatchScript = Join-Path $failRoot "fake-mismatch.cjs"
[System.IO.File]::WriteAllText($crashScript, "process.stderr.write('Simulated checker crash\n'); process.exit(1);`n", $utf8)
[System.IO.File]::WriteAllText($emptyScript, "process.exit(0);`n", $utf8)
[System.IO.File]::WriteAllText($malformedScript, "process.stdout.write('NOT_JSON\n'); process.exit(0);`n", $utf8)
[System.IO.File]::WriteAllText($mismatchScript, "process.stdout.write('[]\n'); process.exit(0);`n", $utf8)

function Run-OneShotWithEnv([string]$envScript, [hashtable]$specTable) {
    $specPath = Join-Path $failRoot "oneshot-spec.json"
    ($specTable | ConvertTo-Json -Compress -Depth 20) | Set-Content -NoNewline -Encoding utf8 -Path $specPath
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Qark
    $psi.Arguments = "apply `"$specPath`" --root `"$failRoot`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables["QARK_CHECKER_SCRIPT"] = $envScript
    $p = [System.Diagnostics.Process]::Start($psi)
    $outText = $p.StandardOutput.ReadToEnd()
    [void]$p.WaitForExit(15000)
    return ($outText | ConvertFrom-Json)
}

$rCrash = Run-OneShotWithEnv $crashScript @{ path = "app.js"; text = "const ok = 1;`n" }
Check "AutoCode #6a: crashing checker fails closed with code:checker_error and sanitized diagnostics" ((-not $rCrash.ok) -and $rCrash.error.code -eq "checker_error" -and $rCrash.error.validation_complete -eq $false -and $rCrash.error.checker_diagnostics[0].category -eq "crash" -and $rCrash.error.checker_diagnostics[0].exit_code -eq 1 -and $rCrash.error.checker_diagnostics[0].stderr -match "Simulated checker crash" -and (-not (Test-Path (Join-Path $failRoot "app.js")))) $rCrash

$rCrashDry = Run-OneShotWithEnv $crashScript @{ dry_run = $true; path = "app.js"; text = "const ok = 1;`n" }
Check "AutoCode #6b: crashing checker on dry_run reports ready:false and check:error" ($rCrashDry.ok -and $rCrashDry.result.ready -eq $false -and $rCrashDry.result.validation_complete -eq $false -and $rCrashDry.result.files[0].check -eq "error" -and $rCrashDry.result.checker_diagnostics[0].category -eq "crash") $rCrashDry

$rEmpty = Run-OneShotWithEnv $emptyScript @{ path = "app.js"; text = "const ok = 1;`n" }
Check "AutoCode #6c: empty checker stdout fails closed with category:empty_output" ((-not $rEmpty.ok) -and $rEmpty.error.code -eq "checker_error" -and $rEmpty.error.checker_diagnostics[0].category -eq "empty_output") $rEmpty

$rMalformed = Run-OneShotWithEnv $malformedScript @{ path = "app.js"; text = "const ok = 1;`n" }
Check "AutoCode #6d: malformed non-JSON checker output fails closed with category:malformed_output" ((-not $rMalformed.ok) -and $rMalformed.error.code -eq "checker_error" -and $rMalformed.error.checker_diagnostics[0].category -eq "malformed_output") $rMalformed

$rMismatch = Run-OneShotWithEnv $mismatchScript @{ path = "app.js"; text = "const ok = 1;`n" }
Check "AutoCode #6e: wrong response array length fails closed with category:count_mismatch" ((-not $rMismatch.ok) -and $rMismatch.error.code -eq "checker_error" -and $rMismatch.error.checker_diagnostics[0].category -eq "count_mismatch") $rMismatch

$rPermissive = Run-OneShotWithEnv $crashScript @{ check = "permissive"; path = "perm.js"; text = "const ok = 1;`n" }
Check "AutoCode #6f: explicit check:permissive policy allows write on checker crash with validation_complete:false" ($rPermissive.ok -and $rPermissive.result.check_policy -eq "permissive" -and $rPermissive.result.validation_complete -eq $false -and $rPermissive.result.checks.error -eq 1 -and (Test-Path (Join-Path $failRoot "perm.js"))) $rPermissive

# Case 7: Mixed batch atomicity (valid JSON + invalid or uncheckable JS publishes neither)
$rMixedSyntax = Run-OneShotWithEnv "" @{
    files = @(
        @{ path = "batch/valid.json"; text = "{`"ok`": true}`n" },
        @{ path = "batch/invalid.js"; text = "export const broken = ;`n" }
    )
}
$rMixedCrash = Run-OneShotWithEnv $crashScript @{
    files = @(
        @{ path = "batch/valid2.json"; text = "{`"ok`": true}`n" },
        @{ path = "batch/crash.js"; text = "const a = 1;`n" }
    )
}
Check "AutoCode #7: mixed batch with valid JSON and invalid/crashed JS publishes neither file" ((-not $rMixedSyntax.ok) -and (-not (Test-Path (Join-Path $failRoot "batch\valid.json"))) -and (-not $rMixedCrash.ok) -and (-not (Test-Path (Join-Path $failRoot "batch\valid2.json")))) @{ syntax = $rMixedSyntax; crash = $rMixedCrash }

# Case 8: Structured repair feedback (mismatch_category, col, target_lines, actual_line) and changed_lines in receipts & events
$repRoot = Join-Path $root "autocode-repair"
New-Item -ItemType Directory -Force -Path $repRoot | Out-Null
$wrep = Start-Worker @("--headless", "--stdio", "--root", "`"$repRoot`"")
function QRep([string]$op, $argsObj) {
    $script:id++
    $req = @{ id = $script:id; op = $op; args = $argsObj } | ConvertTo-Json -Compress -Depth 20
    $wrep.StandardInput.WriteLine($req)
    return ((Read-Reply $wrep $req) | ConvertFrom-Json)
}
$rSeed = QRep "apply" @{
    path = "src/game.js"
    text = "function init() {`n  return 0;`n}`n`nfunction stepPlayer(state) {`n  const speed = state.baseSpeed * 2;`n  return speed;`n}`n"
}
$rRepairNear = QRep "apply" @{
    path = "src/game.js"
    edits = @(
        @{ within = @{ symbol = "stepPlayer" }; find = "  const speed = state.baseSpeed * 999;"; replace = "  const speed = 1;" }
    )
}
Check "AutoCode #8a: edit failure includes mismatch_category, col, target_lines, and actual_line" ((-not $rRepairNear.ok) -and $rRepairNear.error.code -eq "edit_not_found" -and $rRepairNear.error.mismatch_category -eq "near_miss" -and $rRepairNear.error.line -eq 6 -and $rRepairNear.error.col -gt 1 -and $rRepairNear.error.target_lines[0] -eq 5 -and $rRepairNear.error.target_lines[1] -eq 8 -and $rRepairNear.error.actual_line -eq "  const speed = state.baseSpeed * 2;") $rRepairNear

$rCoordEdit = QRep "apply" @{
    path = "src/game.js"
    edits = @(
        @{ within = @{ symbol = "stepPlayer" }; find = "  const speed = state.baseSpeed * 2;"; replace = "  const speed = state.baseSpeed * 4;" }
    )
}
$rRepEvents = QRep "events" @{ since_offset = 0; limit = 10 }
Check "AutoCode #8b: receipt and committed journal events include changed_lines and validation_complete" ($rCoordEdit.ok -and $rCoordEdit.result.files[0].changed_lines[0] -eq 6 -and $rCoordEdit.result.files[0].changed_lines[1] -eq 6 -and $rRepEvents.ok -and $rRepEvents.result.events[-1].event -eq "transaction.committed" -and $rRepEvents.result.events[-1].validation_complete -eq $true -and $rRepEvents.result.events[-1].files[0].changed_lines[0] -eq 6) @{ receipt = $rCoordEdit; events = $rRepEvents }

# Case 9: One-shot vs warm-process checker parity
$warmInvalid = QRep "apply" @{ dry_run = $true; path = "src/parity.js"; text = "const a = 1;`nconst a = 2;`n" }
$oneShotInvalid = Run-OneShotWithEnv "" @{ dry_run = $true; path = "src/parity.js"; text = "const a = 1;`nconst a = 2;`n" }
Check "AutoCode #9: one-shot and warm-process checker runs produce identical validation outcomes" ($warmInvalid.result.ready -eq $oneShotInvalid.result.ready -and $warmInvalid.result.validation_complete -eq $oneShotInvalid.result.validation_complete -and $warmInvalid.result.files[0].check -eq $oneShotInvalid.result.files[0].check -and $warmInvalid.result.files[0].line -eq $oneShotInvalid.result.files[0].line) @{ warm = $warmInvalid; oneshot = $oneShotInvalid }
$wrep.StandardInput.Close()
[void]$wrep.WaitForExit(5000)

Remove-Item -Recurse -Force $root
Write-Host ""
if ($script:fail -gt 0) {
    Write-Host "$($script:fail) of $($script:count) checks failed"
    exit 1
}
Write-Host "all $($script:count) checks passed"
exit 0
