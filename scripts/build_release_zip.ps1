[CmdletBinding()]
param(
  [string]$Version = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$Root = Split-Path -Parent $ScriptDir

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = (Get-Content -LiteralPath (Join-Path $Root "VERSION") -Raw).Trim()
}

$DistDir = Join-Path $Root "dist"
if (-not (Test-Path -LiteralPath $DistDir)) {
  New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
}

$PackageName = "Sage-and-Triton-one-shot-v$Version"
$TempRoot = Join-Path $env:TEMP $PackageName
$ZipPath = Join-Path $DistDir "$PackageName.zip"

if (Test-Path -LiteralPath $TempRoot) {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

$items = @(
  "PingPong-SageInstaller.bat",
  "SagePocketInstaller.ps1",
  "README.md",
  "LICENSE",
  "VERSION"
)

foreach ($item in $items) {
  Copy-Item -LiteralPath (Join-Path $Root $item) -Destination (Join-Path $TempRoot $item) -Force
}

if (Test-Path -LiteralPath $ZipPath) {
  Remove-Item -LiteralPath $ZipPath -Force
}
$packageItems = Get-ChildItem -LiteralPath $TempRoot -Force | Select-Object -ExpandProperty FullName
Compress-Archive -LiteralPath $packageItems -DestinationPath $ZipPath -Force
Write-Host "Created $ZipPath"
