# Creates/deletes a VM in VMware Workstation (Windows host). Called by Terraform.
# Usage: vm.ps1 create|destroy  (parameters via environment variables)
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('create', 'destroy')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'

$vmrun = $env:VMRUN
$vmx   = $env:VM_VMX

function Invoke-Tool {
    param([string]$Exe, [string[]]$Arguments, [switch]$IgnoreError)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0 -and -not $IgnoreError) {
        throw "$Exe $($Arguments -join ' ') failed (exit $LASTEXITCODE)"
    }
}

function Set-Vmx {
    param([string]$Key, [string]$Value)
    $lines = Get-Content -LiteralPath $vmx | Where-Object {
        ($_ -split '=', 2)[0].Trim() -ne $Key
    }
    $lines += "$Key = `"$Value`""
    [System.IO.File]::WriteAllLines($vmx, [string[]]$lines)
}

switch ($Action) {
    'create' {
        if (Test-Path -LiteralPath $vmx) { throw "$vmx already exists." }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $vmx) | Out-Null

        Write-Host "[$env:VM_NAME] Cloning $env:TEMPLATE_VMX"
        Invoke-Tool $vmrun @('-T', 'ws', 'clone', $env:TEMPLATE_VMX, $vmx, 'full', "-cloneName=$env:VM_NAME")

        Write-Host "[$env:VM_NAME] Setting CPU=$env:CPU, memory=$($env:MEMORY_MB)MB and cloud-init guestinfo"
        Set-Vmx 'numvcpus' $env:CPU
        Set-Vmx 'cpuid.coresPerSocket' '1'
        Set-Vmx 'memsize' $env:MEMORY_MB
        Set-Vmx 'guestinfo.metadata' $env:METADATA_B64
        Set-Vmx 'guestinfo.metadata.encoding' 'base64'
        Set-Vmx 'guestinfo.userdata' $env:USERDATA_B64
        Set-Vmx 'guestinfo.userdata.encoding' 'base64'

        $diskLine = Get-Content -LiteralPath $vmx |
            Where-Object { $_ -match '^(scsi|sata|nvme|ide)\d+:0\.fileName\s*=\s*"(.+\.vmdk)"' } |
            Select-Object -First 1
        if ($diskLine -and $diskLine -match '"(.+)"') {
            $disk = $Matches[1]
            if (-not [System.IO.Path]::IsPathRooted($disk)) { $disk = Join-Path (Split-Path -Parent $vmx) $disk }
            Write-Host "[$env:VM_NAME] Expanding disk to $($env:DISK_GB)GB"
            try {
                Invoke-Tool $env:VDISKMANAGER @('-x', "$($env:DISK_GB)GB", $disk)
            } catch {
                Write-Warning "[$env:VM_NAME] Could not expand the disk (is it already larger?): $_"
            }
        } else {
            Write-Warning "[$env:VM_NAME] No disk found in $vmx"
        }

        Write-Host "[$env:VM_NAME] Starting"
        $mode = if ($env:START_MODE) { $env:START_MODE } else { 'nogui' }
        Invoke-Tool $vmrun @('-T', 'ws', 'start', $vmx, $mode)
    }

    'destroy' {
        if (-not (Test-Path -LiteralPath $vmx)) {
            Write-Host "$vmx does not exist, nothing to delete."
            exit 0
        }
        Invoke-Tool $vmrun @('-T', 'ws', 'stop', $vmx, 'hard') -IgnoreError
        Invoke-Tool $vmrun @('-T', 'ws', 'deleteVM', $vmx)
        Remove-Item -LiteralPath (Split-Path -Parent $vmx) -Force -ErrorAction SilentlyContinue
    }
}
