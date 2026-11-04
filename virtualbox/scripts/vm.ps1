# Creates/deletes a VM in VirtualBox (Windows host). Called by Terraform.
# Usage: vm.ps1 image|create|destroy  (parameters via environment variables)
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('image', 'create', 'destroy')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'

function Invoke-VBox {
    param([string[]]$Arguments, [switch]$IgnoreError)
    & $env:VBOXMANAGE @Arguments
    if ($LASTEXITCODE -ne 0 -and -not $IgnoreError) {
        throw "VBoxManage $($Arguments -join ' ') failed (exit $LASTEXITCODE)"
    }
}

function Get-VmInfo {
    $info = & $env:VBOXMANAGE showvminfo $env:VM_NAME --machinereadable 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $info
}

function Get-VmState {
    $info = Get-VmInfo
    if (-not $info) { return $null }
    $line = $info | Where-Object { $_ -match '^VMState="(.*)"$' } | Select-Object -First 1
    if ($line -match '^VMState="(.*)"$') { return $Matches[1] }
    return $null
}

# Builds a cloud-init NoCloud seed ISO (volume label "cidata") from a directory
# with the IMAPI2 file system image API that ships with Windows.
function New-SeedIso {
    param([string]$Directory, [string]$Path)
    if (-not ('SeedIsoWriter' -as [type])) {
        Add-Type -TypeDefinition @'
public static class SeedIsoWriter {
    public static void Write(string path, object stream, int blockSize, int totalBlocks) {
        var input = (System.Runtime.InteropServices.ComTypes.IStream)stream;
        var buffer = new byte[blockSize];
        using (var output = System.IO.File.Create(path)) {
            while (totalBlocks-- > 0) {
                input.Read(buffer, blockSize, System.IntPtr.Zero);
                output.Write(buffer, 0, blockSize);
            }
        }
    }
}
'@
    }
    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $image.FileSystemsToCreate = 3   # ISO 9660 + Joliet
    $image.VolumeName = 'cidata'
    $image.Root.AddTree($Directory, $false)
    $result = $image.CreateResultImage()
    [SeedIsoWriter]::Write($Path, $result.ImageStream, $result.BlockSize, $result.TotalBlocks)
}

# Returns the VBoxManage modifyvm arguments that attach NIC <n>.
function Get-NicArgs {
    param([int]$N, [string]$Type, [string]$Name)
    $attach = switch ($Type) {
        'bridged'     { @("--nic$N", 'bridged', "--bridgeadapter$N", $Name) }
        'hostonly'    { @("--nic$N", 'hostonly', "--hostonlyadapter$N", $Name) }
        'hostonlynet' { @("--nic$N", 'hostonlynet', "--host-only-net$N", $Name) }
        'natnetwork'  { @("--nic$N", 'natnetwork', "--nat-network$N", $Name) }
        default       { throw "Unknown network type: $Type" }
    }
    return $attach + @("--nictype$N", 'virtio', "--cableconnected$N", 'on')
}

function Write-Base64File {
    param([string]$Value, [string]$Path)
    [System.IO.File]::WriteAllBytes($Path, [System.Convert]::FromBase64String($Value))
}

# Checks $env:OVA against OVA_SHA256, or against the SHA256SUMS next to the URL
# it was downloaded from. A local file without OVA_SHA256 is not verified.
function Test-Ova {
    if ($env:VERIFY_SHA256 -eq '0') { return }
    $expected = $env:OVA_SHA256
    if (-not $expected) {
        if ($env:OVA_SOURCE -notmatch '^https?://') {
            Write-Host "Note: $env:OVA is not verified; set ubuntu_image_sha256 to verify a local file."
            return
        }
        $base = $env:OVA_SOURCE.Substring(0, $env:OVA_SOURCE.LastIndexOf('/'))
        $name = $env:OVA_SOURCE.Substring($env:OVA_SOURCE.LastIndexOf('/') + 1)
        $sums = (Invoke-WebRequest -Uri "$base/SHA256SUMS" -UseBasicParsing).Content
        if ($sums -is [byte[]]) { $sums = [System.Text.Encoding]::UTF8.GetString($sums) }
        $line = $sums -split "`n" | Where-Object { $_ -match "^([0-9a-f]{64}) [ *]$([regex]::Escape($name))\s*$" } | Select-Object -First 1
        if (-not $line) {
            throw "No SHA256 for $name in $base/SHA256SUMS. Set ubuntu_image_sha256, or verify_ubuntu_image = false."
        }
        $expected = $line.Substring(0, 64)
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $env:OVA).Hash.ToLower()
    if ($expected.ToLower() -ne $actual) {
        throw "SHA256 of $env:OVA is $actual, expected $expected."
    }
    Write-Host "Verified SHA256 of $env:OVA"
}

switch ($Action) {
    'image' {
        if ($env:OVA_SOURCE -match '^https?://') {
            if ((Test-Path -LiteralPath $env:OVA) -and (Get-Item -LiteralPath $env:OVA).Length -gt 0) {
                Write-Host "Using downloaded $env:OVA"
            } else {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $env:OVA) | Out-Null
                Write-Host "Downloading $env:OVA_SOURCE"
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $env:OVA_SOURCE -OutFile "$env:OVA.part" -UseBasicParsing
                Move-Item -Force -LiteralPath "$env:OVA.part" -Destination $env:OVA
            }
        } elseif (-not (Test-Path -LiteralPath $env:OVA)) {
            throw "$env:OVA not found."
        }
        Test-Ova
    }

    'create' {
        if (Get-VmState) { throw "A VirtualBox VM named $env:VM_NAME already exists." }

        $seed = Join-Path $env:WORK_DIR $env:VM_NAME
        if (Test-Path -LiteralPath $seed) { Remove-Item -Recurse -Force -LiteralPath $seed }
        $cidata = Join-Path $seed 'cidata'
        New-Item -ItemType Directory -Force -Path $cidata | Out-Null
        Write-Base64File $env:USERDATA_B64 (Join-Path $cidata 'user-data')
        Write-Base64File $env:METADATA_B64 (Join-Path $cidata 'meta-data')
        Write-Base64File $env:NETWORK_CONFIG_B64 (Join-Path $cidata 'network-config')
        $iso = Join-Path $seed 'seed.iso'
        New-SeedIso -Directory $cidata -Path $iso

        Write-Host "[$env:VM_NAME] Importing $env:OVA"
        Invoke-VBox @('import', $env:OVA, '--vsys', '0', '--vmname', $env:VM_NAME, '--ostype', 'Ubuntu_64',
            '--cpus', $env:CPU, '--memory', $env:MEMORY_MB, '--options', 'importtovdi')

        $info = Get-VmInfo
        $cfg = ($info | Where-Object { $_ -match '^CfgFile="(.*)"$' } | Select-Object -First 1)
        $null = $cfg -match '^CfgFile="(.*)"$'
        $vmDir = Split-Path -Parent ($Matches[1] -replace '\\\\', '\')

        # The first hard disk, as "<controller>-<port>-<device>"="<path>".
        $diskLine = $info | Where-Object { $_ -match '^"(.+)-(\d+)-(\d+)"="(.+\.(vdi|vmdk))"$' } | Select-Object -First 1
        if (-not $diskLine) { throw "No disk found on $env:VM_NAME after import." }
        $null = $diskLine -match '^"(.+)-(\d+)-(\d+)"="(.+\.(vdi|vmdk))"$'
        $controller = $Matches[1]; $port = $Matches[2]; $device = $Matches[3]
        $disk = $Matches[4] -replace '\\\\', '\'

        # VMDK cannot be resized; convert it if the import kept that format.
        if ($disk -match '\.vmdk$') {
            Write-Host "[$env:VM_NAME] Converting $disk to VDI"
            $vdi = [System.IO.Path]::ChangeExtension($disk, '.vdi')
            Invoke-VBox @('clonemedium', 'disk', $disk, $vdi, '--format', 'VDI')
            Invoke-VBox @('storageattach', $env:VM_NAME, '--storagectl', $controller, '--port', $port, '--device', $device, '--type', 'hdd', '--medium', $vdi)
            Invoke-VBox @('closemedium', 'disk', $disk, '--delete')
            $disk = $vdi
        }

        Write-Host "[$env:VM_NAME] Expanding disk to $($env:DISK_GB)GB"
        try {
            Invoke-VBox @('modifymedium', 'disk', $disk, '--resize', ([int]$env:DISK_GB * 1024))
        } catch {
            Write-Warning "[$env:VM_NAME] Could not expand the disk (is it already larger?): $_"
        }

        $nic = Get-NicArgs 1 $env:NETWORK_TYPE $env:NETWORK_NAME
        if ($env:MAC1) { $nic += @('--macaddress1', $env:MAC1) }
        # A second NIC (with fixed MACs, so the guest can tell the NICs apart).
        if ($env:SECONDARY_NETWORK_TYPE) {
            $nic += Get-NicArgs 2 $env:SECONDARY_NETWORK_TYPE $env:SECONDARY_NETWORK_NAME
            $nic += @('--macaddress2', $env:MAC2)
        }

        # Ubuntu cloud images log to ttyS0 and boot slowly without a serial port.
        Write-Host "[$env:VM_NAME] Setting network, serial console and cloud-init seed"
        Invoke-VBox (@('modifyvm', $env:VM_NAME) + $nic + @(
            '--uart1', '0x3F8', '4', '--uartmode1', 'file', (Join-Path $vmDir 'console.log'),
            '--description', 'Ubuntu 26.04 - managed by Terraform'))

        Invoke-VBox @('storagectl', $env:VM_NAME, '--name', 'cidata', '--add', 'sata', '--controller', 'IntelAhci', '--portcount', '1')
        Invoke-VBox @('storageattach', $env:VM_NAME, '--storagectl', 'cidata', '--port', '0', '--device', '0', '--type', 'dvddrive', '--medium', $iso)

        Write-Host "[$env:VM_NAME] Starting"
        $type = if ($env:START_TYPE) { $env:START_TYPE } else { 'headless' }
        Invoke-VBox @('startvm', $env:VM_NAME, '--type', $type)
    }

    'destroy' {
        $state = Get-VmState
        if ($state) {
            if ($state -ne 'poweroff' -and $state -ne 'aborted') {
                Invoke-VBox @('controlvm', $env:VM_NAME, 'poweroff') -IgnoreError
            }
            # Wait for the VM to stop and release its session lock.
            for ($i = 0; $i -lt 30; $i++) {
                $state = Get-VmState
                if ($state -eq 'poweroff' -or $state -eq 'aborted') {
                    & $env:VBOXMANAGE unregistervm $env:VM_NAME --delete 2>$null
                    if ($LASTEXITCODE -eq 0) { break }
                }
                Start-Sleep -Seconds 2
            }
            if (Get-VmState) { throw "Could not delete $env:VM_NAME." }
            # The seed ISO stays registered as a DVD medium; remove it.
            & $env:VBOXMANAGE closemedium dvd (Join-Path (Join-Path $env:WORK_DIR $env:VM_NAME) 'seed.iso') 2>$null
        } else {
            Write-Host "$env:VM_NAME does not exist, nothing to delete."
        }
        $seed = Join-Path $env:WORK_DIR $env:VM_NAME
        if (Test-Path -LiteralPath $seed) { Remove-Item -Recurse -Force -LiteralPath $seed }
    }
}
