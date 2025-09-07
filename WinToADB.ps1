# WinToADB.ps1 - Push save files from Windows to Android device via ADB
# This is a wrapper around ADBtoWin.ps1 that specifically handles Win->ADB transfers

param(
    [string]$Device = '127.0.0.1:5555',
    [string]$ConnectAddr = '127.0.0.1:5555',
    [switch]$AutoConnect,
    [string]$RemotePath = '/sdcard/Android/data/com.crunchyroll.gv.blacklilystale.game/files/Savedata',
    [string]$LocalBase = "$env:USERPROFILE\OneDrive\Saves\Android\BlackLilyCR\BlueStacks A11",
    [string]$LocalSource = '',                 # optional explicit folder to push
    [string]$AdbExe = 'adb',
    [switch]$DryRun,
    [switch]$WhatIf,
    [switch]$ShowDetails,
    [switch]$UseLatest,                        # automatically select latest timestamped folder
    [int]$InitialWait = 0,                     # seconds to wait before starting ADB operations
    [int]$MaxRetries = 3,                      # number of times to retry ADB operations
    [int]$RetryDelay = 5,                      # seconds between retries
    [int]$ConnectTimeout = 10,                 # seconds to wait for device connection
    [switch]$Help
)

# Show help if requested
if ($Help) {
    Write-Host "WinToADB.ps1 - Push save files from Windows to Android device via ADB"
    Write-Host ""
    Write-Host "Usage: WinToADB.ps1 [options]"
    Write-Host ""
    Write-Host "Parameters:"
    Write-Host "  -Device <addr>           ADB device address (default: 127.0.0.1:5555)"
    Write-Host "  -ConnectAddr <addr>      Address for adb connect (default: same as Device)"
    Write-Host "  -AutoConnect             Attempt 'adb connect' if device not listed"
    Write-Host "  -RemotePath <path>       Target path on Android device"
    Write-Host "  -LocalBase <path>        Base local folder containing saves"
    Write-Host "  -LocalSource <path>      Explicit source folder to push (overrides LocalBase)"
    Write-Host "  -UseLatest               Automatically select latest timestamped subfolder from LocalBase"
    Write-Host "  -InitialWait <seconds>   Wait before starting ADB operations (useful for Playnite)"
    Write-Host "  -MaxRetries <count>      Number of times to retry ADB operations (default: 3)"
    Write-Host "  -RetryDelay <seconds>    Seconds between retries (default: 5)"
    Write-Host "  -ConnectTimeout <sec>    Seconds to wait for device connection (default: 10)"
    Write-Host "  -AdbExe <path>           Path to adb executable (default: 'adb' from PATH)"
    Write-Host "  -DryRun                  Show what would be done without making changes"
    Write-Host "  -WhatIf                  Show commands that would be executed"
    Write-Host "  -ShowDetails             Show detailed logging"
    Write-Host "  -Help                    Show this help message"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  WinToADB.ps1 -AutoConnect -ShowDetails"
    Write-Host "  WinToADB.ps1 -LocalSource 'C:\Saves\SpecificFolder' -DryRun"
    Write-Host "  WinToADB.ps1 -UseLatest -AutoConnect -InitialWait 10"
    Write-Host "  WinToADB.ps1 -AutoConnect -MaxRetries 5 -RetryDelay 3"
    exit 0
}

function Write-Log {
    param($Msg, $Level='INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    if ($Level -eq 'ERROR') { Write-Host "[$ts] [$Level] $Msg" -ForegroundColor Red }
    elseif ($Level -eq 'WARN') { Write-Host "[$ts] [$Level] $Msg" -ForegroundColor Yellow }
    elseif ($Level -eq 'SUCCESS') { Write-Host "[$ts] [$Level] $Msg" -ForegroundColor Green }
    elseif ($Level -eq 'DEBUG' -and $ShowDetails) { Write-Host "[$ts] [$Level] $Msg" -ForegroundColor Gray }
    else { Write-Host "[$ts] [$Level] $Msg" }
}

# Get the directory where this script is located
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$adbtowinScript = Join-Path $scriptDir "ADBtoWin.ps1"

# Check if ADBtoWin.ps1 exists
if (-not (Test-Path $adbtowinScript)) {
    Write-Log "ADBtoWin.ps1 not found in the same directory as this script ($scriptDir)" "ERROR"
    Write-Log "Please ensure ADBtoWin.ps1 is in the same directory." "ERROR"
    exit 1
}

Write-Log "WinToADB - Pushing saves from Windows to Android device" "INFO"

# Handle UseLatest option
if ($UseLatest -and -not $LocalSource) {
    if (-not (Test-Path $LocalBase)) {
        Write-Log "Local base path not found: $LocalBase" "ERROR"
        exit 2
    }
    
    # Look for timestamped folders (YYYY-MM-DD_HH-MM-SS format) or any subdirectories
    $candidates = Get-ChildItem -Path $LocalBase -Directory | Sort-Object LastWriteTime -Descending
    
    if ($candidates.Count -eq 0) {
        Write-Log "No subdirectories found in $LocalBase" "ERROR"
        exit 3
    }
    
    $latestFolder = $candidates[0]
    $LocalSource = $latestFolder.FullName
    Write-Log "Using latest folder: $LocalSource (modified: $($latestFolder.LastWriteTime))" "INFO"
}

# Prepare arguments for ADBtoWin.ps1
$adbArgs = @(
    '-Action', 'Push'
    '-Device', $Device
    '-ConnectAddr', $ConnectAddr
    '-RemotePath', $RemotePath
    '-LocalBase', $LocalBase
    '-AdbExe', $AdbExe
)

if ($LocalSource) { $adbArgs += @('-LocalSource', $LocalSource) }
if ($InitialWait -gt 0) { $adbArgs += @('-InitialWait', $InitialWait) }
if ($MaxRetries -ne 3) { $adbArgs += @('-MaxRetries', $MaxRetries) }
if ($RetryDelay -ne 5) { $adbArgs += @('-RetryDelay', $RetryDelay) }
if ($ConnectTimeout -ne 10) { $adbArgs += @('-ConnectTimeout', $ConnectTimeout) }
if ($AutoConnect) { $adbArgs += '-AutoConnect' }
if ($DryRun) { $adbArgs += '-DryRun' }
if ($WhatIf) { $adbArgs += '-WhatIf' }
if ($ShowDetails) { $adbArgs += '-ShowDetails' }

Write-Log "Calling ADBtoWin.ps1 with Push action..." "DEBUG"
if ($ShowDetails) {
    Write-Log "Arguments: $($adbArgs -join ' ')" "DEBUG"
}

# Execute ADBtoWin.ps1 with Push action
try {
    & $adbtowinScript @adbArgs
    $exitCode = $LASTEXITCODE
    
    if ($exitCode -eq 0) {
        Write-Log "Push operation completed successfully" "SUCCESS"
    } else {
        Write-Log "Push operation failed with exit code $exitCode" "ERROR"
        exit $exitCode
    }
} catch {
    Write-Log "Error executing ADBtoWin.ps1: $_" "ERROR"
    exit 99
}
