param(
    [string]$AddOnsPath = "E:\Games\Battle.net\World of Warcraft\_retail_\Interface\AddOns"
)

$ErrorActionPreference = "Stop"

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$addonName = "FlyingMountCycler"
$addonSource = Join-Path $projectRoot $addonName
$addonTarget = Join-Path $AddOnsPath $addonName

if (-not (Test-Path $addonSource)) {
    throw "Addon source folder not found: $addonSource"
}

if (-not (Test-Path $AddOnsPath)) {
    throw "WoW AddOns path not found: $AddOnsPath"
}

if (Test-Path $addonTarget) {
    Remove-Item $addonTarget -Recurse -Force
}

New-Item -ItemType Junction -Path $addonTarget -Target $addonSource | Out-Null
Write-Host "Linked $addonSource -> $addonTarget"
