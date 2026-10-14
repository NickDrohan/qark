# Start Qark's MCP server rooted at the project Claude Code is editing.
# stdout is the protocol, so this script writes nothing of its own.
$ErrorActionPreference = "Stop"
$root = $env:CLAUDE_PROJECT_DIR
if (-not $root) { $root = (Get-Location).Path }
$qark = "D:\Dev\Qark\out\windows-x86_64\release\bin\qark.exe"
if (-not (Test-Path $qark)) {
    [Console]::Error.WriteLine("qark: missing $qark ; run build.ps1 in D:\Dev\Qark")
    exit 1
}
& $qark mcp --root $root
exit $LASTEXITCODE
