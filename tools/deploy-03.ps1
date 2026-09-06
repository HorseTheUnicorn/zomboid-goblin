[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$true)]
    [string]$ComputerName,
    [Parameter(Mandatory=$true)]
    [string]$SshUser,
    [Parameter(Mandatory=$true)]
    [string]$DestinationRoot,
    [string]$PackageRoot,
    [string]$RepoRoot
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Join-Path $PSScriptRoot ".." }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    $PackageRoot = Join-Path $RepoRoot "dist\GoblinSurvivor"
}
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot)
if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
    throw "Build a clean package first: $PackageRoot"
}
if ([string]::IsNullOrWhiteSpace($DestinationRoot) -or $DestinationRoot -notmatch '^/[A-Za-z0-9._/-]+$' -or $DestinationRoot -match '/\.\.') {
    throw "DestinationRoot must be an explicit absolute Unix path without traversal."
}

$ssh = Get-Command ssh -ErrorAction SilentlyContinue
$scp = Get-Command scp -ErrorAction SilentlyContinue
if (-not $ssh -or -not $scp) { throw "OpenSSH ssh and scp are required; no password is embedded by this script." }
$remote = "$SshUser@$ComputerName"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$parent = Split-Path -Parent $DestinationRoot
$backup = "$parent/backups/GoblinSurvivor-$stamp"
$remotePackage = "${remote}:$DestinationRoot"

Write-Output "Verifying SSH identity for $remote."
& $ssh.Source $remote "uname -n"
if ($LASTEXITCODE -ne 0) { throw "SSH identity verification failed." }
Write-Output "The deployment will back up only $DestinationRoot to $backup."
if (-not $PSCmdlet.ShouldProcess($remote, "backup and replace GoblinSurvivor")) { return }

& $ssh.Source $remote "mkdir -p '$backup' && if [ -d '$DestinationRoot' ]; then cp -a '$DestinationRoot/.' '$backup/'; fi && mkdir -p '$DestinationRoot'"
if ($LASTEXITCODE -ne 0) { throw "Remote backup preparation failed; no package was uploaded." }
& $scp.Source -r (Join-Path $PackageRoot '*') $remotePackage
if ($LASTEXITCODE -ne 0) { throw "Package upload failed. The backup remains at $backup." }
Write-Output "Uploaded GoblinSurvivor to $remotePackage"
Write-Output "Backup: $backup"
Write-Output "Restart and smoke-test the PZ server separately after inspecting the transfer."
