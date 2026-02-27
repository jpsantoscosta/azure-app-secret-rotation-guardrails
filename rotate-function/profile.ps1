# profile.ps1 - keep it minimal on Linux Consumption
$modules = Join-Path $PSScriptRoot "Modules"
if (Test-Path $modules) {
  $env:PSModulePath = "$modules;$env:PSModulePath"
  Write-Host "Adding local Modules path: $modules"
} else {
  Write-Host "Modules folder not found at: $modules"
}
