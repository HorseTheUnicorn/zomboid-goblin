[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PzInstallRoot = "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid",
    [string]$ProfileName = "goblin-local"
)

$ErrorActionPreference = "Stop"
$PzInstallRoot = [IO.Path]::GetFullPath($PzInstallRoot)
$javaPath = Join-Path $PzInstallRoot "jre64\bin\java.exe"
if (-not (Test-Path -LiteralPath $javaPath -PathType Leaf)) {
    throw "Build 42 Java runtime was not found: $javaPath"
}

$running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ExecutablePath -eq $javaPath -and
        $_.CommandLine -match "zombie\.network\.GameServer" -and
        $_.CommandLine -match ([regex]::Escape($ProfileName))
    })
if ($running.Count -eq 0) {
    Write-Output "No local PZ server for profile '$ProfileName' is running."
    exit 0
}

foreach ($item in $running) {
    $process = Get-Process -Id ([int]$item.ProcessId) -ErrorAction SilentlyContinue
    if ($process -and $PSCmdlet.ShouldProcess("PID $($item.ProcessId)", "stop local PZ server '$ProfileName'")) {
        Stop-Process -Id ([int]$item.ProcessId) -Force
        Write-Output "Stopped local PZ server PID $($item.ProcessId)."
    }
}
