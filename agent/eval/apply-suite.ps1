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
Check "session.info is 0.2.0 at the root" ($info.ok -and $info.result.version -eq "0.2.0" -and $info.result.root -like "*qark-suite-*") $info

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
Check "template.list shows session and builtin templates" ($t.ok -and ($t.result.templates | Where-Object { $_.name -eq "greet.py" }) -and ($t.result.templates | Where-Object { $_.name -eq "py/script" })) $t
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
Check "mcp initialize" ($init.result.protocolVersion -eq "2025-06-18" -and $init.result.serverInfo.name -eq "qark" -and $init.result.capabilities.tools) $init
$m.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
$tl = M "tools/list" @{} 2
Check "mcp tools/list has five tools with schemas" ($tl.result.tools.Count -eq 5 -and $tl.result.tools[0].inputSchema.type -eq "object" -and ($tl.result.tools | Where-Object { $_.name -eq "qark_search" })) $tl
$call = M "tools/call" @{ name = "qark_apply"; arguments = @{ path = "mcp/hello.py"; text = "print('hi')`n" } } 3
Check "mcp qark_apply" ((-not $call.result.isError) -and $call.result.structuredContent.created -eq 1 -and $call.result.content[0].type -eq "text") $call
$call = M "tools/call" @{ name = "qark_apply"; arguments = @{ path = "../x"; text = "x" } } 4
Check "mcp refusal sets isError" ($call.result.isError -and $call.result.structuredContent.code -eq "path_dots") $call
$call = M "tools/call" @{ name = "qark_read"; arguments = @{ path = "mcp/hello.py" } } "five"
Check "mcp string ids echo and read works" ($call.id -eq "five" -and $call.result.structuredContent.files[0].text -eq "print('hi')`n") $call
$call = M "tools/call" @{ name = "qark_search"; arguments = @{ glob = "mcp/*.py" } } 7
Check "mcp qark_search lists matching paths" ((-not $call.result.isError) -and ($call.result.structuredContent.paths -contains "mcp/hello.py")) $call
$bad = M "nope/method" @{} 6
Check "mcp unknown method is -32601" ($bad.error.code -eq -32601) $bad
$m.StandardInput.Close()
[void]$m.WaitForExit(5000)

Remove-Item -Recurse -Force $root
Write-Host ""
if ($script:fail -gt 0) {
    Write-Host "$($script:fail) of $($script:count) checks failed"
    exit 1
}
Write-Host "all $($script:count) checks passed"
exit 0
