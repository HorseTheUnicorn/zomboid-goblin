[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$PzDataRoot = "$env:USERPROFILE\Zomboid",
    [string]$PzInstallRoot,
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$ProfileName = "goblin-local",
    [ValidateRange(0, 8)]
    [int]$ManagedNpcCount = 6,
    [switch]$SkipWorkshopStaging
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Join-Path $PSScriptRoot ".."
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

if ([string]::IsNullOrWhiteSpace($PzInstallRoot)) {
    $common = @(
        "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid",
        "C:\Program Files\Steam\steamapps\common\ProjectZomboid"
    )
    $PzInstallRoot = $common | Where-Object {
        Test-Path -LiteralPath (Join-Path $_ "projectzomboid.jar") -PathType Leaf
    } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($PzInstallRoot)) {
    throw "Project Zomboid Build 42 installation was not discovered. Pass -PzInstallRoot explicitly."
}

$sync = Join-Path $RepoRoot "tools\Sync-LocalPz.ps1"
if (-not (Test-Path -LiteralPath $sync -PathType Leaf)) {
    throw "Local synchronization script was not found: $sync"
}
Write-Output "Installing the current repository mod into the disposable local PZ profile."
& $sync -RepoRoot $RepoRoot -PzDataRoot $PzDataRoot -PzInstallRoot $PzInstallRoot `
    -ProfileName $ProfileName -ManagedNpcCount $ManagedNpcCount `
    -SkipWorkshopStaging:$SkipWorkshopStaging
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "Local PZ synchronization failed with exit code $LASTEXITCODE."
}
Write-Output "Local GoblinSurvivor installation completed without touching unrelated mods."
