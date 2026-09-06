[CmdletBinding()]
param(
    [string]$PzDataRoot = "$env:USERPROFILE\Zomboid",
    [string]$ProfileName = "goblin-local",
    [ValidateRange(20, 2000)]
    [int]$Tail = 240
)

$ErrorActionPreference = "Stop"
$logRoot = Join-Path ([IO.Path]::GetFullPath($PzDataRoot)) "Logs"
if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) {
    throw "PZ log directory was not found: $logRoot"
}

$patterns = @(
    "$ProfileName-server.stdout.log",
    "$ProfileName-server.stderr.log",
    "console.txt",
    "server-console.txt"
)
foreach ($name in $patterns) {
    $path = Join-Path $PzDataRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $path = Join-Path $logRoot $name
    }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Write-Output "--- $path ---"
        Get-Content -LiteralPath $path -Tail $Tail
    }
}

$latest = Get-ChildItem -LiteralPath $logRoot -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 8
if ($latest) {
    Write-Output "--- recent log files ---"
    $latest | Select-Object LastWriteTime,Length,Name | Format-Table -AutoSize
}
