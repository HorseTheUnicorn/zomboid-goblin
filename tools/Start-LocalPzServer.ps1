[CmdletBinding()]
param(
    [string]$PzDataRoot = "$env:USERPROFILE\Zomboid",
    [string]$PzInstallRoot = "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid",
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$ProfileName = "goblin-local",
    [switch]$BootstrapAdmin,
    [switch]$Storm
)

$ErrorActionPreference = "Stop"
$PzDataRoot = [IO.Path]::GetFullPath($PzDataRoot)
$PzInstallRoot = [IO.Path]::GetFullPath($PzInstallRoot)
$javaPath = Join-Path $PzInstallRoot "jre64\bin\java.exe"
$jarPath = Join-Path $PzInstallRoot "projectzomboid.jar"
$profilePath = Join-Path $PzDataRoot "Server\$ProfileName.ini"
$stormBootstrap = Join-Path $PzDataRoot "Workshop\storm\Contents\mods\storm\bootstrap\storm-bootstrap.jar"
$databasePath = Join-Path $PzDataRoot "db\$ProfileName.db"
if (-not (Test-Path -LiteralPath $javaPath -PathType Leaf)) {
    throw "Build 42 Java runtime was not found: $javaPath"
}
if (-not (Test-Path -LiteralPath $jarPath -PathType Leaf)) {
    throw "Project Zomboid jar was not found: $jarPath"
}
if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
    throw "Local profile was not found. Run tools\Sync-LocalPz.ps1 first: $profilePath"
}
if ($Storm -and -not (Test-Path -LiteralPath $stormBootstrap -PathType Leaf)) {
    throw "Storm local bootstrap was not found. Build/install Storm first: $stormBootstrap"
}

$running = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ExecutablePath -eq $javaPath -and
        $_.CommandLine -match "zombie\.network\.GameServer" -and
        $_.CommandLine -match ([regex]::Escape($ProfileName))
    }
if ($running) {
    throw "The local PZ server profile is already running."
}

$logRoot = Join-Path $PzDataRoot "Logs"
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$stdoutPath = Join-Path $logRoot "$ProfileName-server.stdout.log"
$stderrPath = Join-Path $logRoot "$ProfileName-server.stderr.log"
$stormArguments = @()
if ($Storm) {
    $stormArguments = @(
        "-javaagent:$stormBootstrap",
        "-Dstorm.server=true",
        "-DstormType=local",
        "-DLOG_LEVEL=DEBUG"
    )
}
$arguments = @(
    "--enable-native-access=ALL-UNNAMED",
    "--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED",
    "-XX:+UseZGC",
    "-XX:-CreateCoredumpOnCrash",
    "-XX:-OmitStackTraceInFastThrow",
    "-Xmx3072m",
    "-Djava.library.path=./natives/;./natives/win64/;./"
) + $stormArguments + @(
    "-cp",
    "./;projectzomboid.jar",
    "zombie.network.GameServer",
    "-nosteam",
    "-servername",
    $ProfileName
)
$needsAdmin = $BootstrapAdmin -or -not (Test-Path -LiteralPath $databasePath -PathType Leaf)
$plainAdminPassword = $null
if ($needsAdmin) {
    Write-Output "The local profile has no admin account yet. Choose a local-only admin password when prompted."
    $securePassword = Read-Host "Local PZ admin password" -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    try {
        $plainAdminPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

if ($needsAdmin) {
    # The first-run server asks for the password on stdin. Keep it out of the
    # Java command line and send it through a private redirected pipe.
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $javaPath
    $startInfo.WorkingDirectory = $PzInstallRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.Arguments = ($arguments -join " ")
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    Start-Sleep -Seconds 2
    $process.StandardInput.WriteLine($plainAdminPassword)
    $process.StandardInput.WriteLine($plainAdminPassword)
    $process.StandardInput.Flush()
    $plainAdminPassword = $null
} else {
    $process = Start-Process -FilePath $javaPath -ArgumentList $arguments -WorkingDirectory $PzInstallRoot -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -WindowStyle Hidden -PassThru
}
Write-Output "Started local PZ server."
Write-Output "  profile: $ProfileName"
Write-Output "  pid:     $($process.Id)"
Write-Output "  ports:   16271/16272"
Write-Output "  stdout:  $stdoutPath"
Write-Output "  stderr:  $stderrPath"
