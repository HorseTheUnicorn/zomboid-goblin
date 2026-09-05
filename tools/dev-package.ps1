[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$OutputRoot,
    [switch]$Zip
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Join-Path $PSScriptRoot ".." }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $RepoRoot "dist" }
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$source = Join-Path $RepoRoot "mod\Contents\mods\GoblinSurvivor"
if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "GoblinSurvivor source package was not found: $source"
}

$package = Join-Path $OutputRoot "GoblinSurvivor"
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
if (Test-Path -LiteralPath $package) {
    throw "Refusing to overwrite an existing package. Choose another -OutputRoot or remove only this exact package after review: $package"
}
New-Item -ItemType Directory -Force -Path $package | Out-Null
Copy-Item -LiteralPath (Join-Path $source "42") -Destination $package -Recurse

$forbidden = @("ClientAdapter", "live_client", "SteamCMD")
$runtimeFiles = Get-ChildItem -LiteralPath $package -Recurse -File
foreach ($file in $runtimeFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    foreach ($word in $forbidden) {
        if ($content -match [regex]::Escape($word)) {
            throw "Release package contains forbidden runtime reference '$word': $($file.FullName)"
        }
    }
    if ($file.Extension -ieq ".lua") {
        $imports = [regex]::Matches(
            $content,
            'require\s*\(\s*["'']([^"'']+)["'']\s*\)'
        )
        foreach ($import in $imports) {
            $module = $import.Groups[1].Value
            if (-not $module.StartsWith("GoblinSurvivor/")) {
                throw "Release package contains an external Lua module import '$module': $($file.FullName)"
            }
        }
    }
}

Write-Output "Created clean GoblinSurvivor package: $package"
if ($Zip) {
    $zipPath = Join-Path $OutputRoot "GoblinSurvivor.zip"
    if (Test-Path -LiteralPath $zipPath) {
        throw "Refusing to overwrite an existing package archive: $zipPath"
    }
    Compress-Archive -LiteralPath $package -DestinationPath $zipPath
    Write-Output "Created package archive: $zipPath"
}
