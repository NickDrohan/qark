# qark syntax checker: reads [{"name","text"}] as json on stdin, parses each text
# without running it, and prints [{"ok"} | {"ok":false,"line","col","msg"}] in order.
# with -serve [-idle seconds] it answers one json line per request line, and exits
# when stdin closes or when no request arrives for that many seconds.
param([switch]$serve, [int]$idle = 0)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8

function Answer([string]$raw) {
    $files = ConvertFrom-Json -InputObject $raw
    $parts = foreach ($f in $files) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput([string]$f.text, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            $e = $errors[0]
            ConvertTo-Json -Compress -Depth 4 -InputObject ([ordered]@{ ok = $false; line = $e.Extent.StartLineNumber; col = $e.Extent.StartColumnNumber; msg = [string]$e.Message })
        } else {
            '{"ok":true}'
        }
    }
    return '[' + ($parts -join ',') + ']'
}

if ($serve) {
    $timer = $null
    $arm = {
        if ($timer -ne $null) { $timer.Dispose() }
        if ($idle -gt 0) {
            $script:timer = New-Object System.Threading.Timer ([System.Threading.TimerCallback]{ [Environment]::Exit(0) }, $null, ($idle * 1000), [System.Threading.Timeout]::Infinite)
        }
    }
    & $arm
    while ($null -ne ($line = [Console]::In.ReadLine())) {
        if ($timer -ne $null) { $timer.Dispose(); $timer = $null }
        if ($line.Trim()) {
            [Console]::Out.WriteLine((Answer $line))
            [Console]::Out.Flush()
        }
        & $arm
    }
} else {
    [Console]::Out.Write((Answer ([Console]::In.ReadToEnd())))
}
