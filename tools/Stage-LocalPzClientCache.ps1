[CmdletBinding()]
param(
    [string]$SourcePzDataRoot = "$env:USERPROFILE\Zomboid",
    [Parameter(Mandatory = $true)]
    [string]$TargetPzDataRoot,
    [string]$RepoRoot
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Join-Path $PSScriptRoot ".."
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$SourcePzDataRoot = [IO.Path]::GetFullPath($SourcePzDataRoot)
$TargetPzDataRoot = [IO.Path]::GetFullPath($TargetPzDataRoot)

if (-not (Test-Path -LiteralPath $SourcePzDataRoot -PathType Container)) {
    throw "Source PZ data directory was not found: $SourcePzDataRoot"
}
if ([string]::Equals($SourcePzDataRoot.TrimEnd('\'),
        $TargetPzDataRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw "The isolated client cache must be different from the source PZ data directory."
}

function Assert-Directory([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label was not found: $Path"
    }
}

function Copy-Package([string]$RelativePath, [string]$Label) {
    $source = Join-Path $SourcePzDataRoot $RelativePath
    $target = Join-Path $TargetPzDataRoot $RelativePath
    Assert-Directory $source $Label
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $TargetPzDataRoot | Out-Null

# A parallel client needs its own Storm bootstrap, direct mod package, and
# integration config. Runtime bridge files are intentionally not copied:
# only the server writes authoritative state, and sharing those files would
# make the second client's diagnostics ambiguous.
Copy-Package 'Workshop\storm' 'Storm package'
Copy-Package 'Workshop\GoblinSurvivor' 'GoblinSurvivor Workshop package'
Copy-Package 'mods\GoblinSurvivor' 'GoblinSurvivor direct package'

$sourceBridge = Join-Path $SourcePzDataRoot 'Lua\goblin-bridge'
$targetBridge = Join-Path $TargetPzDataRoot 'Lua\goblin-bridge'
Assert-Directory $sourceBridge 'Goblin bridge config directory'
New-Item -ItemType Directory -Force -Path $targetBridge | Out-Null
foreach ($name in @('.goblin-bridge-v1', 'config.ini')) {
    $source = Join-Path $sourceBridge $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Required client bridge file was not found: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $targetBridge $name) -Force
}

$options = Join-Path $SourcePzDataRoot 'options.ini'
if (Test-Path -LiteralPath $options -PathType Leaf) {
    Copy-Item -LiteralPath $options -Destination (Join-Path $TargetPzDataRoot 'options.ini') -Force
}

Write-Output "Staged isolated local PZ client cache."
Write-Output "  source: $SourcePzDataRoot"
Write-Output "  target: $TargetPzDataRoot"
Write-Output "  next:   Start-LocalPzClient.ps1 -Storm -Visible -AllowMultiple -PzDataRoot '$TargetPzDataRoot' -CacheDir '$TargetPzDataRoot' -LogPrefix 'goblin-local-client-2' -ConnectAddress '127.0.0.1:16271'"
