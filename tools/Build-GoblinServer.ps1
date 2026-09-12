[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Jdk,
    [string]$Game = 'C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid',
    [Parameter(Mandatory=$true)][string]$StormJar
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$classes=Join-Path $repo 'server-java\build\classes'
$output=Join-Path $repo 'mod\Contents\mods\GoblinSurvivor\42\goblin-server.jar'
New-Item -ItemType Directory -Force -Path $classes | Out-Null
$sources=@(Get-ChildItem -LiteralPath (Join-Path $repo 'server-java\src') -Recurse -Filter '*.java' | ForEach-Object FullName)
& (Join-Path $Jdk 'bin\javac.exe') --release 25 -cp "$Game\projectzomboid.jar;$StormJar;$(Split-Path -Parent $StormJar)\*" -d $classes $sources
if ($LASTEXITCODE -ne 0) { throw 'Goblin server compilation failed' }
& (Join-Path $Jdk 'bin\jar.exe') --create --file $output -C $classes .
if ($LASTEXITCODE -ne 0) { throw 'Goblin server packaging failed' }
Get-FileHash -LiteralPath $output -Algorithm SHA256
