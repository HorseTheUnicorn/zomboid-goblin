[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$PzInstallRoot = "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid",
    [string]$PzDataRoot = "$env:USERPROFILE\Zomboid",
    [string]$JdkRoot = "C:\Users\tomgr\AppData\Local\Temp\pz-jdk25\jdk-25.0.4.1+1"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Join-Path $PSScriptRoot ".."
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$sourceRoot = Join-Path $RepoRoot "storm\src"
$pzJar = Join-Path $PzInstallRoot "projectzomboid.jar"
$javac = Join-Path $JdkRoot "bin\javac.exe"
$jarTool = Join-Path $JdkRoot "bin\jar.exe"
$stormLib = Join-Path $PzDataRoot "Workshop\storm\Contents\mods\storm\42\lib"
$stormJar = Get-ChildItem -LiteralPath $stormLib -Filter "storm-*.jar" -File |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
$outputJar = Join-Path $RepoRoot "mod\Contents\mods\GoblinSurvivor\42\goblin-survivor-storm.jar"
$buildRoot = Join-Path $env:TEMP "goblin-survivor-storm-build"
$classes = Join-Path $buildRoot "classes"

foreach ($required in @(
    @{ Path = $sourceRoot; Label = "Storm mod source" },
    @{ Path = $pzJar; Label = "Project Zomboid jar" },
    @{ Path = $javac; Label = "JDK 25 javac" },
    @{ Path = $jarTool; Label = "JDK 25 jar tool" },
    @{ Path = $stormJar.FullName; Label = "Storm API jar" }
)) {
    if (-not (Test-Path -LiteralPath $required.Path)) {
        throw "$($required.Label) was not found: $($required.Path)"
    }
}

if (Test-Path -LiteralPath $buildRoot) {
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $classes | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputJar) | Out-Null

$sources = @(Get-ChildItem -LiteralPath $sourceRoot -Filter "*.java" -Recurse -File |
    Select-Object -ExpandProperty FullName)
if ($sources.Count -eq 0) {
    throw "No Storm mod Java sources were found under $sourceRoot"
}

$classpath = "$pzJar;$($stormJar.FullName)"
& $javac --release 25 -cp $classpath -d $classes $sources
if ($LASTEXITCODE -ne 0) {
    throw "Storm mod compilation failed with exit code $LASTEXITCODE."
}
& $jarTool --create --file $outputJar -C $classes .
if ($LASTEXITCODE -ne 0) {
    throw "Storm mod packaging failed with exit code $LASTEXITCODE."
}

Write-Output "Built GoblinSurvivor Storm bridge: $outputJar"
