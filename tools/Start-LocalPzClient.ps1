[CmdletBinding()]
param(
    [string]$PzInstallRoot = "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid",
    [ValidatePattern('^[^:]+:[0-9]+$')]
    [string]$ConnectAddress,
    [switch]$Storm,
    [switch]$Visible,
    [string]$PzDataRoot = "$env:USERPROFILE\Zomboid"
)

$ErrorActionPreference = "Stop"
$PzInstallRoot = [IO.Path]::GetFullPath($PzInstallRoot)
$clientPath = Join-Path $PzInstallRoot "ProjectZomboid64.exe"
if (-not (Test-Path -LiteralPath $clientPath -PathType Leaf)) {
    throw "Project Zomboid client was not found: $clientPath"
}

$running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -eq $clientPath -or (
        $_.ExecutablePath -eq (Join-Path $PzInstallRoot 'jre64\bin\java.exe') -and
        $_.CommandLine -match 'zombie\.gameStates\.MainScreenState') })
if ($running) {
    $nonSteam = @($running | Where-Object { $_.CommandLine -match "(^|\s)-nosteam(\s|$)" })
    if ($nonSteam) {
        Write-Output "Local PZ client is already running in non-Steam mode."
        Write-Output "  pid: $($nonSteam[0].ProcessId)"
        exit 0
    }
    throw "A Steam-mode Project Zomboid client is already running. Close it before starting the local non-Steam test client."
}

$arguments = @("-nosteam")
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
    $process = Start-Process -FilePath (Join-Path $PzInstallRoot 'jre64\bin\java.exe') `
        -ArgumentList ($vmArgs + $arguments) -WorkingDirectory $PzInstallRoot -WindowStyle $windowStyle `
        -RedirectStandardOutput (Join-Path $logs 'goblin-local-client.stdout.log') `
        -RedirectStandardError (Join-Path $logs 'goblin-local-client.stderr.log') -PassThru
} else {
    $process = Start-Process -FilePath $clientPath -ArgumentList $arguments -WorkingDirectory $PzInstallRoot -PassThru
}
Write-Output "Started local PZ client in non-Steam mode."
Write-Output "  pid: $($process.Id)"
Write-Output "  Storm: $Storm"
Write-Output "  Visible: $Visible"
