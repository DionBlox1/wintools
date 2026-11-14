# ============================================================================
# AUTO-ELEVATION CHECK (Supports both local .ps1 and irm | iex execution)
# ============================================================================
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    $psExe = (Get-Process -Id $PID).Path

    try {
        if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
            # Running from a local .ps1 file
            Start-Process -FilePath $psExe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -ErrorAction Stop
        } else {
            # Running in-memory via irm <url> | iex
            $scriptBody = if ($MyInvocation.MyCommand.ScriptContents) {
                $MyInvocation.MyCommand.ScriptContents
            } else {
                $MyInvocation.MyCommand.Definition
            }

            if ([string]::IsNullOrWhiteSpace($scriptBody)) {
                throw "Unable to capture in-memory script content for elevation."
            }

            $tempScript = Join-Path $env:TEMP "WinUpdateMultiTool_Elevated.ps1"
            Set-Content -Path $tempScript -Value $scriptBody -Encoding UTF8 -Force

            $cmd = "& '$tempScript'; Remove-Item -Path '$tempScript' -Force -ErrorAction SilentlyContinue"
            Start-Process -FilePath $psExe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`"" -ErrorAction Stop
        }
        return
    } catch {
        Write-Host ""
        Write-Host "============================================================================" -ForegroundColor Red
        Write-Host "[ERROR] ADMINISTRATOR PRIVILEGES REQUIRED" -ForegroundColor Red
        Write-Host "============================================================================" -ForegroundColor Red
        Write-Host "Elevation was cancelled or failed: $($_.Exception.Message)"
        Write-Host "Please open PowerShell as Administrator and re-run the command."
        Write-Host ""
        if ($Host.Name -eq 'ConsoleHost') {
            Write-Host "Press any key to exit..." -NoNewline
            $null = [Console]::ReadKey($true)
            Write-Host ""
        }
        return
    }
}

# Set console title
$Host.UI.RawUI.WindowTitle = "Windows Update Multitool"

# Detect execution context: local .ps1 file vs in-memory/temp elevated script
$tempDirNormalized = $env:TEMP.TrimEnd('\')
if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot) -and ($PSScriptRoot.TrimEnd('\') -ne $tempDirNormalized)) {
    $BaseDir = $PSScriptRoot
} else {
    $BaseDir = "C:\WinUpdateMultiTool"
}

$MsuDir  = Join-Path $BaseDir "MSUUpdates"
$LogFile = Join-Path $BaseDir "WinUpdate_Multitool.log"

# Ensure base and MSUUpdates folders exist
foreach ($dir in @($BaseDir, $MsuDir)) {
    if (-not (Test-Path -Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
}

# ============================================================================
# HELPER & SHARED FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogFile -Value "[$timestamp] $Message" -ErrorAction SilentlyContinue
}

function Pause-Script {
    param([string]$Message = "Press any key to continue...")
    Write-Host $Message -NoNewline
    if ($Host.Name -eq 'ConsoleHost') {
        $null = [Console]::ReadKey($true)
        Write-Host ""
    } else {
        Read-Host
    }
}

function Read-Choice {
    param(
        [string]$Prompt,
        [string[]]$ValidKeys
    )
    Write-Host $Prompt -NoNewline
    $upperKeys = $ValidKeys | ForEach-Object { $_.ToUpper() }

    if ($Host.Name -eq 'ConsoleHost') {
        while ($true) {
            $keyInfo = [Console]::ReadKey($true)
            $char = $keyInfo.KeyChar.ToString().ToUpper()
            if ($upperKeys -contains $char) {
                Write-Host $char
                return $char
            }
        }
    } else {
        while ($true) {
            $inputStr = (Read-Host).Trim().ToUpper()
            if ($upperKeys -contains $inputStr) {
                return $inputStr
            }
            Write-Host $Prompt -NoNewline
        }
    }
}

function Close-SettingsApp {
    $procs = Get-Process -Name "SystemSettings" -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Log "Closing open Windows Settings app..."
        Write-Host "Closing Windows Settings app..."
        $procs | ForEach-Object { $_.CloseMainWindow() | Out-Null }
        Start-Sleep -Seconds 2
        
        $procs = Get-Process -Name "SystemSettings" -ErrorAction SilentlyContinue
        if ($procs) {
            Write-Log "Settings app did not close gracefully; force-killing SystemSettings.exe."
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
}

function Clear-UpdateCache {
    param([bool]$ShouldClean)
    if ($ShouldClean) {
        Write-Log "Clearing SoftwareDistribution cache..."
        Write-Host "Clearing SoftwareDistribution cache..."
        Stop-Service -Name "bits" -Force -ErrorAction SilentlyContinue
        $sdPath = Join-Path $env:windir "SoftwareDistribution"
        Remove-Item -Path $sdPath -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path $sdPath -ItemType Directory -Force | Out-Null
        Start-Service -Name "bits" -ErrorAction SilentlyContinue
        Write-Log "SoftwareDistribution cache cleared and recreated."
    }
}

function Invoke-DelayedReboot {
    param([bool]$CleanCache = $false)
    Write-Host ""
    Write-Host "Save everything before you restart. Press any key to prepare for restart now."
    Pause-Script ""

    Close-SettingsApp
    if ($CleanCache) {
        Stop-Service -Name "wuauserv" -Force -ErrorAction SilentlyContinue
        Clear-UpdateCache -ShouldClean $true
    }

    Write-Log "Initiating 15-second delayed PC restart."
    Write-Host ""
    Write-Host "Multitool is ready to restart your computer. It will restart in 15 seconds..."
    & shutdown.exe /r /t 15 /c "Windows Update Multitool is restarting your computer in 15 seconds." | Out-Null

    Write-Host "Press [C] within 15 seconds to CANCEL the restart... " -NoNewline
    $cancelled = $false

    if ($Host.Name -eq 'ConsoleHost') {
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.KeyChar.ToString().ToUpper() -eq 'C') {
                    $cancelled = $true
                    break
                }
            }
            Start-Sleep -Milliseconds 100
        }
    } else {
        $resp = Read-Host "`nType C and press Enter to cancel"
        if ($resp.Trim().ToUpper() -eq 'C') { $cancelled = $true }
    }

    if ($cancelled) {
        & shutdown.exe /a | Out-Null
        Write-Log "User cancelled the scheduled 15-second PC restart."
        Write-Host "`n[CANCELLED] Automatic restart has been aborted." -ForegroundColor Yellow
        Start-Service -Name "bits" -ErrorAction SilentlyContinue
        Start-Service -Name "wuauserv" -ErrorAction SilentlyContinue
        Pause-Script
        return
    }
    exit 0
}

function Invoke-BatteryCheckAndScan {
    $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $battery) {
        Write-Log "No battery detected (desktop/AC-only device)."
    } else {
        $charge = $battery.EstimatedChargeRemaining
        $status = $battery.BatteryStatus
        Write-Log "Battery detected: Charge=$charge%, Status=$status"

        if ($status -eq 1) {
            Write-Host ""
            if ($charge -le 20) {
                Write-Log "[WARNING] Low battery ($charge%) and running on battery power."
                Write-Host "[WARNING] Your device battery is low ($charge%) and running on battery power. It is not recommended to attempt to update before charging." -ForegroundColor Red
            } else {
                Write-Log "[NOTICE] Running on battery power ($charge%) without AC adapter."
                Write-Host "[NOTICE] Your device is running on battery power ($charge%). It is recommended to plug in the AC adapter during the update." -ForegroundColor Yellow
            }

            $ans = Read-Choice -Prompt "Do you want to continue anyway? (Y/N): " -ValidKeys @('Y', 'N')
            if ($ans -eq 'N') {
                Write-Log "User aborted update scan due to battery warning."
                return
            }
            Write-Log "User chose to continue update scan despite battery warning."
        }
    }

    Write-Host ""
    Write-Host "Triggering Windows Update scan and checking update status..."
    Write-Log "Triggering usoclient StartScan and querying update status..."
    Start-Process -FilePath "usoclient.exe" -ArgumentList "StartScan" -WindowStyle Hidden -ErrorAction SilentlyContinue

    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        Write-Host "Scanning for standard and optional updates (this may take a moment)..."
        $result   = $searcher.Search("IsInstalled=0 and IsHidden=0")

        $req = @($result.Updates | Where-Object { $_.BrowseOnly -eq $false })
        $opt = @($result.Updates | Where-Object { $_.BrowseOnly -eq $true })

        $msg1 = "Pending Standard Updates: $($req.Count)"
        Write-Host $msg1
        Write-Log $msg1
        foreach ($u in $req) {
            Write-Host "  - $($u.Title)"
            Write-Log "  - $($u.Title)"
        }

        $msg2 = "Optional Updates Available: $($opt.Count)"
        Write-Host $msg2
        Write-Log $msg2
        foreach ($u in $opt) {
            Write-Host "  - $($u.Title)"
            Write-Log "  - $($u.Title)"
        }

        $sysInfo = New-Object -ComObject Microsoft.Update.SystemInfo
        if ($sysInfo.RebootRequired) {
            $msg3 = "[NOTICE] A system reboot is pending to finish installing updates."
            Write-Host $msg3 -ForegroundColor Yellow
            Write-Log $msg3
        }
    } catch {
        Write-Log "[ERROR] Failed to query Windows Update COM API: $_"
        Write-Host "[ERROR] Failed to query Windows Update API." -ForegroundColor Red
    }

    Write-Host ""
    $openSettings = Read-Choice -Prompt "Would you like to open Windows Update Settings to view or install them? (Y/N): " -ValidKeys @('Y', 'N')
    if ($openSettings -eq 'Y') {
        Write-Log "Opening Windows Update Settings app."
        Start-Process "ms-settings:windowsupdate"
    }
}

# ============================================================================
# MODULE 1: FEATURE UPDATE PAUSER
# ============================================================================
function Start-FeaturePauser {
    Clear-Host
    Write-Log "--- Entered Module 1: Feature Update Pauser ---"
    Write-Host "============================================================================" -ForegroundColor Yellow
    Write-Host "                     MODULE 1: FEATURE UPDATE PAUSER" -ForegroundColor Yellow
    Write-Host "============================================================================" -ForegroundColor Yellow
    Write-Host ""

    $cleanCache = $false
    $cvKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    $winVer = (Get-ItemProperty -Path $cvKey -Name "DisplayVersion" -ErrorAction SilentlyContinue).DisplayVersion

    if ([string]::IsNullOrWhiteSpace($winVer)) {
        Write-Log "[ERROR] Could not detect Windows 11 DisplayVersion from registry. Aborting."
        Write-Host "[ERROR] Could not detect your Windows 11 version from the registry." -ForegroundColor Red
        Pause-Script
        return
    }
    Write-Log "Detected Windows 11 DisplayVersion: $winVer"

    Write-Host "Verifying required Windows Update services are running..."
    foreach ($svcName in @("bits", "wuauserv")) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') {
            Write-Log "[NOTICE] Service $svcName is not running. Attempting to start..."
            Write-Host "Starting $svcName service..."
            try {
                Start-Service -Name $svcName -ErrorAction Stop
                Write-Log "Started $svcName service successfully."
            } catch {
                Write-Log "[WARNING] Failed to start $svcName service prior to cache check."
                Write-Host "[WARNING] Could not start $svcName service. Cache check may rely on folder inspection only." -ForegroundColor Yellow
            }
        } else {
            Write-Log "Service $svcName is already running."
        }
    }

    Write-Host "Checking for cached or pending updates before checking patch status (90-second timeout)..."

    $downloadDir = Join-Path $env:windir "SoftwareDistribution\Download"
    if ((Test-Path $downloadDir) -and (Get-ChildItem -Path $downloadDir -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
        $cleanCache = $true
        Write-Log "[NOTICE] Cached update files found in SoftwareDistribution\Download."
    }

    $job = Start-Job -ScriptBlock {
        try {
            $s   = New-Object -ComObject Microsoft.Update.Session
            $u   = $s.CreateUpdateSearcher()
            $r   = $u.Search("IsInstalled=0 and IsHidden=0")
            $sys = New-Object -ComObject Microsoft.Update.SystemInfo
            if ($r.Updates.Count -gt 0 -or $sys.RebootRequired) { return "1" } else { return "0" }
        } catch {
            return "0"
        }
    }

    if (Wait-Job -Job $job -Timeout 90) {
        $comCheckResult = Receive-Job -Job $job
        Remove-Job -Job $job -Force
    } else {
        Stop-Job -Job $job
        Remove-Job -Job $job -Force
        $comCheckResult = "TIMEOUT"
    }

    if ($comCheckResult -eq "TIMEOUT") {
        Write-Log "[WARNING] Windows Update cache/status check timed out after 90 seconds."
        Write-Host "[WARNING] Windows Update status check timed out after 1 minute 30 seconds. Proceeding..." -ForegroundColor Yellow
    } elseif ($comCheckResult -eq "1") {
        $cleanCache = $true
        Write-Log "[NOTICE] Pending updates or pending reboot detected via Windows Update API."
    }

    if ($cleanCache) {
        Write-Log "[NOTICE] SoftwareDistribution cache flagged for cleanup."
        Write-Host "[NOTICE] Cached or pending updates were detected. The SoftwareDistribution folder will be cleared when applying changes." -ForegroundColor Yellow
    } else {
        Write-Log "No cached or pending updates detected."
    }

    $wuPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    $isLocked = $null -ne (Get-ItemProperty -Path $wuPolicyPath -Name "TargetReleaseVersion" -ErrorAction SilentlyContinue)

    if (-not $isLocked) {
        Write-Host ""
        Write-Host "This will lock Windows Update to Windows 11 version ($winVer) so feature upgrades are blocked."
        Write-Host "You can undo this later by running this module again."
        Write-Host ""
        $confirm = Read-Choice -Prompt "Proceed with applying version lock? (Y/N): " -ValidKeys @('Y', 'N')
        if ($confirm -eq 'N') { return }

        if (-not (Test-Path $wuPolicyPath)) {
            New-Item -Path $wuPolicyPath -Force | Out-Null
        }
        New-ItemProperty -Path $wuPolicyPath -Name "TargetReleaseVersion" -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $wuPolicyPath -Name "TargetReleaseVersionInfo" -Value $winVer -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $wuPolicyPath -Name "ProductVersion" -Value "Windows 11" -PropertyType String -Force | Out-Null
        Write-Log "[SUCCESS] Applied Windows Update version lock for Windows 11 $winVer."
    } else {
        Write-Host ""
        Write-Host "This patch is CURRENTLY ACTIVE. Proceeding will UNDO the patch and allow feature updates again." -ForegroundColor Cyan
        Write-Host ""
        $confirm = Read-Choice -Prompt "Proceed with removing version lock? (Y/N): " -ValidKeys @('Y', 'N')
        if ($confirm -eq 'N') { return }

        Remove-ItemProperty -Path $wuPolicyPath -Name "TargetReleaseVersion" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $wuPolicyPath -Name "TargetReleaseVersionInfo" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $wuPolicyPath -Name "ProductVersion" -ErrorAction SilentlyContinue
        Write-Log "[SUCCESS] Undid Windows Update version lock. Feature updates re-enabled."
    }

    Write-Host ""
    Write-Host "How would you like to apply these changes?"
    Write-Host "   1. Restart Windows Update service now (No PC reboot required)"
    Write-Host "   2. Restart the entire PC now"
    Write-Host "   3. Return to Main Menu (Restart manually later)"
    Write-Host ""
    $applyOpt = Read-Choice -Prompt "Select an option (1, 2, or 3): " -ValidKeys @('1', '2', '3')

    switch ($applyOpt) {
        '3' {
            Write-Log "User selected Option 3: Return to menu and restart manually later."
            Close-SettingsApp
            if ($cleanCache) {
                Stop-Service -Name "wuauserv" -Force -ErrorAction SilentlyContinue
                Clear-UpdateCache -ShouldClean $true
                Start-Service -Name "wuauserv" -ErrorAction SilentlyContinue
            }
            Write-Host "Changes saved. Remember to restart your PC later."
            Pause-Script
        }
        '2' {
            Write-Log "User selected Option 2: Restart the entire PC now."
            Invoke-DelayedReboot -CleanCache $cleanCache
        }
        '1' {
            Write-Log "User selected Option 1: Restart Windows Update service now."
            Write-Host ""
            Close-SettingsApp

            Write-Host "Refreshing Group Policy..."
            & gpupdate.exe /force | Out-Null
            Write-Log "Executed gpupdate /force."

            Write-Host "Stopping Windows Update service..."
            try {
                Stop-Service -Name "wuauserv" -Force -ErrorAction Stop
                Write-Log "Stopped wuauserv service."
            } catch {
                Write-Log "[WARNING] Could not stop wuauserv service; may be busy installing an update."
                Write-Host "[WARNING] Could not stop the Windows Update service. It may be busy installing an update." -ForegroundColor Yellow
                Write-Host "Please restart your PC manually later to apply the changes."
                Pause-Script
                return
            }

            Clear-UpdateCache -ShouldClean $cleanCache

            Write-Host "Starting Windows Update service..."
            try {
                Start-Service -Name "wuauserv" -ErrorAction Stop
                Write-Log "Restarted wuauserv service successfully."
            } catch {
                Write-Log "[ERROR] Failed to restart wuauserv service."
                Write-Host "[ERROR] Failed to restart the Windows Update service. Please restart your PC manually." -ForegroundColor Red
                Pause-Script
                return
            }

            Write-Host ""
            Write-Host "Done! Your changes are now active without needing a reboot." -ForegroundColor Green
            Write-Host ""
            $scanNow = Read-Choice -Prompt "Would you like to trigger a Windows Update check now? (Y/N): " -ValidKeys @('Y', 'N')
            if ($scanNow -eq 'Y') {
                Write-Log "User requested Windows Update check."
                Invoke-BatteryCheckAndScan
                Pause-Script
            }
        }
    }
}

# ============================================================================
# MODULE 2: FIX WINDOWS UPDATE (FULL COMPONENT & NETWORK RESET)
# ============================================================================
function Start-FixWindowsUpdate {
    Clear-Host
    Write-Log "--- Entered Module 2: Fix Windows Update ---"
    Write-Host "============================================================================" -ForegroundColor Green
    Write-Host "                    MODULE 2: FIX WINDOWS UPDATE COMPONENTS" -ForegroundColor Green
    Write-Host "============================================================================" -ForegroundColor Green
    Write-Host "This tool will perform a deep reset of Windows Update components:"
    Write-Host "   1. Stop BITS, Windows Update, Cryptographic, and MSI Installer services"
    Write-Host "   2. Clear QMGR downloader data files"
    Write-Host "   3. Backup and wipe SoftwareDistribution and Catroot2 folders"
    Write-Host "   4. Reset service security descriptors and re-register Update DLLs"
    Write-Host "   5. Reset Winsock catalog and WinHTTP proxy settings"
    Write-Host "   6. Restart all update services"
    Write-Host "============================================================================" -ForegroundColor Green
    Write-Host ""

    $confirm = Read-Choice -Prompt "Do you want to run the Windows Update repair now? (Y/N): " -ValidKeys @('Y', 'N')
    if ($confirm -eq 'N') { return }

    Write-Host ""
    Close-SettingsApp

    Write-Host "[1/6] Stopping Windows Update services..."
    Write-Log "Stopping bits, wuauserv, appidsvc, cryptsvc, msiserver..."
    foreach ($svc in @("bits", "wuauserv", "appidsvc", "cryptsvc", "msiserver")) {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    }

    Write-Host "[2/6] Deleting old QMGR data files..."
    $qmgrPaths = @(
        "$env:ALLUSERSPROFILE\Application Data\Microsoft\Network\Downloader\qmgr*.dat",
        "$env:ALLUSERSPROFILE\Microsoft\Network\Downloader\qmgr*.dat"
    )
    foreach ($p in $qmgrPaths) {
        Remove-Item -Path $p -Force -ErrorAction SilentlyContinue
    }

    Write-Host "[3/6] Resetting SoftwareDistribution and Catroot2 folders..."
    $sdPath      = Join-Path $env:windir "SoftwareDistribution"
    $sdBakPath   = Join-Path $env:windir "SoftwareDistribution.bak"
    $catPath     = Join-Path $env:windir "System32\catroot2"
    $catBakPath  = Join-Path $env:windir "System32\catroot2.bak"

    if (Test-Path $sdBakPath)  { Remove-Item -Path $sdBakPath -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $catBakPath) { Remove-Item -Path $catBakPath -Recurse -Force -ErrorAction SilentlyContinue }

    if (Test-Path $sdPath) {
        try {
            Rename-Item -Path $sdPath -NewName "SoftwareDistribution.bak" -Force -ErrorAction Stop
        } catch {
            Remove-Item -Path $sdPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    New-Item -Path $sdPath -ItemType Directory -Force | Out-Null

    if (Test-Path $catPath) {
        try {
            Rename-Item -Path $catPath -NewName "catroot2.bak" -Force -ErrorAction Stop
        } catch {
            Remove-Item -Path $catPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    New-Item -Path $catPath -ItemType Directory -Force | Out-Null
    Write-Log "SoftwareDistribution and catroot2 folders reset."

    Write-Host "[4/6] Resetting service permissions and re-registering Update DLLs..."
    $sddl = "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)"
    & sc.exe sdset bits $sddl | Out-Null
    & sc.exe sdset wuauserv $sddl | Out-Null

    $dlls = @(
        "atl.dll", "urlmon.dll", "mshtml.dll", "shdocvw.dll", "browseui.dll", "jscript.dll", "vbscript.dll",
        "scrrun.dll", "msxml.dll", "msxml3.dll", "msxml6.dll", "actxprxy.dll", "softpub.dll", "wintrust.dll",
        "dssenh.dll", "rsaenh.dll", "gpkcsp.dll", "sccbase.dll", "slbcsp.dll", "cryptdlg.dll", "oleaut32.dll",
        "ole32.dll", "shell32.dll", "initpki.dll", "wuapi.dll", "wuaueng.dll", "wuaueng1.dll", "wucltui.dll",
        "wups.dll", "wups2.dll", "wuweb.dll", "qmgr.dll", "qmgrprxy.dll", "wucltux.dll", "muweb.dll", "wuwebv.dll"
    )
    foreach ($dll in $dlls) {
        & regsvr32.exe /s $dll | Out-Null
    }
    Write-Log "Re-registered Windows Update DLLs."

    Write-Host "[5/6] Resetting Winsock and WinHTTP Proxy..."
    & netsh.exe winsock reset | Out-Null
    & netsh.exe winhttp reset proxy | Out-Null
    & ipconfig.exe /flushdns | Out-Null
    Write-Log "Winsock, WinHTTP proxy, and DNS cache reset."

    Write-Host "[6/6] Starting Windows Update services..."
    foreach ($svc in @("cryptsvc", "bits", "wuauserv", "msiserver")) {
        Start-Service -Name $svc -ErrorAction SilentlyContinue
    }
    Write-Log "[SUCCESS] Windows Update full component reset completed."

    Write-Host ""
    Write-Host "[SUCCESS] Windows Update components have been reset!" -ForegroundColor Green
    Write-Host "A system reboot is recommended before checking for updates."
    Write-Host ""
    $rebootNow = Read-Choice -Prompt "Would you like to restart your PC now? (Y/N): " -ValidKeys @('Y', 'N')
    if ($rebootNow -eq 'Y') {
        Invoke-DelayedReboot
    }
}

# ============================================================================
# MODULE 3: MANUAL OFFLINE UPDATE INSTALLER (MSUUpdates FOLDER)
# ============================================================================
function Start-ManualMsuInstaller {
    while ($true) {
        Clear-Host
        Write-Log "--- Entered Module 3: Manual MSU/CAB Installer ---"
        Write-Host "============================================================================" -ForegroundColor Magenta
        Write-Host "                  MODULE 3: MANUAL OFFLINE UPDATE INSTALLER" -ForegroundColor Magenta
        Write-Host "============================================================================" -ForegroundColor Magenta
        Write-Host "Target Folder: `"$MsuDir`""
        Write-Host ""

        if (-not (Test-Path $MsuDir)) {
            try {
                New-Item -Path $MsuDir -ItemType Directory -Force | Out-Null
            } catch {
                Write-Host "[ERROR] Unable to create or access the MSUUpdates folder." -ForegroundColor Red
                Pause-Script
                return
            }
        }

        $packages = @(Get-ChildItem -Path $MsuDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.msu', '.cab') })

        if ($packages.Count -eq 0) {
            Write-Host "[NOTICE] No .msu or .cab update files were found in:" -ForegroundColor Yellow
            Write-Host "          `"$MsuDir`""
            Write-Host ""
            Write-Host "Place your downloaded Microsoft Update files (.msu or .cab)"
            Write-Host "into that folder and run this option again."
            Write-Host ""
            $openFolder = Read-Choice -Prompt "Open the MSUUpdates folder in File Explorer now? (Y/N): " -ValidKeys @('Y', 'N')
            if ($openFolder -eq 'Y') {
                Start-Process "explorer.exe" -ArgumentList "`"$MsuDir`""
            }
            return
        }

        Write-Host "Found $($packages.Count) update package(s) ready to install." -ForegroundColor Green
        Write-Host ""
        Write-Host "   1. Install ALL packages silently (/quiet /norestart)"
        Write-Host "   2. Install ALL packages interactively"
        Write-Host "   3. Open MSUUpdates folder in Explorer"
        Write-Host "   4. Return to Main Menu"
        Write-Host ""

        $opt = Read-Choice -Prompt "Select an option (1-4): " -ValidKeys @('1', '2', '3', '4')
        if ($opt -eq '4') { return }
        if ($opt -eq '3') {
            Start-Process "explorer.exe" -ArgumentList "`"$MsuDir`""
            continue
        }

        $installMode = if ($opt -eq '1') { "SILENT" } else { "INTERACTIVE" }

        Write-Host ""
        Write-Host "Ensuring Windows Update service (wuauserv) is running..."
        Start-Service -Name "wuauserv" -ErrorAction SilentlyContinue

        $currNum = 0
        $rebootNeeded = $false

        foreach ($pkg in $packages) {
            $currNum++
            Write-Host ""
            Write-Host "[$currNum/$($packages.Count)] Processing: $($pkg.Name)"
            $ext = $pkg.Extension.ToLower()

            if ($ext -eq ".msu") {
                Write-Log "Installing MSU package: $($pkg.Name) (Mode: $installMode)"
                $argsList = if ($installMode -eq "SILENT") { "`"$($pkg.FullName)`" /quiet /norestart" } else { "`"$($pkg.FullName)`" /norestart" }
                $proc = Start-Process -FilePath "wusa.exe" -ArgumentList $argsList -Wait -PassThru
                $exitCode = $proc.ExitCode
            } elseif ($ext -eq ".cab") {
                Write-Log "Installing CAB package: $($pkg.Name) (Mode: $installMode)"
                $argsList = if ($installMode -eq "SILENT") {
                    @("/Online", "/Add-Package", "/PackagePath:`"$($pkg.FullName)`"", "/Quiet", "/NoRestart")
                } else {
                    @("/Online", "/Add-Package", "/PackagePath:`"$($pkg.FullName)`"", "/NoRestart")
                }
                $proc = Start-Process -FilePath "dism.exe" -ArgumentList $argsList -Wait -NoNewWindow -PassThru
                $exitCode = $proc.ExitCode
            }

            Write-Log "Finished $($pkg.Name) with exit code: $exitCode"

            switch ($exitCode) {
                3010 {
                    Write-Host "     -> Installed successfully. Reboot required." -ForegroundColor Yellow
                    $rebootNeeded = $true
                }
                0 {
                    Write-Host "     -> Installed successfully." -ForegroundColor Green
                }
                2359302 {
                    Write-Host "     -> Already installed on this system." -ForegroundColor Cyan
                }
                -2145124329 {
                    Write-Host "     -> Not applicable to this Windows version/architecture." -ForegroundColor DarkYellow
                }
                2149842967 {
                    Write-Host "     -> Not applicable to this Windows version/architecture." -ForegroundColor DarkYellow
                }
                default {
                    Write-Host "     -> Finished with exit code $exitCode." -ForegroundColor Red
                    Write-Host "     -> Check the log for details."
                }
            }
        }

        Write-Host ""
        Write-Host "============================================================================" -ForegroundColor Magenta
        Write-Host "All offline update packages processed."
        Write-Host "============================================================================" -ForegroundColor Magenta

        if ($rebootNeeded) {
            Write-Host ""
            Write-Host "[NOTICE] One or more updates require a system restart." -ForegroundColor Yellow
            $rebootChoice = Read-Choice -Prompt "Restart PC now? (Y/N): " -ValidKeys @('Y', 'N')
            if ($rebootChoice -eq 'Y') {
                Invoke-DelayedReboot
            }
            return
        }

        Pause-Script
        return
    }
}

# ============================================================================
# MODULE 4: SYSTEM HEALTH REPAIR (DISM & SFC)
# ============================================================================
function Start-SystemRepair {
    Clear-Host
    Write-Log "--- Entered Module 4: DISM & SFC System Repair ---"
    Write-Host "============================================================================" -ForegroundColor Blue
    Write-Host "                 MODULE 4: SYSTEM HEALTH REPAIR (DISM + SFC)" -ForegroundColor Blue
    Write-Host "============================================================================" -ForegroundColor Blue
    Write-Host "Corrupted system files often cause Windows Updates to fail with 0x800f081f"
    Write-Host "or 0x80073712 errors. This tool runs:"
    Write-Host "   1. DISM /Online /Cleanup-Image /RestoreHealth"
    Write-Host "   2. SFC /scannow"
    Write-Host "   3. DISM Component Store Cleanup (StartComponentCleanup)"
    Write-Host "============================================================================" -ForegroundColor Blue
    Write-Host ""

    $confirm = Read-Choice -Prompt "Start System Health Repair? (This may take 10-20 minutes) (Y/N): " -ValidKeys @('Y', 'N')
    if ($confirm -eq 'N') { return }

    Write-Host ""
    Write-Host "[Step 1/3] Running DISM RestoreHealth..." -ForegroundColor Cyan
    Write-Log "Running DISM /Online /Cleanup-Image /RestoreHealth"
    & dism.exe /Online /Cleanup-Image /RestoreHealth

    Write-Host ""
    Write-Host "[Step 2/3] Running System File Checker (SFC /scannow)..." -ForegroundColor Cyan
    Write-Log "Running sfc /scannow"
    & sfc.exe /scannow

    Write-Host ""
    Write-Host "[Step 3/3] Cleaning up superseded WinSxS update components..." -ForegroundColor Cyan
    Write-Log "Running DISM StartComponentCleanup"
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup

    Write-Log "[SUCCESS] System Health Repair completed."
    Write-Host ""
    Write-Host "System Health Repair complete!" -ForegroundColor Green
    Pause-Script
}

# ============================================================================
# MODULE 5: UPDATE UTILITIES SUBMENU
# ============================================================================
function Start-UtilitiesMenu {
    while ($true) {
        Clear-Host
        Write-Host "============================================================================" -ForegroundColor White
        Write-Host "                        MODULE 5: UPDATE UTILITIES" -ForegroundColor White
        Write-Host "============================================================================" -ForegroundColor White
        Write-Host "   1. Scan for Pending & Optional Updates Now (with Battery Check)"
        Write-Host "   2. Clear SoftwareDistribution Download Cache Only"
        Write-Host "   3. Open Windows Update Settings (ms-settings:windowsupdate)"
        Write-Host "   4. Open Update History & Uninstall Updates Control Panel"
        Write-Host "   5. View Multitool Log File"
        Write-Host "   6. Return to Main Menu"
        Write-Host "============================================================================" -ForegroundColor White
        Write-Host ""

        $opt = Read-Choice -Prompt "Select a utility (1-6): " -ValidKeys @('1', '2', '3', '4', '5', '6')

        switch ($opt) {
            '6' { return }
            '5' {
                if (Test-Path $LogFile) {
                    Start-Process "notepad.exe" -ArgumentList "`"$LogFile`""
                } else {
                    Write-Host "Log file not found yet." -ForegroundColor Yellow
                    Pause-Script
                }
            }
            '4' {
                Write-Log "Opened Installed Updates Control Panel."
                Start-Process "control.exe" -ArgumentList "appwiz.cpl,,2"
            }
            '3' {
                Write-Log "Opened Windows Update Settings."
                Start-Process "ms-settings:windowsupdate"
            }
            '2' {
                Write-Host ""
                Close-SettingsApp
                Stop-Service -Name "wuauserv" -Force -ErrorAction SilentlyContinue
                Clear-UpdateCache -ShouldClean $true
                Start-Service -Name "wuauserv" -ErrorAction SilentlyContinue
                Write-Host "SoftwareDistribution cache cleared!" -ForegroundColor Green
                Pause-Script
            }
            '1' {
                Invoke-BatteryCheckAndScan
                Pause-Script
            }
        }
    }
}

# ============================================================================
# MAIN MENU LOOP
# ============================================================================
function Start-WinUpdateMultitool {
    Write-Log "=================================================="
    Write-Log "Multitool started by $env:USERNAME on $env:COMPUTERNAME (BaseDir: $BaseDir)"

    while ($true) {
        Clear-Host
        $winVer = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name "DisplayVersion" -ErrorAction SilentlyContinue).DisplayVersion
        if ([string]::IsNullOrWhiteSpace($winVer)) { $winVer = "Unknown" }

        $isLocked = $null -ne (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "TargetReleaseVersion" -ErrorAction SilentlyContinue)
        $patchStatus = if ($isLocked) { "[LOCKED to $winVer]" } else { "[UNLOCKED - Feature Updates Allowed]" }

        Write-Host "============================================================================" -ForegroundColor Cyan
        Write-Host "                        WINDOWS UPDATE MULTITOOL" -ForegroundColor Cyan
        Write-Host "============================================================================" -ForegroundColor Cyan
        Write-Host "  OS Version   : Windows 11 $winVer"
        Write-Host "  Update Lock  : " -NoNewline
        if ($isLocked) {
            Write-Host $patchStatus -ForegroundColor Yellow
        } else {
            Write-Host $patchStatus -ForegroundColor Green
        }
        Write-Host "  MSU Folder   : $MsuDir"
        Write-Host "  Log File     : $LogFile"
        Write-Host "============================================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "   [1] Feature Update Pauser (Lock / Unlock Windows 11 Version)"
        Write-Host "   [2] Fix Windows Update (Full Reset, Cache Wipe, Winsock & Services)"
        Write-Host "   [3] Manual Offline Update Installer (Install .msu / .cab from MSUUpdates)"
        Write-Host "   [4] System Health Repair (DISM RestoreHealth + SFC /scannow)"
        Write-Host "   [5] Update Utilities (Trigger Scan, Open Settings, View Log, Clear Cache)"
        Write-Host "   [6] Exit"
        Write-Host ""
        Write-Host "============================================================================" -ForegroundColor Cyan

        $choice = Read-Choice -Prompt "Select an option (1-6): " -ValidKeys @('1', '2', '3', '4', '5', '6')

        switch ($choice) {
            '1' { Start-FeaturePauser }
            '2' { Start-FixWindowsUpdate }
            '3' { Start-ManualMsuInstaller }
            '4' { Start-SystemRepair }
            '5' { Start-UtilitiesMenu }
            '6' {
                Write-Log "Multitool exited cleanly."
                return
            }
        }
    }
}

# Launch the tool
Start-WinUpdateMultitool