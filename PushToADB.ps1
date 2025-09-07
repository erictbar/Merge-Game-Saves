# PushToADB.ps1 - Simple alias for pushing saves to ADB using existing ADBtoWin.ps1
# This demonstrates how to use ADBtoWin.ps1 for Win->ADB transfers

param(
    [string]$LocalSource = '',
    [string]$RemotePath = '/sdcard/Android/data/com.crunchyroll.gv.blacklilystale.game/files/Savedata',
    [string]$LocalBase = "$env:USERPROFILE\OneDrive\Saves\Android\BlackLilyCR\BlueStacks A11",
    [switch]$AutoConnect,
    [switch]$DryRun,
    [switch]$ShowDetails
)

# Get script directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$adbtowinScript = Join-Path $scriptDir "ADBtoWin.ps1"

# Build arguments for Push action
$adbArgs = @('-Action', 'Push', '-RemotePath', $RemotePath, '-LocalBase', $LocalBase)

if ($LocalSource) { $adbArgs += @('-LocalSource', $LocalSource) }
if ($AutoConnect) { $adbArgs += '-AutoConnect' }
if ($DryRun) { $adbArgs += '-DryRun' }
if ($ShowDetails) { $adbArgs += '-ShowDetails' }

# Execute ADBtoWin.ps1 with Push action
& $adbtowinScript @adbArgs
