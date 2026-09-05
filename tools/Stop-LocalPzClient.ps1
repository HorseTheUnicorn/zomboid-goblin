[CmdletBinding()]
param(
    [string]$PzInstallRoot = "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid"
)

$ErrorActionPreference = "Stop"
$PzInstallRoot = [IO.Path]::GetFullPath($PzInstallRoot)
$clientPath = Join-Path $PzInstallRoot "ProjectZomboid64.exe"
$running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -eq $clientPath -or (
        $_.ExecutablePath -eq (Join-Path $PzInstallRoot 'jre64\bin\java.exe') -and
        $_.CommandLine -match 'zombie\.gameStates\.MainScreenState' -and
        $_.CommandLine -match '(^|\s)-nosteam(\s|$)') })
if (-not $running) {
    Write-Output "Local PZ client is not running."
    exit 0
}
foreach ($entry in $running) {
    Stop-Process -Id $entry.ProcessId -ErrorAction Stop
    Write-Output "Stopped local PZ client PID $($entry.ProcessId)."
}
