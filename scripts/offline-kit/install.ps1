# Installs the Terraform part of the offline kit on a Windows machine without
# internet access. Written into the kit by scripts/prepare-offline.sh; run it
# from there in PowerShell (no administrator rights needed):
#
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# It adds the kit's terraform.exe to the user PATH and points Terraform at the
# kit's providers mirror (TF_CLI_CONFIG_FILE). Ansible does not run on Windows:
# keep run_ansible = false, or run the Ansible part from a Linux machine or WSL
# with install.sh (see README.txt).

$ErrorActionPreference = 'Stop'

$kit = $PSScriptRoot
$bin = Join-Path $kit 'terraform\windows_amd64'
if (-not (Test-Path -LiteralPath (Join-Path $bin 'terraform.exe'))) {
    throw "The kit has no Terraform for windows_amd64 (prepare-offline.sh -a linux_amd64,windows_amd64)."
}

# Terraform reads forward slashes on Windows as well.
$mirror = (Join-Path $kit 'terraform-providers') -replace '\\', '/'
$rc = Join-Path $kit 'terraformrc'
@"
# Terraform CLI configuration for the offline kit (written by install.ps1).
provider_installation {
  filesystem_mirror {
    path = "$mirror"
  }
  direct {
    exclude = ["*/*/*"]
  }
}
"@ | Set-Content -LiteralPath $rc -Encoding ascii

[Environment]::SetEnvironmentVariable('TF_CLI_CONFIG_FILE', $rc, 'User')
$path = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not (($path -split ';') -contains $bin)) {
    [Environment]::SetEnvironmentVariable('Path', (@($path, $bin) | Where-Object { $_ }) -join ';', 'User')
}
$env:TF_CLI_CONFIG_FILE = $rc
$env:Path = "$bin;$env:Path"

& (Join-Path $bin 'terraform.exe') version
Write-Host ""
Write-Host "Done. TF_CLI_CONFIG_FILE and PATH are set for new terminals."
Write-Host "Ansible does not run on Windows: set run_ansible = false, or run the"
Write-Host "Ansible part from Linux or WSL (install.sh). See README.txt."
