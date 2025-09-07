# WinToADB.ps1 - Push save files from Windows to Android device via ADB
# This is a wrapper around ADBtoWin.ps1 that specifically handles Win->ADB transfers

param(
    [string]$Device = '',  # Leave empty to auto-detect BlueStacks
    [string]$ConnectAddr = '',
    [string]$BlueStacksInstance = 'Rvc64',  # Default to "BlueStacks Android 11"
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

function Get-BlueStacksADBPort {
    param([string]$InstanceName = 'Rvc64')
    
    $configPath = "C:\ProgramData\BlueStacks_nxt\bluestacks.conf"
    if (-not (Test-Path $configPath)) {
        Write-Log "BlueStacks config not found at: $configPath" "WARN"
        return $null
    }
    
    try {
        $content = Get-Content $configPath
        $pattern = "^bst\.instance\.$InstanceName\.status\.adb_port=`"(\d+)`""
        
        foreach ($line in $content) {
            if ($line -match $pattern) {
                $port = $matches[1]
                Write-Log "Found BlueStacks $InstanceName on port: $port" "DEBUG"
                return "127.0.0.1:$port"
            }
        }
        
        Write-Log "BlueStacks instance '$InstanceName' not found in config" "WARN"
        return $null
    } catch {
        Write-Log "Error reading BlueStacks config: $($_.Exception.Message)" "WARN"
        return $null
    }
}

# Auto-detect BlueStacks ADB port if not specified
if ([string]::IsNullOrEmpty($Device)) {
    $detectedDevice = Get-BlueStacksADBPort -InstanceName $BlueStacksInstance
    if ($detectedDevice) {
        $Device = $detectedDevice
        if ([string]::IsNullOrEmpty($ConnectAddr)) {
            $ConnectAddr = $detectedDevice
        }
        Write-Log "Auto-detected BlueStacks device: $Device" "INFO"
    } else {
        # Fallback to default
        $Device = "127.0.0.1:5555"
        if ([string]::IsNullOrEmpty($ConnectAddr)) {
            $ConnectAddr = "127.0.0.1:5555"
        }
        Write-Log "Could not auto-detect BlueStacks port, using default: $Device" "WARN"
    }
} else {
    # Device was specified, ensure ConnectAddr is set
    if ([string]::IsNullOrEmpty($ConnectAddr)) {
        $ConnectAddr = $Device
    }
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

# Build hashtable for proper parameter splatting
$adbParams = @{
    Action      = 'Push'
    Device      = $Device
    ConnectAddr = $ConnectAddr
    RemotePath  = $RemotePath
    LocalBase   = $LocalBase
    AdbExe      = $AdbExe
    LocalSource = $LocalSource
    InitialWait = $InitialWait
    MaxRetries  = $MaxRetries
    RetryDelay  = $RetryDelay
}

# Add switch parameters properly
if ($AutoConnect) { $adbParams.AutoConnect = $true }
if ($Timestamped) { $adbParams.Timestamped = $true }
if ($DryRun) { $adbParams.DryRun = $true }
if ($WhatIf) { $adbParams.WhatIf = $true }
if ($ShowDetails) { $adbParams.ShowDetails = $true }

Write-Log "Calling ADBtoWin.ps1 with Push action" "DEBUG"

try {
    & $adbtowinScript @adbParams
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ADBtoWin.ps1 returned exit code: $LASTEXITCODE" "ERROR"
        exit $LASTEXITCODE
    }
    Write-Log "Successfully completed push operation" "INFO"
} catch {
    Write-Log "Error executing ADBtoWin.ps1: $($_.Exception.Message)" "ERROR"
    exit 1
}
