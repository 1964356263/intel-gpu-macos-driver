# collect-windows.ps1: hardware inventory for the Intel GPU macOS driver project (v1).
#
# Run it on Windows on the same machine (most testers dual-boot). It records the hardware, firmware
# settings that Windows can see (Resizable BAR / Above 4G, Secure Boot), GPU drivers, monitors (EDID)
# and a dxdiag report. Read-only; no admin needed (an admin run adds the TPM and Secure Boot details).
# PowerShell 5.1 (built into Windows 10/11); no modules to install.
#
#   powershell -ExecutionPolicy Bypass -File collect-windows.ps1 [-OutDir <folder>]
#
# Writes xe-report-XR-xxxxxxxx.zip in the current folder (or -OutDir). Serial numbers, UUIDs, MAC
# addresses, user and computer names and Wi-Fi network names are removed. It never reads ACPI tables
# or anything about the Windows product key, and it stops without a file if the output contains
# anything shaped like a product key.

param([string]$OutDir = (Get-Location).Path)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$CollectorVersion = 1
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$Budget = 60

function Left { [int]($Budget - $sw.Elapsed.TotalSeconds) }

$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$b = New-Object byte[] 4
$rng.GetBytes($b)
$ID = 'XR-' + (($b | ForEach-Object { $_.ToString('X2') }) -join '')
$Name = "xe-report-$ID"
$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("xe-report-" + [guid]::NewGuid().ToString('N'))
$W = Join-Path $Tmp $Name
foreach ($d in 'system', 'gpu', 'display', 'logs') { New-Item -ItemType Directory -Force -Path (Join-Path $W $d) | Out-Null }
$Log = Join-Path $W 'collector.txt'
$Skipped = New-Object System.Collections.ArrayList
$Literals = New-Object System.Collections.ArrayList   # private values to remove; never written

function Note([string]$m) { Add-Content -Path $Log -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8 }
function Skip([string]$m) { [void]$Skipped.Add($m); Note "skipped: $m" }
function Lit([string]$kind, $v) {
    if ($null -eq $v) { return }
    $s = ([string]$v).Trim()
    if ($s.Length -lt 4) { return }
    if ($s -match '^(To be filled by O\.E\.M\.|Default string|System Serial Number|Not Specified|None|0+|Not Applicable|N/A|Unknown|Base Board Serial Number|Chassis Serial Number)$') { return }
    [void]$Literals.Add([pscustomobject]@{ Kind = $kind; Value = $s })
}
# Section 'file' { block }: run the block, write its output as text; errors go into the file
function Section([string]$file, [scriptblock]$block) {
    $path = Join-Path $W $file
    if ((Left) -lt 3) { Skip "$file : time budget used up"; return }
    try { $out = & $block 2>&1 | Out-String -Width 250 }
    catch { $out = "error: $($_.Exception.Message)" }
    Add-Content -Path $path -Value $out -Encoding UTF8
}

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "Intel GPU: collecting the Windows hardware inventory ($ID), about a minute..."
Set-Content -Path $Log -Encoding UTF8 -Value @(
    "collector: collect-windows.ps1 v$CollectorVersion",
    "report id: $ID",
    "started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')",
    "powershell: $($PSVersionTable.PSVersion)  admin: $IsAdmin",
    "")
if (-not $IsAdmin) { Skip "admin-only details (TPM version via Get-Tpm, Confirm-SecureBootUEFI): not run as administrator; Secure Boot and TPM presence come from the registry and device list instead" }

# ------------------------------------------------------------ private values (never written)
Lit user $env:USERNAME
Lit host $env:COMPUTERNAME
Lit host $env:USERDOMAIN
$un = $env:USERNAME -replace "'", "''"
try { Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True AND Name='$un'" -ErrorAction Stop | ForEach-Object { Lit user $_.FullName } } catch {}
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    Lit host $cs.Name; Lit host $cs.DNSHostName; Lit user (($cs.UserName -split '\\')[-1])
    if ($cs.Domain -ne 'WORKGROUP') { Lit host $cs.Domain }
} catch {}
try { Get-CimInstance Win32_BIOS | ForEach-Object { Lit serial $_.SerialNumber } } catch {}
try { Get-CimInstance Win32_BaseBoard | ForEach-Object { Lit serial $_.SerialNumber } } catch {}
try { Get-CimInstance Win32_SystemEnclosure | ForEach-Object { Lit serial $_.SerialNumber; Lit serial $_.SMBIOSAssetTag } } catch {}
try { Get-CimInstance Win32_ComputerSystemProduct | ForEach-Object { Lit serial $_.IdentifyingNumber; Lit uuid $_.UUID } } catch {}
try { Get-CimInstance Win32_DiskDrive | ForEach-Object { Lit serial $_.SerialNumber } } catch {}
try { Get-CimInstance Win32_PhysicalMedia | ForEach-Object { Lit serial $_.SerialNumber } } catch {}
try { Lit uuid (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid } catch {}
try {
    Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.MACAddress } | ForEach-Object {
        $m = $_.MACAddress
        Lit mac $m; Lit mac ($m -replace ':', '-'); if (($m -replace ':', '') -match '[A-Fa-f]') { Lit mac ($m -replace ':', '') }
    }
} catch {}
try {
    $wl = & netsh.exe wlan show profiles 2>$null
    # "    All User Profile     : name" (the label is translated; the layout is not)
    foreach ($l in $wl) {
        if ($l -match '^\s{4,}\S[^:]*\s:\s(.+)$') {
            $s = $Matches[1].Trim()
            if ($s.Length -ge 3 -and -not $s.StartsWith('<')) { [void]$Literals.Add([pscustomobject]@{ Kind = 'ssid'; Value = $s }) }
        }
    }
} catch {}

# ------------------------------------------------------------ system
Note 'system'
Section 'system\os.txt' {
    Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture, InstallDate, LastBootUpTime
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    "DisplayVersion: $($cv.DisplayVersion)  UBR: $($cv.UBR)  EditionID: $($cv.EditionID)"
}
Section 'system\hardware.txt' {
    '== System'; Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, SystemFamily, SystemSKUNumber, TotalPhysicalMemory, PCSystemType
    '== Board'; Get-CimInstance Win32_BaseBoard | Select-Object Manufacturer, Product, Version
    '== BIOS'; Get-CimInstance Win32_BIOS | Select-Object Manufacturer, SMBIOSBIOSVersion, BIOSVersion, ReleaseDate, SMBIOSMajorVersion, SMBIOSMinorVersion
    '== CPU'; Get-CimInstance Win32_Processor | Select-Object Name, Manufacturer, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed
    '== Memory'; Get-CimInstance Win32_PhysicalMemory | Select-Object Manufacturer, PartNumber, Capacity, ConfiguredClockSpeed
}
Section 'system\security.txt' {
    $sb = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue
    "Secure Boot (registry UEFISecureBootEnabled): $(if ($null -eq $sb) { 'unknown (legacy BIOS?)' } else { $sb.UEFISecureBootEnabled })"
    if ($IsAdmin) {
        try { "Confirm-SecureBootUEFI: $(Confirm-SecureBootUEFI -ErrorAction Stop)" } catch { "Confirm-SecureBootUEFI: $($_.Exception.Message)" }
        try { Get-Tpm -ErrorAction Stop | Select-Object TpmPresent, TpmReady, TpmEnabled, ManufacturerIdTxt, ManufacturerVersion } catch { "Get-Tpm: $($_.Exception.Message)" }
    }
    '== TPM devices'
    Get-PnpDevice -Class SecurityDevices -PresentOnly -ErrorAction SilentlyContinue | Select-Object FriendlyName, Status
    "Firmware type: $(if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { 'UEFI' } else { 'unknown' })"
}
Section 'system\storage-network.txt' {
    '== Disks (model only)'
    Get-CimInstance Win32_DiskDrive | Select-Object Model, InterfaceType, MediaType, @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB) } }
    '== Network adapters (model only)'
    Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.PhysicalAdapter } | Select-Object Name, Manufacturer, AdapterType
}

# ------------------------------------------------------------ GPUs
Note 'gpu'
$gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
Section 'gpu\video-controllers.txt' {
    $gpus | Select-Object Name, PNPDeviceID, DriverVersion, DriverDate, InstalledDisplayDrivers, VideoProcessor, AdapterCompatibility,
        AdapterRAM, CurrentHorizontalResolution, CurrentVerticalResolution, CurrentRefreshRate, Status | Format-List
}
$gpuSummary = New-Object System.Collections.ArrayList
Section 'gpu\pnp-display.txt' {
    $devs = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue)
    foreach ($dev in $devs) {
        "== $($dev.FriendlyName)  [$($dev.Status), present: $($dev.Present)]"
        "InstanceId: $($dev.InstanceId)"
        $keys = 'DEVPKEY_Device_HardwareIds', 'DEVPKEY_Device_DriverVersion', 'DEVPKEY_Device_DriverDate', 'DEVPKEY_Device_DriverProvider',
            'DEVPKEY_Device_DriverInfPath', 'DEVPKEY_Device_LocationInfo', 'DEVPKEY_Device_LocationPaths', 'DEVPKEY_Device_ProblemCode',
            'DEVPKEY_PciDevice_CurrentLinkSpeed', 'DEVPKEY_PciDevice_CurrentLinkWidth', 'DEVPKEY_PciDevice_MaxLinkSpeed', 'DEVPKEY_PciDevice_MaxLinkWidth'
        foreach ($k in $keys) {
            $p = Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName $k -ErrorAction SilentlyContinue
            if ($p -and $null -ne $p.Data) { "{0}: {1}" -f ($k -replace '^DEVPKEY_', ''), (($p.Data | ForEach-Object { "$_" }) -join '; ') }
        }
        # memory ranges = BARs; one larger than 256 MB, or one above 4 GB, means Resizable BAR / Above 4G decoding is on
        $bars = @(); $bars4g = @()
        try {
            $ent = Get-CimInstance Win32_PnPEntity -Filter ("DeviceID='" + ($dev.InstanceId -replace '\\', '\\') + "'") -ErrorAction Stop
            $mem = @(Get-CimAssociatedInstance -InputObject $ent -ResultClassName Win32_DeviceMemoryAddress -ErrorAction Stop)
            foreach ($m in $mem) {
                $size = [uint64]$m.EndingAddress - [uint64]$m.StartingAddress + 1
                "memory range: 0x{0:X} - 0x{1:X} ({2} MB)" -f [uint64]$m.StartingAddress, [uint64]$m.EndingAddress, [math]::Round($size / 1MB)
                $bars += $size
                $bars4g += ([uint64]$m.StartingAddress -ge 4GB)
            }
        } catch { "memory ranges: $($_.Exception.Message)" }
        $hw = ''
        if ($dev.InstanceId -match 'VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})&SUBSYS_([0-9A-F]{8})&REV_([0-9A-F]{2})') {
            $hw = "{0}:{1} sub {2}:{3} rev {4}" -f $Matches[1], $Matches[2], $Matches[3].Substring(4, 4), $Matches[3].Substring(0, 4), $Matches[4]
        }
        $big = ($bars | Measure-Object -Maximum).Maximum
        $hi = @($bars4g | Where-Object { $_ }).Count
        $rebar = if ($null -eq $big) { 'BARs unknown (no memory ranges reported)' } elseif ($big -gt 256MB) { "largest BAR $([math]::Round($big / 1MB)) MB (Resizable BAR active)" } else { "largest BAR $([math]::Round($big / 1MB)) MB (no Resizable BAR)" }
        if ($hi) { $rebar += ", $hi range(s) above 4 GB (Above 4G decoding on)" }
        $ver = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName DEVPKEY_Device_DriverVersion -ErrorAction SilentlyContinue).Data
        $dat = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName DEVPKEY_Device_DriverDate -ErrorAction SilentlyContinue).Data
        if ($dev.Present) { [void]$gpuSummary.Add(("{0}  {1}  driver {2} ({3})  {4}" -f $dev.FriendlyName, $hw, $ver, $(if ($dat) { $dat.ToString('yyyy-MM-dd') } else { '?' }), $rebar)) }
        ''
    }
}
Section 'gpu\signed-drivers.txt' {
    Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceClass='DISPLAY' OR DeviceClass='MEDIA' OR DeviceClass='MONITOR'" -ErrorAction SilentlyContinue |
        Select-Object DeviceClass, DeviceName, Manufacturer, DriverProviderName, DriverVersion, DriverDate, InfName, HardWareID | Format-List
}
Section 'gpu\all-pci.txt' {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\*' } | Sort-Object InstanceId |
        Select-Object Class, FriendlyName, @{ n = 'HardwareId'; e = { ($_.InstanceId -split '\\')[1] } } | Format-Table -AutoSize
}

# ------------------------------------------------------------ monitors (EDID)
Note 'display'
function Get-EdidByte([byte[]]$e, [int]$i) { if ($i -lt $e.Length) { return [int]$e[$i] } else { return 0 } }
function Clean-Edid([byte[]]$e) {
    $c = [byte[]]$e.Clone()
    if ($c.Length -lt 128) { return $c }
    for ($i = 12; $i -le 15; $i++) { $c[$i] = 0 }                       # serial number
    foreach ($d in 54, 72, 90, 108) {                                     # serial-number text descriptor
        if ($c[$d] -eq 0 -and $c[$d + 1] -eq 0 -and $c[$d + 3] -eq 0xFF) { $c[$d + 5] = 10; for ($j = $d + 6; $j -le $d + 17; $j++) { $c[$j] = 32 } }
    }
    $sum = 0; for ($i = 0; $i -lt 127; $i++) { $sum += $c[$i] }
    $c[127] = [byte]((256 - ($sum % 256)) % 256)
    return $c
}
function Describe-Edid([byte[]]$e) {
    if ($e.Length -lt 128) { return "short EDID ($($e.Length) bytes)" }
    $m = $e[8] * 256 + $e[9]
    $mfg = [string][char](64 + (($m -shr 10) -band 31)) + [char](64 + (($m -shr 5) -band 31)) + [char](64 + ($m -band 31))
    $prod = '{0:x4}' -f ($e[11] * 256 + $e[10])
    $name = ''
    foreach ($d in 54, 72, 90, 108) {
        if ($e[$d] -eq 0 -and $e[$d + 1] -eq 0 -and $e[$d + 3] -eq 0xFC) {
            for ($j = $d + 5; $j -le $d + 17; $j++) { if ($e[$j] -eq 10) { break }; $name += [char]$e[$j] }
        }
    }
    $pc = ($e[54] + $e[55] * 256) * 10000
    $w = $e[56] + ($e[58] -shr 4) * 256; $ht = $w + $e[57] + ($e[58] -band 15) * 256
    $h = $e[59] + ($e[61] -shr 4) * 256; $vt = $h + $e[60] + ($e[61] -band 15) * 256
    $hz = if ($ht * $vt -gt 0) { $pc / ($ht * $vt) } else { 0 }
    return ('{0} {1} "{2}" preferred {3}x{4}@{5:N2}, EDID {6}.{7}, {8} extension block(s)' -f $mfg, $prod, $name.Trim(), $w, $h, $hz, $e[18], $e[19], $e[126])
}
$present = @{}
Get-PnpDevice -Class Monitor -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object { $present[$_.InstanceId.ToUpper()] = $true }
$monSummary = New-Object System.Collections.ArrayList
$n = 0
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY' -ErrorAction SilentlyContinue | ForEach-Object {
    $model = $_.PSChildName
    Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
        $inst = "DISPLAY\$model\$($_.PSChildName)"
        $edid = (Get-ItemProperty (Join-Path $_.PSPath 'Device Parameters') -Name EDID -ErrorAction SilentlyContinue).EDID
        if ($edid) {
            $n++
            $clean = Clean-Edid ([byte[]]$edid)
            $hex = ($clean | ForEach-Object { $_.ToString('x2') }) -join ''
            $isNow = $present.ContainsKey($inst.ToUpper())
            $desc = Describe-Edid $clean
            Set-Content -Path (Join-Path $W "display\edid-$n-$model.hex") -Value $hex -Encoding ASCII
            Add-Content -Path (Join-Path $W 'display\monitors.txt') -Value ("monitor {0}: {1} ({2}) {3}" -f $n, $model, $(if ($isNow) { 'connected now' } else { 'seen before' }), $desc) -Encoding UTF8
            if ($isNow) { [void]$monSummary.Add("$model  $desc") }
        }
    }
}
Section 'display\connections.txt' {
    Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction SilentlyContinue | Select-Object InstanceName, VideoOutputTechnology, Active
    '(VideoOutputTechnology: 10 = DisplayPort, 5 = HDMI, 11 = embedded DisplayPort (laptop panel), 0x80000000 = internal)'
}

# ------------------------------------------------------------ dxdiag
Note 'dxdiag'
$dx = Join-Path $Tmp 'dxdiag.txt'
$wait = [math]::Max(5, [math]::Min(45, (Left) - 5))
try {
    $p = Start-Process -FilePath "$env:SystemRoot\System32\dxdiag.exe" -ArgumentList '/whql:off', '/t', "`"$dx`"" -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit($wait * 1000)) { try { $p.Kill() } catch {}; Skip "dxdiag /t: did not finish in $wait s" }
    $t0 = Get-Date
    while (-not (Test-Path $dx) -and ((Get-Date) - $t0).TotalSeconds -lt 3) { Start-Sleep -Milliseconds 250 }
    if (Test-Path $dx) {
        Get-Content $dx | Where-Object { $_ -notmatch '^\s*(Machine name|Machine Id|User Name)\s*:' } |
            Set-Content (Join-Path $W 'gpu\dxdiag.txt') -Encoding UTF8
    } elseif ($p.HasExited) { Skip 'dxdiag /t: wrote no file' }
} catch { Skip "dxdiag /t: $($_.Exception.Message)" }

# ------------------------------------------------------------ summary
Note 'summary'
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
$csys = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$bb = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
$bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
$cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
$sbv = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue).UEFISecureBootEnabled
$tpm = @(Get-PnpDevice -Class SecurityDevices -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'Trusted Platform' })
$S = New-Object System.Collections.ArrayList
[void]$S.Add("Intel GPU: Windows hardware inventory $ID")
[void]$S.Add("Created $(Get-Date -Format 'yyyy-MM-dd HH:mm zzz') by collect-windows.ps1 v$CollectorVersion")
[void]$S.Add('')
[void]$S.Add("Windows      $($os.Caption) $($cv.DisplayVersion) build $($os.BuildNumber).$($cv.UBR) $($os.OSArchitecture)")
[void]$S.Add("Machine      $($csys.Manufacturer) $($csys.Model) $($csys.SystemFamily)")
[void]$S.Add("Board        $($bb.Manufacturer) $($bb.Product) $($bb.Version)")
[void]$S.Add("BIOS         $($bios.Manufacturer) $($bios.SMBIOSBIOSVersion) ($(if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') }))")
[void]$S.Add("CPU          $($cpu.Name), $($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) threads, $([math]::Round($csys.TotalPhysicalMemory / 1GB)) GB RAM")
[void]$S.Add("Secure Boot  $(switch ($sbv) { 1 { 'on' } 0 { 'off' } default { 'unknown' } })   TPM: $(if ($tpm.Count) { $tpm[0].FriendlyName } else { 'not found' })")
[void]$S.Add('')
[void]$S.Add('GPUs')
if ($gpuSummary.Count) { foreach ($g in $gpuSummary) { [void]$S.Add("  $g") } } else { [void]$S.Add('  none found') }
[void]$S.Add('')
[void]$S.Add('Monitors connected now')
if ($monSummary.Count) { foreach ($m in $monSummary) { [void]$S.Add("  $m") } } else { [void]$S.Add('  no EDID found in the registry') }
[void]$S.Add('')
[void]$S.Add('Note: Windows cannot show the "Above 4G decoding" BIOS switch directly. A GPU memory range above')
[void]$S.Add('4 GB or larger than 256 MB (see gpu\pnp-display.txt) means it is on and Resizable BAR is active.')
if ($Skipped.Count) {
    [void]$S.Add('')
    [void]$S.Add('Not collected')
    foreach ($s in $Skipped) { [void]$S.Add("  - $s") }
}
[void]$S.Add('')
[void]$S.Add('Removed before packing: serial numbers, UUIDs, machine GUID, MAC addresses, user and computer names,')
[void]$S.Add('Wi-Fi network names, monitor serial numbers (EDID). ACPI tables and product keys are never read.')
Set-Content -Path (Join-Path $W 'summary.txt') -Value $S -Encoding UTF8

# ------------------------------------------------------------ redaction and checks
Note 'redaction'
$lits = $Literals | Sort-Object { $_.Value.Length } -Descending
$files = Get-ChildItem -Path $W -Recurse -File
foreach ($f in $files) {
    $t = [System.IO.File]::ReadAllText($f.FullName)
    foreach ($l in $lits) { $t = $t -replace [regex]::Escape($l.Value), "<$($l.Kind)-redacted>" }
    $t = $t -replace '(?i)([A-Z]:\\Users\\)[^\\\s"'']+', '$1USER'
    $t = $t -replace '(?i)\b([0-9A-F]{2}[:-]){5}[0-9A-F]{2}\b', 'xx-xx-xx-xx-xx-xx'
    $t = $t -replace '(?im)^(\s*(Serial ?Number|SerialNumber|UUID|IdentifyingNumber|MACAddress|Machine (name|Id))\s*:\s*).+$', '$1<redacted>'
    [System.IO.File]::WriteAllText($f.FullName, $t, (New-Object System.Text.UTF8Encoding($false)))
}
$fail = $false
foreach ($f in (Get-ChildItem -Path $W -Recurse -File)) {
    $t = [System.IO.File]::ReadAllText($f.FullName)
    foreach ($l in $lits) {
        if ($t.IndexOf($l.Value, [StringComparison]::OrdinalIgnoreCase) -ge 0) { Write-Warning "privacy check: a $($l.Kind) value is still present in $($f.Name)"; $fail = $true }
    }
    if ($t -cmatch '\b[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}\b') {
        Write-Warning "privacy check: $($f.Name) contains something shaped like a Windows product key"; $fail = $true
    }
}
if ($fail) {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
    Write-Host 'No report was written. Please open an issue and say that the privacy check failed (no file needed).'
    exit 3
}

# ------------------------------------------------------------ pack
Add-Content -Path $Log -Value @('', "finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz') ($([int]$sw.Elapsed.TotalSeconds) s)", 'privacy check: passed') -Encoding UTF8
$man = Get-ChildItem -Path $W -Recurse -File | Sort-Object FullName | ForEach-Object {
    $h = Get-FileHash -Algorithm SHA256 -Path $_.FullName
    '{0}  ./{1}' -f $h.Hash.ToLower(), ($_.FullName.Substring($W.Length + 1) -replace '\\', '/')
}
Set-Content -Path (Join-Path $W 'manifest.txt') -Value $man -Encoding ASCII
$zip = Join-Path $OutDir "$Name.zip"
try { Compress-Archive -Path $W -DestinationPath $zip -Force -ErrorAction Stop }
catch { Write-Host "could not write $zip : $($_.Exception.Message)"; Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue; exit 1 }
Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "Report ID: $ID"
Write-Host "File:      $zip"
Write-Host "Took $([int]$sw.Elapsed.TotalSeconds) s. Nothing was uploaded. Attach the file to your GitHub issue and put the report ID in the form."
