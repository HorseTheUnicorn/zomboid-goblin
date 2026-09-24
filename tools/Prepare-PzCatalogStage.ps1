[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$StageRoot,
    [Parameter(Mandatory=$true)][string]$Mods,
    [Parameter(Mandatory=$true)][string]$WorkshopItems,
    [string]$InstalledGame = 'C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid'
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($StageRoot)
$sourceGame = [IO.Path]::GetFullPath($InstalledGame)
$content = Join-Path $root 'content'
$runtime = Join-Path $root 'runtime'
$cache = Join-Path $runtime 'cache'
$game = Join-Path $runtime 'game'
if ($Mods.Contains("`n") -or $Mods.Contains("`r") -or [string]::IsNullOrWhiteSpace($Mods)) {
    throw 'Expected a single explicit Mods value, not a server configuration file'
}
$workshopIds = @($WorkshopItems -split ';')
if ($workshopIds.Count -eq 0 -or $workshopIds.Where({ $_ -notmatch '^\d+$' }).Count -gt 0 -or
    @($workshopIds | Select-Object -Unique).Count -ne $workshopIds.Count) {
    throw 'Expected unique numeric WorkshopItems IDs from the target server configuration'
}
if (!(Test-Path -LiteralPath (Join-Path $content 'media/scripts')) -or
    !(Test-Path -LiteralPath (Join-Path $content 'steamapps/workshop/content/108600'))) {
    throw 'Missing verified installed-content snapshot'
}
if (Test-Path -LiteralPath $runtime) { throw 'Runtime already exists; inspect it instead of overwriting it' }
New-Item -ItemType Directory -Path $game,(Join-Path $game 'media'),(Join-Path $cache 'mods'),
    (Join-Path $cache 'Server'),(Join-Path $cache 'Lua/goblin-reference-export'),
    (Join-Path $cache 'Lua/goblin-bridge') | Out-Null

# Only the disposable runtime is written. Scripts/Lua come from the captured
# server; other assets use the matching local build. Media must be physical
# copies: native scanners disagree on junction canonicalization.
Get-ChildItem -LiteralPath $sourceGame -File | Where-Object {
    $_.Extension -in '.dll','.jar' -or $_.Name -in 'stdlib.lua','stdlib.lbc'
} | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $game }
foreach ($folder in Get-ChildItem -LiteralPath $sourceGame -Directory) {
    if ($folder.Name -in 'media','mods','Workshop','steamapps') { continue }
    New-Item -ItemType Junction -Path (Join-Path $game $folder.Name) -Target $folder.FullName | Out-Null
}
foreach ($asset in Get-ChildItem -LiteralPath (Join-Path $sourceGame 'media')) {
    $target = Join-Path $game ('media/' + $asset.Name)
    if ($asset.PSIsContainer) {
        if ($asset.Name -in 'scripts','lua') {
            # Native source scanners canonicalize these paths, unlike the file
            # map. Junctions here produce unmapped absolute paths at runtime.
            Copy-Item -LiteralPath (Join-Path $content ('media/' + $asset.Name)) -Destination $target -Recurse
        } else {
            Copy-Item -LiteralPath $asset.FullName -Destination $target -Recurse
        }
    } else { Copy-Item -LiteralPath $asset.FullName -Destination $target }
}

$workshop = Join-Path $content 'steamapps/workshop/content/108600'
foreach ($itemId in $workshopIds) {
    $itemPath = Join-Path $workshop $itemId
    if (!(Test-Path -LiteralPath $itemPath -PathType Container)) {
        throw ('Configured Workshop item is missing from the snapshot: ' + $itemId)
    }
    $item = Get-Item -LiteralPath $itemPath
    $modRoot = Join-Path $item.FullName 'mods'
    if (!(Test-Path -LiteralPath $modRoot)) { continue }
    foreach ($folder in Get-ChildItem -LiteralPath $modRoot -Directory) {
        $target = Join-Path $cache ('mods/' + $folder.Name)
        if (Test-Path -LiteralPath $target) { throw ('Ambiguous duplicate mod folder: ' + $folder.Name) }
        # Only the Goblin copy receives the candidate helper. The snapshot stays intact.
        Copy-Item -LiteralPath $folder.FullName -Destination $target -Recurse
    }
}

$serverOptions = @(
    'Public=false','Open=false','UPnP=false','RCONPort=0','MaxPlayers=1',
    'DefaultPort=17261','UDPPort=17262','PauseEmpty=true','AutoCreateUserInWhiteList=false',
    'Map=Muldraugh, KY','WorkshopItems=',('Mods=' + $Mods)
) -join "`n"
[IO.File]::WriteAllText((Join-Path $cache 'Server/goblin-catalog.ini'), $serverOptions + "`n")
[IO.File]::WriteAllText((Join-Path $cache 'Lua/goblin-bridge/config.ini'),
    "GoblinEnabled=false`nGoblinAutonomyEnabled=false`n")
[PSCustomObject]@{ Game=$game; Cache=$cache; CandidateMod=(Join-Path $cache 'mods/GoblinSurvivor') }
