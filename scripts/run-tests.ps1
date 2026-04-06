$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$previousNativePreference = $PSNativeCommandUseErrorActionPreference
$PSNativeCommandUseErrorActionPreference = $false
python -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('lupa') else 1)" *> $null
$needsInstall = $LASTEXITCODE -ne 0
$PSNativeCommandUseErrorActionPreference = $previousNativePreference

if ($needsInstall) {
    Write-Host "Installing Python test dependencies from requirements.txt"
    python -m pip install --disable-pip-version-check -r requirements.txt
}

python -m unittest discover -s tests -p "test_*.py" -v
