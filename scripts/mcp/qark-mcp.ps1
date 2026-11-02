# Start Qark's MCP server rooted at the active workspace.
# stdout is the JSON-RPC protocol stream, so this script writes nothing of its own to stdout.
$ErrorActionPreference = "Stop"
$root = $null
if ($args.Count -ge 1 -and $args[0] -and (Test-Path -LiteralPath $args[0] -PathType Container)) {
    $root = $args[0]
}
if (-not $root) { $root = $env:QARK_ROOT }
if (-not $root) { $root = $env:CLAUDE_PROJECT_DIR }
if (-not $root) { $root = $env:WORKSPACE_FOLDER }
if (-not $root) { $root = $env:VSCODE_CWD }
if (-not $root) { $root = (Get-Location).Path }

$qark = "D:\Dev\Qark\out\windows-x86_64\release\bin\qark.exe"
if (-not (Test-Path -LiteralPath $qark)) {
    $qark = "D:\Dev\Qark\release\v0.3.0\qark.exe"
}
if (-not (Test-Path -LiteralPath $qark)) {
    [Console]::Error.WriteLine("qark: missing qark.exe; run build.ps1 in D:\Dev\Qark")
    exit 1
}
& $qark mcp --root $root
exit $LASTEXITCODE
