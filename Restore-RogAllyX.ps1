#Requires -Version 5.1
<#
.SYNOPSIS
  ROG Ally X (RC72LA) - NON-DESTRUCTIVE reinstall of the ASUS Cloud Recovery software payload.

.DESCRIPTION
  Rebuilds every ASUS/ROG driver, service and app that Cloud Recovery deploys, inside the running
  Windows install. NOTHING is uninstalled, deleted or reset.

  Source of truth: ASUS's own RC72LA support catalog (rog.asus.com webapi -> dlcdnets.asus.com,
  the same CDN Cloud Recovery and MyASUS pull from). For every item the catalog supplies:
    - the official silent switches (ExeModule field: /SUPPRESSMSGBOXES /VERYSILENT /NORESTART)
    - the hardware IDs it targets (so only the variant matching YOUR sensor / card reader /
      fingerprint reader is installed, exactly like ASUS's updater does)
    - whether it needs a reboot

  Order (mirrors OEM provisioning): component-store repair -> AMD chipset -> AMD graphics ->
  ASUS System Control Interface v3 -> Armoury Crate Control Interface -> device drivers ->
  Dolby -> Store apps (MyASUS, GlideX, Realtek Audio Console) -> Armoury Crate SE ->
  Windows Update drivers -> AppX re-registration -> service matrix.

  Skipped on purpose: "MyASUS in WinRE for USB" (that is the wipe-and-reset Cloud Recovery
  boot tool) and the MCU firmware tool unless -IncludeFirmware.

.PARAMETER ListOnly       Show what would be installed, change nothing.
.PARAMETER PackageDir     Extra folder of ASUS files (.inf/.appx/.msix/.exe/.msi) to apply as well.
.PARAMETER IncludeFirmware Also launch the ROG MCU firmware tool (keep on AC power).
.PARAMETER SkipHealthCheck / SkipWindowsUpdate / SkipStore  Skip those stages.

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\Restore-RogAllyX.ps1
#>
[CmdletBinding()]
param(
    [string]$Model = 'RC72LA',
    [string]$PackageDir,
    [switch]$ListOnly,
    [switch]$IncludeFirmware,
    [switch]$SkipHealthCheck,
    [switch]$SkipWindowsUpdate,
    [switch]$SkipStore
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

function Step($m) { Write-Host "`n==== $m ====" -ForegroundColor Cyan }
function Info($m) { Write-Host "  [*] $m" -ForegroundColor Gray }
function Ok($m)   { Write-Host "  [+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "  [x] $m" -ForegroundColor Red }

$script:NeedReboot = $false
$script:Failed     = New-Object System.Collections.Generic.List[string]
$TrustedSigners    = 'ASUSTeK|ASUS|Advanced Micro Devices|Microsoft|Realtek|MediaTek|Texas Instruments|Dolby|Focal|Egis|Genesys|Bosch|TDK|InvenSense'

# ---------------------------------------------------------------------------
# Catalog helpers
# ---------------------------------------------------------------------------
function Get-InstallOrder($category, $title, $isStore) {
    switch -Regex ($title) {
        'WinRE'                           { return 99 }
        'MCU FW'                          { return 95 }
        'Armoury Crate SE'                { return 90 }
        'AMD Chipset'                     { return 10 }
        'AMD Graphics'                    { return 20 }
        'System Control Interface'        { return 30 }
        'Armoury Crate Control Interface' { return 40 }
    }
    if ($isStore) { return 80 }
    if ($category -eq 'Software and Utility') { return 70 }
    return 50
}

function Get-RogCatalog {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $api = "https://rog.asus.com/support/webapi/product/GetPDDrivers?website=global&model=$Model&cpu=$Model&osid=52&pdhashedid="
    $r = Invoke-RestMethod -Uri $api -UserAgent 'Mozilla/5.0' -TimeoutSec 60 -ErrorAction Stop
    foreach ($cg in $r.Result.Obj) {
        # newest release per title (ReleaseDate is yyyy/MM/dd, so string sort works)
        $cg.Files | Sort-Object ReleaseDate -Descending | Group-Object Title | ForEach-Object {
            $f       = $_.Group[0]
            $url     = $f.DownloadUrl.Global
            $leaf    = ([uri]$url).Segments[-1]
            $storeId = if ($leaf -match '^[0-9A-Za-z]{12}$') { $leaf.ToUpper() } else { $null }
            $silent  = if ($f.ExeModule -match '%%(.+)$') { $Matches[1].Trim() } else { '' }
            [pscustomobject]@{
                Order      = Get-InstallOrder $cg.Name $f.Title ([bool]$storeId)
                Category   = $cg.Name
                Title      = $f.Title
                Version    = $f.Version
                Size       = $f.FileSize
                Url        = $url
                File       = $leaf
                StoreId    = $storeId
                SilentArgs = $silent
                Reboot     = ($f.Reboot -eq '1')
                HwIds      = @($f.HardwareInfoList | ForEach-Object { $_.hardwareid } | Where-Object { $_ })
            }
        }
    }
}

$script:PresentHwIds = @()
function Test-HardwareMatch($ids) {
    if (-not $ids -or -not $script:PresentHwIds) { return $true }   # no targeting info -> install
    foreach ($h in $ids) {
        foreach ($p in $script:PresentHwIds) {
            if ($p.StartsWith($h, 'OrdinalIgnoreCase') -or $h.StartsWith($p + '&', 'OrdinalIgnoreCase')) { return $true }
        }
    }
    return $false
}

function Test-Signed($file) {
    $sig = Get-AuthenticodeSignature -FilePath $file
    if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match $TrustedSigners) { return $true }
    Bad "Signature check failed for $(Split-Path $file -Leaf) [$($sig.Status) / $($sig.SignerCertificate.Subject)] - not run"
    return $false
}

function Get-Download($item, $dir) {
    $out = Join-Path $dir $item.File
    if ((Test-Path $out) -and (Get-Item $out).Length -gt 0) { Info "Cached: $($item.File)"; return $out }
    Info "Downloading $($item.Title) $($item.Version) ($($item.Size))"
    try { Start-BitsTransfer -Source $item.Url -Destination $out -ErrorAction Stop }
    catch {
        try { Invoke-WebRequest -Uri $item.Url -OutFile $out -UserAgent 'Mozilla/5.0' -UseBasicParsing -ErrorAction Stop }
        catch { Bad "$($item.Title): download failed - $($_.Exception.Message)"; return $null }
    }
    return $out
}

function Invoke-Installer($path, $silentArgs, $title, [int]$timeoutMin = 45) {
    if ($path -match '\.msi$') {
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$path`" /qn /norestart" -PassThru
    } elseif ($silentArgs) {
        $p = Start-Process $path -ArgumentList $silentArgs -WorkingDirectory (Split-Path $path) -PassThru
    } else {
        Warn "$title has no silent mode - its window will open. Click Install (never Uninstall)."
        $p = Start-Process $path -WorkingDirectory (Split-Path $path) -PassThru
    }
    if (-not $p.WaitForExit($timeoutMin * 60000)) { Warn "$title still running after $timeoutMin min - continuing"; return }
    switch ($p.ExitCode) {
        0       { Ok "$title installed" }
        3010    { Ok "$title installed (reboot required)"; $script:NeedReboot = $true }
        8       { Warn "${title}: setup asks for a reboot first - re-run this script after restarting"; $script:NeedReboot = $true; $script:Failed.Add($title) }
        default { Bad "$title exited with code $($p.ExitCode)"; $script:Failed.Add($title) }
    }
}

# ---------------------------------------------------------------------------
# ListOnly: preview, no admin needed, nothing changed
# ---------------------------------------------------------------------------
if ($ListOnly) {
    if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
        $script:PresentHwIds = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object { $_.HardwareID } | Where-Object { $_ })
    }
    Get-RogCatalog | Sort-Object Order, Title | ForEach-Object {
        $action = if ($_.Title -match 'WinRE') { 'SKIP (reset tool)' }
                  elseif ($_.Title -match 'MCU FW' -and -not $IncludeFirmware) { 'SKIP (-IncludeFirmware)' }
                  elseif (-not (Test-HardwareMatch $_.HwIds)) { 'SKIP (hardware not present)' }
                  elseif ($_.StoreId) { "STORE $($_.StoreId)" }
                  elseif ($_.SilentArgs) { 'SILENT' } else { 'INTERACTIVE' }
        [pscustomobject]@{ Order = $_.Order; Title = $_.Title; Version = $_.Version; Size = $_.Size; Action = $action }
    } | Format-Table -AutoSize
    return
}

# ---------------------------------------------------------------------------
# 0. Privilege + host checks
# ---------------------------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script must run as Administrator." -ForegroundColor Red
    Write-Host "Right-click Start > 'Terminal (Admin)', then run:" -ForegroundColor Yellow
    Write-Host "  powershell.exe -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -ForegroundColor Yellow
    exit 1
}
if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Host "Relaunching in Windows PowerShell 5.1 (Appx/DISM/BITS modules need it)..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v) { $argList += "-$k" } } else { $argList += "-$k"; $argList += "`"$v`"" }
    }
    Start-Process powershell.exe -ArgumentList $argList -Verb RunAs -Wait
    exit
}

$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$Root   = Join-Path $env:ProgramData 'RogAllyRestore'
$LogDir = Join-Path $Root $stamp
$DlDir  = Join-Path $Root 'Downloads'
New-Item -ItemType Directory -Path $LogDir, $DlDir -Force | Out-Null
Start-Transcript -Path (Join-Path $LogDir 'transcript.log') | Out-Null
Write-Host "ROG Ally X non-destructive restore - logs: $LogDir" -ForegroundColor Cyan

# Keep the handheld awake while this process runs (no power settings are changed)
Add-Type -Namespace Win32 -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
[void][Win32.Power]::SetThreadExecutionState([uint32]2147483649)   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED

# ---------------------------------------------------------------------------
# 1. Device / power / disk checks
# ---------------------------------------------------------------------------
Step "Device check"
$cs = Get-CimInstance Win32_ComputerSystem
Info "Model: $($cs.Manufacturer) $($cs.Model)  BIOS: $((Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion)  OS build: $([Environment]::OSVersion.Version)"
if ($cs.Model -notmatch $Model) { Warn "Model is not $Model. Hardware matching still limits drivers to present devices." }
else { Ok "ROG Ally X ($Model) detected." }
$bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
if ($bat -and $bat.BatteryStatus -ne 2) { Warn "Not on AC power ($($bat.EstimatedChargeRemaining)%). Plug in - AMD graphics install is long." }
$free = [math]::Round((Get-PSDrive ($env:SystemDrive.TrimEnd(':'))).Free / 1GB, 1)
if ($free -lt 6) { Warn "Only $free GB free on $env:SystemDrive - about 3 GB of downloads plus install space is needed." } else { Info "$free GB free." }

# ---------------------------------------------------------------------------
# 2. Restore point + state snapshot (rollback material)
# ---------------------------------------------------------------------------
Step "Restore point and snapshot"
try {
    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
    Checkpoint-Computer -Description "Before ROG Ally X restore $stamp" -RestorePointType APPLICATION_INSTALL -ErrorAction Stop
    Ok "System restore point created."
} catch { Warn "Restore point not created ($($_.Exception.Message)). Windows allows one per 24h by default." }

$svcPattern  = 'ASUS|\bROG|Armoury|Aura|LightingService'   # \bROG so 'Program ...' services don't match
$appxPattern = 'ASUS|ArmouryCrate|ROG|Aura|ASUSHOTKEY|B9ECED6F|MyASUS|GlideX|Realtek|AMDRadeon|AdvancedMicroDevices|Dolby'

Get-CimInstance Win32_Service | Where-Object { $_.Name -match $svcPattern -or $_.DisplayName -match $svcPattern } |
    Select-Object Name, DisplayName, StartMode, State, PathName |
    Export-Csv (Join-Path $LogDir 'services-before.csv') -NoTypeInformation
Get-AppxPackage -AllUsers | Where-Object { $_.Name -match $appxPattern -or $_.Publisher -match 'ASUSTeK|Advanced Micro Devices|Realtek|Dolby' } |
    Select-Object Name, PackageFullName, Version, InstallLocation |
    Export-Csv (Join-Path $LogDir 'appx-before.csv') -NoTypeInformation
pnputil /enum-drivers > (Join-Path $LogDir 'drivers-before.txt')
Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' -and $_.Present } |
    Select-Object FriendlyName, Class, Status, InstanceId | Export-Csv (Join-Path $LogDir 'problem-devices-before.csv') -NoTypeInformation
Ok "Snapshot saved."

# ---------------------------------------------------------------------------
# 3. Component store repair FIRST so driver/app installs can bind (repair only)
# ---------------------------------------------------------------------------
if (-not $SkipHealthCheck) {
    Step "DISM RestoreHealth (repair only - no /StartComponentCleanup)"
    DISM /Online /Cleanup-Image /RestoreHealth
    Step "SFC /scannow"
    sfc /scannow
}

# ---------------------------------------------------------------------------
# 4. Stop hung ASUS processes (they restart on their own; no files touched)
# ---------------------------------------------------------------------------
Step "Stopping stuck ASUS processes"
'ArmouryCrate', 'ArmouryCrateSE', 'ArmouryCrateUserSessionHelper', 'ArmouryCrateKeyControl',
'AsusOptimizationStaging', 'ArmourySocketServer', 'ArmourySwAgent', 'AacAmbientLighting' | ForEach-Object {
    $running = Get-Process -Name $_ -ErrorAction SilentlyContinue
    if ($running) { $running | Stop-Process -Force -ErrorAction SilentlyContinue; Ok "Stopped $_" }
}

# ---------------------------------------------------------------------------
# 5. ASUS catalog: download + install everything Cloud Recovery provides
# ---------------------------------------------------------------------------
Step "Reading ASUS $Model catalog"
$script:PresentHwIds = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object { $_.HardwareID } | Where-Object { $_ })
try   { $catalog = @(Get-RogCatalog | Sort-Object Order, Title); Ok "$($catalog.Count) components listed." }
catch { Bad "ASUS catalog unreachable: $($_.Exception.Message)"; $catalog = @() }

$hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
if (-not $hasWinget) { Warn "winget (App Installer) missing - Store apps will be skipped. Update 'App Installer' from the Microsoft Store." }

foreach ($it in $catalog) {
    Step "$($it.Title) $($it.Version)"
    if ($it.Title -match 'WinRE') { Info "Skipped: this is the USB reset tool - it would wipe the device."; continue }
    if ($it.Title -match 'MCU FW' -and -not $IncludeFirmware) { Info "Skipped: firmware (use -IncludeFirmware)."; continue }
    if (-not (Test-HardwareMatch $it.HwIds)) { Info "Skipped: target hardware ($($it.HwIds[0])) not in this unit - other variant."; continue }

    if ($it.StoreId) {
        if ($SkipStore -or -not $hasWinget) { Info "Skipped Store app $($it.StoreId)"; continue }
        winget install --id $it.StoreId --source msstore --exact --silent --accept-package-agreements --accept-source-agreements
        $code = $LASTEXITCODE
        if ($code -ne 0) { winget list --id $it.StoreId --exact --accept-source-agreements | Out-Null }
        if ($code -eq 0 -or $LASTEXITCODE -eq 0) { Ok "$($it.Title) installed / already current" }
        else { Warn "$($it.Title): winget exit $code"; $script:Failed.Add($it.Title) }
        continue
    }

    $file = Get-Download $it $DlDir
    if (-not $file) { $script:Failed.Add($it.Title); continue }

    if ($file -match '\.zip$') {
        $ex = Join-Path $DlDir ([IO.Path]::GetFileNameWithoutExtension($file))
        Expand-Archive -Path $file -DestinationPath $ex -Force
        $exe = Get-ChildItem $ex -Recurse -Include *.exe, *.msi -ErrorAction SilentlyContinue |
               Sort-Object { $_.FullName.Split('\').Count }, Name | Select-Object -First 1
        if (-not $exe) { Warn "Nothing runnable inside $($it.File) - opened $ex"; Start-Process explorer.exe $ex; continue }
        if ($exe.Extension -eq '.msi' -or (Test-Signed $exe.FullName)) { Invoke-Installer $exe.FullName '' $it.Title }
        else { $script:Failed.Add($it.Title) }
    } else {
        if (-not (Test-Signed $file)) { $script:Failed.Add($it.Title); continue }
        $silent = $it.SilentArgs
        # ASUS "_Z_" packages (e.g. Dolby) are Inno Setup wrappers even when the catalog omits the switches
        if (-not $silent -and (Select-String -Path $file -Pattern 'Inno Setup Setup Data' -SimpleMatch -Quiet)) {
            $silent = '/SUPPRESSMSGBOXES /VERYSILENT /NORESTART'
        }
        Invoke-Installer $file $silent $it.Title
    }
    if ($it.Reboot) { $script:NeedReboot = $true }
}

# ---------------------------------------------------------------------------
# 6. Extra packages: C:\eSupport (factory payload, if any survived) and -PackageDir
# ---------------------------------------------------------------------------
$extraRoots = @("$env:SystemDrive\eSupport", $PackageDir) | Where-Object { $_ -and (Test-Path $_) }
foreach ($root in $extraRoots) {
    Step "Applying packages in $root"
    if (Get-ChildItem $root -Recurse -Filter *.inf -ErrorAction SilentlyContinue | Select-Object -First 1) {
        pnputil /add-driver "$root\*.inf" /subdirs /install
    }
    Get-ChildItem $root -Recurse -Include *.appx, *.appxbundle, *.msix, *.msixbundle -ErrorAction SilentlyContinue | ForEach-Object {
        $pkgFile = $_
        try { Add-AppxPackage -Path $pkgFile.FullName -ErrorAction Stop; Ok "Added $($pkgFile.Name)" }
        catch {
            if ($_.Exception.Message -match '0x80073D06') { Info "$($pkgFile.Name): a newer version is already installed - kept." }
            else { Warn "$($pkgFile.Name): $($_.Exception.Message)" }
        }
    }
    if ($root -eq $PackageDir) {
        Get-ChildItem $root -Recurse -Include *.exe, *.msi -ErrorAction SilentlyContinue | ForEach-Object {
            if ((Read-Host "  Run installer $($_.Name)? (y/N)") -match '^[yY]') {
                if ($_.Extension -eq '.msi' -or (Test-Signed $_.FullName)) { Invoke-Installer $_.FullName '' $_.Name }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 7. Windows Update drivers (ASUS/AMD extension INFs Cloud Recovery also carries)
# ---------------------------------------------------------------------------
if (-not $SkipWindowsUpdate) {
    Step "Windows Update: pending driver updates"
    try {
        $wu = New-Object -ComObject Microsoft.Update.Session
        $res = $wu.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $res.Updates) {
            if (-not $u.EulaAccepted) { Warn "Needs licence approval, skipped: $($u.Title)"; continue }
            if ($u.DriverClass -eq 'Firmware' -and -not $IncludeFirmware) { Info "Firmware via Windows Update skipped (use -IncludeFirmware): $($u.Title)"; continue }
            Info $u.Title; [void]$coll.Add($u)
        }
        if ($coll.Count -gt 0) {
            $d = $wu.CreateUpdateDownloader(); $d.Updates = $coll; [void]$d.Download()
            $i = $wu.CreateUpdateInstaller();  $i.Updates = $coll; $r = $i.Install()
            Ok "Windows Update drivers installed (result code $($r.ResultCode))"
            if ($r.RebootRequired) { $script:NeedReboot = $true }
        } else { Ok "No pending driver updates." }
    } catch { Warn "Windows Update scan failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
# 8. Re-apply staged ASUS/AMD drivers + rescan hardware
# ---------------------------------------------------------------------------
Step "Re-binding ASUS / AMD drivers"
try {
    $storeDrivers = @(Get-WindowsDriver -Online -ErrorAction Stop | Where-Object { $_.ProviderName -match 'ASUS|ASUSTeK|Advanced Micro Devices|AMD' })
    foreach ($d in $storeDrivers) { pnputil /add-driver "$($d.OriginalFileName)" /install | Out-Null }
    Ok "$($storeDrivers.Count) Driver Store packages re-bound."
} catch { Warn "Driver Store enumeration failed: $($_.Exception.Message)" }
pnputil /scan-devices | Out-Null

# ---------------------------------------------------------------------------
# 9. AppX re-registration (Armoury Crate SE, ASUSHOTKEY, Aura, MyASUS, AMD, Realtek, Dolby)
# ---------------------------------------------------------------------------
Step "Re-registering AppX packages"
$seen = @{}
Get-AppxPackage -AllUsers | Where-Object { $_.Name -match $appxPattern -or $_.Publisher -match 'ASUSTeK|Advanced Micro Devices|Realtek|Dolby' } |
ForEach-Object {
    $pkg = $_
    if ($seen[$pkg.PackageFullName] -or -not $pkg.InstallLocation) { return }
    $seen[$pkg.PackageFullName] = $true
    $manifest = Join-Path $pkg.InstallLocation 'AppXManifest.xml'
    if (Test-Path $manifest) {
        try { Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop; Ok "Registered $($pkg.Name) $($pkg.Version)" }
        catch {
            if ($_.Exception.Message -match '0x80073D02') { Info "$($pkg.Name): in use right now - already registered, fine." }
            else { Warn "$($pkg.Name): $($_.Exception.Message)" }
        }
    }
}
Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -match $appxPattern } | ForEach-Object {
    $prov = $_
    $manifest = [Environment]::ExpandEnvironmentVariables($prov.InstallLocation)
    if ($manifest -notmatch '\.xml$') { $manifest = Join-Path $manifest 'AppxManifest.xml' }
    if (Test-Path $manifest) {
        try { Add-AppxPackage -DisableDevelopmentMode -Register $manifest -ErrorAction Stop; Ok "Provisioned package registered: $($prov.DisplayName)" }
        catch {
            if ($_.Exception.Message -match '0x80073D02') { Info "Provisioned $($prov.DisplayName): in use - already registered, fine." }
            else { Warn "Provisioned $($prov.DisplayName): $($_.Exception.Message)" }
        }
    }
}

# ---------------------------------------------------------------------------
# 10. Service matrix stabilization
# ---------------------------------------------------------------------------
Step "Stabilizing ASUS / ROG services"
$coreServices = 'AsusAppService', 'ASUSSysControlService', 'ASUSOptimization', 'ROGLiveService',
                'ArmouryCrateService', 'ArmouryCrateControlInterface', 'LightingService',
                'ASUSSoftwareManager', 'ASUSSwitch', 'ASUSSystemAnalysis', 'ASUSSystemDiagnosis', 'AsusCertService'
$asusRoots = "$env:ProgramFiles\ASUS", "${env:ProgramFiles(x86)}\ASUS", "$env:ProgramData\ASUS"
# On-demand updaters: they run, do their job and stop by design - leave their startup type alone
$onDemand   = 'asus', 'asusm', 'AsusROGLSLService'
$svcPaths   = @(Get-CimInstance Win32_Service | ForEach-Object { $_.PathName })
$discovered = Get-Service | Where-Object { $_.Name -match $svcPattern -or $_.DisplayName -match $svcPattern } | Select-Object -ExpandProperty Name
foreach ($name in (@($coreServices) + @($discovered) | Sort-Object -Unique)) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) {
        $bin = Get-ChildItem $asusRoots -Recurse -Filter "$name.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $bin) { Info "$name not present on this build - skipped."; continue }
        if ($svcPaths -match [regex]::Escape($bin.FullName)) { Info "$name runs under another service name already - not duplicated."; continue }
        try {
            New-Service -Name $name -BinaryPathName "`"$($bin.FullName)`"" -DisplayName $name -StartupType Automatic -ErrorAction Stop | Out-Null
            Ok "Re-registered missing service $name -> $($bin.FullName)"
            $svc = Get-Service $name
        } catch { Bad "Could not register $name : $($_.Exception.Message)"; continue }
    }
    if ($onDemand -contains $name) { Info "$name : on-demand updater, left as $($svc.StartType)"; continue }
    try {
        Set-Service -Name $name -StartupType Automatic -ErrorAction Stop
        if ($svc.Status -ne 'Running') { Start-Service -Name $name -ErrorAction Stop }
        Ok "$name : Automatic / Running"
    } catch { Warn "$name : $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
# 11. Summary
# ---------------------------------------------------------------------------
Step "Summary"
$problem = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' })
if ($problem) { $problem | ForEach-Object { Warn "Device still not OK: $($_.FriendlyName) [$($_.InstanceId)]" } } else { Ok "All present devices report OK." }
if (Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'System Control Interface' }) { Ok "ASUS System Control Interface present." }
else { Warn "ASUS System Control Interface device not detected yet - check again after reboot." }

$after = Get-CimInstance Win32_Service | Where-Object { $_.Name -match $svcPattern -or $_.DisplayName -match $svcPattern } | Select-Object Name, StartMode, State
$after | Format-Table -AutoSize | Out-String | Write-Host
$after | Export-Csv (Join-Path $LogDir 'services-after.csv') -NoTypeInformation
if ($script:Failed.Count) { Bad "Needs attention: $($script:Failed -join '; ')" } else { Ok "Every applicable component installed." }

[void][Win32.Power]::SetThreadExecutionState([uint32]2147483648)   # allow sleep again

Write-Host "`nDone. Nothing was uninstalled or deleted. Downloads kept in $DlDir (re-runs reuse them)." -ForegroundColor Green
Write-Host "Rollback data: $LogDir" -ForegroundColor Green
if ($script:NeedReboot) { Write-Host "RESTART REQUIRED. After restarting, open Armoury Crate SE > Update Center (firmware, plugins)." -ForegroundColor Yellow }
else { Write-Host "Restart recommended, then open Armoury Crate SE > Update Center." -ForegroundColor Green }
Stop-Transcript | Out-Null
