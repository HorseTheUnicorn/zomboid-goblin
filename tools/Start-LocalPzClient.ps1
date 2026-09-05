[CmdletBinding()]
param(
    [string]$PzInstallRoot = "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid",
    [ValidatePattern('^[^:]+:[0-9]+$')]
    [string]$ConnectAddress,
    [switch]$Storm,
    [switch]$Visible,
    [string]$PzDataRoot = "$env:USERPROFILE\Zomboid",
    [string]$CacheDir,
    [switch]$AllowMultiple,
    [string]$LogPrefix = "goblin-local-client"
)

$ErrorActionPreference = "Stop"
$PzInstallRoot = [IO.Path]::GetFullPath($PzInstallRoot)
$PzDataRoot = [IO.Path]::GetFullPath($PzDataRoot)
$cacheSpecified = -not [string]::IsNullOrWhiteSpace($CacheDir)
if ($cacheSpecified) {
    $CacheDir = [IO.Path]::GetFullPath($CacheDir)
    if (-not (Test-Path -LiteralPath $CacheDir -PathType Container)) {
        throw "Client cache directory was not found: $CacheDir. Run Stage-LocalPzClientCache.ps1 first."
    }
}
if ($AllowMultiple -and -not $cacheSpecified) {
    throw "-AllowMultiple requires an isolated -CacheDir."
}
if ([string]::IsNullOrWhiteSpace($LogPrefix) -or
    $LogPrefix -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
    throw "LogPrefix must contain only bounded filename-safe characters."
}
$clientPath = Join-Path $PzInstallRoot "ProjectZomboid64.exe"
if (-not (Test-Path -LiteralPath $clientPath -PathType Leaf)) {
    throw "Project Zomboid client was not found: $clientPath"
}

$running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -eq $clientPath -or (
        $_.ExecutablePath -eq (Join-Path $PzInstallRoot 'jre64\bin\java.exe') -and
        $_.CommandLine -match 'zombie\.gameStates\.MainScreenState') })
if ($running) {
    if ($AllowMultiple -and $cacheSpecified) {
        $cachePattern = [regex]::Escape("-cachedir=$CacheDir")
        $sameCache = @($running | Where-Object {
            $_.CommandLine -match $cachePattern
        })
        if ($sameCache) {
            throw "A local PZ client is already using cache directory: $CacheDir"
        }
    }
    if ($AllowMultiple) {
        # A separate -cachedir isolates the second non-Steam client's options,
        # login state, saves, logs, and Storm package. Never reuse a running
        # client's cache for a parallel validation process.
    } else {
        $nonSteam = @($running | Where-Object { $_.CommandLine -match "(^|\s)-nosteam(\s|$)" })
        if ($nonSteam) {
            Write-Output "Local PZ client is already running in non-Steam mode."
            Write-Output "  pid: $($nonSteam[0].ProcessId)"
            exit 0
        }
        throw "A Steam-mode Project Zomboid client is already running. Close it before starting the local non-Steam test client."
    }
}

$arguments = @()
if ($cacheSpecified) {
    # MainScreenState accepts the single -cachedir=<path> launch argument.
    # Keep it before connection properties so every client-local file is
    # resolved below the isolated test root.
    $arguments += "-cachedir=$CacheDir"
}
$arguments += "-nosteam"
if (-not [string]::IsNullOrWhiteSpace($ConnectAddress)) {
    # MainScreenState consumes +connect as a launch-time property and opens
    # the normal multiplayer connection flow without needing UI automation.
    $arguments += @("+connect", $ConnectAddress)
}
if ($Storm) {
    $bootstrap = Join-Path $PzDataRoot 'Workshop\storm\Contents\mods\storm\bootstrap\storm-bootstrap.jar'
    if (-not (Test-Path -LiteralPath $bootstrap -PathType Leaf)) { throw "Missing Storm bootstrap: $bootstrap" }
    $logs = Join-Path $PzDataRoot 'Logs'
    New-Item -ItemType Directory -Force -Path $logs | Out-Null
    $headlessValue = if ($Visible) { 'false' } else { 'true' }
    $windowStyle = if ($Visible) { 'Normal' } else { 'Hidden' }
    $vmArgs = @(
        '--enable-native-access=ALL-UNNAMED',
        '--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED',
        '-Xmx3072m', "-Djava.awt.headless=$headlessValue", '-Dzomboid.steam=0',
        '-Djava.library.path=win64/;.;natives/;natives/win64/',
        "`"-javaagent:$bootstrap`"", '-DstormType=local', '-Dstorm.server=false',
        '-Dstorm.launcher.handoff=false',
        '-cp', './;projectzomboid.jar', 'zombie.gameStates.MainScreenState'
    )
    $stdout = Join-Path $logs "$LogPrefix.stdout.log"
    $stderr = Join-Path $logs "$LogPrefix.stderr.log"
    $process = Start-Process -FilePath (Join-Path $PzInstallRoot 'jre64\bin\java.exe') `
        -ArgumentList ($vmArgs + $arguments) -WorkingDirectory $PzInstallRoot -WindowStyle $windowStyle `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
} else {
    $process = Start-Process -FilePath $clientPath -ArgumentList $arguments -WorkingDirectory $PzInstallRoot -PassThru
}
Write-Output "Started local PZ client in non-Steam mode."
Write-Output "  pid: $($process.Id)"
Write-Output "  Storm: $Storm"
Write-Output "  Visible: $Visible"
if ($cacheSpecified) { Write-Output "  CacheDir: $CacheDir" }
