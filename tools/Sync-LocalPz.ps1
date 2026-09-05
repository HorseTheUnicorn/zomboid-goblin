[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$PzDataRoot = "$env:USERPROFILE\Zomboid",
    [string]$PzInstallRoot = "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid",
    [string]$ProfileName = "goblin-local",
    [ValidateRange(0, 8)]
    [int]$ManagedNpcCount = 6,
    [switch]$SkipWorkshopStaging
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Join-Path $PSScriptRoot ".."
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$PzDataRoot = [IO.Path]::GetFullPath($PzDataRoot)
$PzInstallRoot = [IO.Path]::GetFullPath($PzInstallRoot)

function Assert-Directory([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label was not found: $Path"
    }
}

function Assert-ExactPackageTarget([string]$Path, [string]$Parent, [string]$Leaf) {
    $full = [IO.Path]::GetFullPath($Path)
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    if ((Split-Path -Leaf $full) -ne $Leaf -or
        (Split-Path -Parent $full) -ne $parentFull) {
        throw "Refusing unexpected package target: $full"
    }
}

function Set-IniValue([string]$Path, [string]$Key, [string]$Value) {
    $lines = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $Path)
    }
    $pattern = "^" + [regex]::Escape($Key) + "="
    $replaced = $false
    $updated = foreach ($line in $lines) {
        if ($line -match $pattern) {
            $replaced = $true
            "$Key=$Value"
        } else {
            $line
        }
    }
    if (-not $replaced) {
        $updated += "$Key=$Value"
    }
    [IO.File]::WriteAllLines(
        $Path,
        [string[]]$updated,
        (New-Object Text.UTF8Encoding($false))
    )
}

function Write-Utf8([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}

function Remove-StalePackageFiles([string]$SourceRoot, [string]$TargetRoot) {
    # Mirror only the exact package target that this script has already
    # validated. This removes files left by an older package without naming or
    # depending on any previous NPC framework.
    $sourceFull = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $targetFull = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
    $sourceFiles = @{}
    foreach ($sourceFile in @(Get-ChildItem -LiteralPath $sourceFull -Recurse -File)) {
        $relative = $sourceFile.FullName.Substring($sourceFull.Length).TrimStart('\', '/')
        $sourceFiles[$relative.ToLowerInvariant()] = $true
    }
    foreach ($targetFile in @(Get-ChildItem -LiteralPath $targetFull -Recurse -File)) {
        $relative = $targetFile.FullName.Substring($targetFull.Length).TrimStart('\', '/')
        if (-not $sourceFiles.ContainsKey($relative.ToLowerInvariant())) {
            Remove-Item -LiteralPath $targetFile.FullName -Force
        }
    }
    $directories = @(Get-ChildItem -LiteralPath $targetFull -Recurse -Directory |
        Sort-Object { $_.FullName.Length } -Descending)
    foreach ($directory in $directories) {
        if ($null -eq (Get-ChildItem -LiteralPath $directory.FullName -Force | Select-Object -First 1)) {
            Remove-Item -LiteralPath $directory.FullName -Force
        }
    }
}

function Set-SandboxValue([string]$Path, [string]$Key, [string]$Value) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $content = [IO.File]::ReadAllText($Path)
    $pattern = "(?m)^(\s*)" + [regex]::Escape($Key) + "\s*=\s*[^,\r\n]+(,?)"
    $matches = [regex]::Matches($content, $pattern)
    if ($matches.Count -ne 1) {
        throw "Refusing ambiguous SandboxVars key '$Key' in $Path (matches=$($matches.Count))"
    }
    $updated = [regex]::Replace($content, $pattern, {
        param($match)
        return $match.Groups[1].Value + $Key + " = " + $Value + $match.Groups[2].Value
    }, 1)
    if ($updated -ne $content) {
        Write-Utf8 $Path $updated
    }
    return $true
}

Assert-Directory $PzInstallRoot "Project Zomboid installation"
Assert-Directory $PzDataRoot "Project Zomboid data directory"

$sourceMod = Join-Path $RepoRoot "mod\Contents\mods\GoblinSurvivor"
$sourceWorkshop = Join-Path $RepoRoot "mod"
Assert-Directory $sourceMod "GoblinSurvivor source package"
Assert-Directory $sourceWorkshop "Workshop staging source"

$javaPath = Join-Path $PzInstallRoot "jre64\bin\java.exe"
$clientPath = Join-Path $PzInstallRoot "ProjectZomboid64.exe"
if (-not (Test-Path -LiteralPath $javaPath -PathType Leaf)) {
    throw "Build 42 Java runtime was not found: $javaPath"
}

$runningClient = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -eq $clientPath -or (
        $_.ExecutablePath -eq $javaPath -and
        $_.CommandLine -match 'zombie\.gameStates\.MainScreenState') }
$runningServer = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ExecutablePath -eq $javaPath -and
        $_.CommandLine -match "zombie\.network\.GameServer"
    }
if ($runningClient -or $runningServer) {
    throw "Project Zomboid is running from the selected installation. Stop the local client/server before syncing."
}

$modsRoot = Join-Path $PzDataRoot "mods"
$directTarget = Join-Path $modsRoot "GoblinSurvivor"
New-Item -ItemType Directory -Force -Path $modsRoot | Out-Null
Assert-ExactPackageTarget $directTarget $modsRoot "GoblinSurvivor"
New-Item -ItemType Directory -Force -Path $directTarget | Out-Null
Copy-Item -Path (Join-Path $sourceMod "*") -Destination $directTarget -Recurse -Force
Remove-StalePackageFiles $sourceMod $directTarget

$workshopTarget = Join-Path $PzDataRoot "Workshop\GoblinSurvivor"
if (-not $SkipWorkshopStaging) {
    $workshopRoot = Join-Path $PzDataRoot "Workshop"
    New-Item -ItemType Directory -Force -Path $workshopRoot | Out-Null
    Assert-ExactPackageTarget $workshopTarget $workshopRoot "GoblinSurvivor"
    New-Item -ItemType Directory -Force -Path $workshopTarget | Out-Null
    Copy-Item -Path (Join-Path $sourceWorkshop "*") -Destination $workshopTarget -Recurse -Force
    Remove-StalePackageFiles $sourceWorkshop $workshopTarget
}

$bridgeRoot = Join-Path $PzDataRoot "Lua\goblin-bridge"
foreach ($channel in @("state", "events", "commands", "responses", "acks", "runtime", "archive", "deadletter")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $bridgeRoot $channel) | Out-Null
}
# Runtime snapshots are disposable and must not survive a package restart;
# otherwise local verification can read a previous server's Goblin status.
$runtimeRoot = Join-Path $bridgeRoot "runtime"
foreach ($runtimeName in @("zomboid-heartbeat.json", "zomboid-state.json", "zomboid-exact-state.json")) {
    $runtimePath = Join-Path $runtimeRoot $runtimeName
    if (Test-Path -LiteralPath $runtimePath -PathType Leaf) {
        Remove-Item -LiteralPath $runtimePath -Force
    }
}
Write-Utf8 (Join-Path $bridgeRoot ".goblin-bridge-v1") "goblin-bridge-v1`n"
Write-Utf8 (Join-Path $bridgeRoot ".ready-index.json") "[]"
Write-Utf8 (Join-Path $bridgeRoot "config.ini") @"
GoblinEnabled=true
GoblinDevelopmentMode=true
GoblinDebugSurvivors=true
GoblinAllowTestCommands=true
GoblinVerboseNPCLogging=true
GoblinBridgeRoot=goblin-bridge
GoblinNpcId=goblin.primary
GoblinNpcName=Goblin
GoblinNpcProgram=GoblinSurvivorNative
GoblinBodyMode=client_survivor
GoblinGameBuild=42.20.4
GoblinNpcProtected=true
GoblinTrackerExact=true
MinimumBaseGuards=1
GoblinManagedNpcCount=$ManagedNpcCount
GoblinCommanders=
"@

$serverRoot = Join-Path $PzDataRoot "Server"
New-Item -ItemType Directory -Force -Path $serverRoot | Out-Null
$profilePath = Join-Path $serverRoot "$ProfileName.ini"
if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
    Write-Utf8 $profilePath @"
DefaultPort=16271
UDPPort=16272
Public=false
Open=true
PauseEmpty=true
MaxPlayers=4
PVP=false
UPnP=false
DisplayName=Goblin Native Local Test
Mods=GoblinSurvivor
WorkshopItems=
"@
}
Set-IniValue $profilePath "DefaultPort" "16271"
Set-IniValue $profilePath "UDPPort" "16272"
Set-IniValue $profilePath "Public" "false"
Set-IniValue $profilePath "Open" "true"
# The local authority must keep advancing when the last client disconnects so
# survivor jobs, zombie population, and telemetry continue without a player.
# Production profiles are never rewritten by this development synchronizer.
Set-IniValue $profilePath "PauseEmpty" "false"
Set-IniValue $profilePath "MaxPlayers" "4"
Set-IniValue $profilePath "PVP" "false"
Set-IniValue $profilePath "UPnP" "false"
Set-IniValue $profilePath "DisplayName" "Goblin Native Local Test"
Set-IniValue $profilePath "Mods" "GoblinSurvivor"
Set-IniValue $profilePath "WorkshopItems" ""

# Keep the disposable local profile useful for the survivor combat gate.  The
# existing profile was created with zombie respawn disabled, which can look
# like the Goblin mod stopped ordinary population spawning.  Restrict this to
# the named local profile; never rewrite a production or user-named profile.
if ($ProfileName -eq "goblin-local") {
    $sandboxPath = Join-Path $serverRoot "${ProfileName}_SandboxVars.lua"
    if (Test-Path -LiteralPath $sandboxPath -PathType Leaf) {
        Set-SandboxValue $sandboxPath "ZombieRespawn" "2" | Out-Null
        Set-SandboxValue $sandboxPath "RespawnHours" "0.5" | Out-Null
        Set-SandboxValue $sandboxPath "RespawnUnseenHours" "16.0" | Out-Null
        Set-SandboxValue $sandboxPath "RespawnMultiplier" "0.1" | Out-Null
        Write-Output "  zombie population: normal respawn enabled for goblin-local"
    }
}

Write-Output "Local PZ package synchronized."
Write-Output "  direct:   $directTarget"
if (-not $SkipWorkshopStaging) { Write-Output "  workshop: $workshopTarget" }
Write-Output "  bridge:   $bridgeRoot"
Write-Output "  profile:  $profilePath"
Write-Output "  roster:   $ManagedNpcCount managed companion(s)"
