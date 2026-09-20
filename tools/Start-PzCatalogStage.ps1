[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$StageRoot,
    [string]$InstalledGame = 'C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid'
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($StageRoot)
$runtime = Join-Path $root 'runtime'
$game = Join-Path $runtime 'game'
$cache = Join-Path $runtime 'cache'
$bootstrap = Join-Path $root 'content/steamapps/workshop/content/108600/3676481910/mods/storm/bootstrap/storm-bootstrap.jar'
foreach ($required in @($bootstrap,(Join-Path $game 'stdlib.lua'),(Join-Path $cache 'Server/goblin-catalog.ini'))) {
    if (!(Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing staged file: $required" }
}
if (Get-NetUDPEndpoint -LocalPort 17261,17262 -ErrorAction SilentlyContinue) {
    throw 'Catalog test ports are already in use; inspect the existing process'
}
# An argument array preserves dotted Java system-property names in PowerShell.
$javaArgs = @(
    '--enable-native-access=ALL-UNNAMED','--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED',
    '-XX:+UseZGC','-XX:-CreateCoredumpOnCrash','-XX:-OmitStackTraceInFastThrow','-Xms512m','-Xmx3072m',
    '-Djava.library.path=./natives/;./natives/win64/;./',("-javaagent:$bootstrap"),
    '-Dstorm.server=true','-Dgoblin.referenceExport=true',("-Duser.home=$runtime"),
    ("-Dstorm.launcher.mods=" + (Join-Path $cache 'mods')),
    '-cp','./;projectzomboid.jar','zombie.network.GameServer',
    '-servername','goblin-catalog',("-cachedir=$cache"),'-nosteam','-ip','127.0.0.1',
    '-port','17261','-udpport','17262','-adminusername','catalog-admin','-adminpassword','catalog-local-only'
)
Push-Location -LiteralPath $game
try {
    & (Join-Path $InstalledGame 'jre64/bin/java.exe') @javaArgs
    if ($LASTEXITCODE -ne 0) { throw "Catalog server exited with code $LASTEXITCODE" }
} finally { Pop-Location }
