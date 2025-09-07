param(
    [ValidateSet('Pull','Push')][string]$Action = 'Pull',
    [string]$Device = '127.0.0.1:5555',
    [string]$ConnectAddr = '127.0.0.1:5555',    # address used for adb connect if AutoConnect
    [switch]$AutoConnect,                      # attempt "adb connect <ConnectAddr>" if device not listed
    [string]$RemotePath = '/sdcard/Android/data/com.crunchyroll.gv.blacklilystale.game/files/Savedata',
    [string]$LocalBase = "$env:USERPROFILE\OneDrive\Saves\Android\BlackLilyCR\BlueStacks A11",
    [switch]$Timestamped,
    [string]$LocalSource = '',                 # optional explicit folder to push (Push action)
    [string]$AdbExe = 'adb',
    [switch]$DryRun,
    [switch]$WhatIf,
    [switch]$ShowDetails,
    [int]$InitialWait = 0,                     # seconds to wait before starting ADB operations
    [int]$MaxRetries = 3,                      # number of times to retry ADB operations
    [int]$RetryDelay = 5,                      # seconds between retries
    [int]$ConnectTimeout = 10                  # seconds to wait for device connection
)

function Write-Log {
    param($Msg, $Level='INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    if ($Level -eq 'ERROR') { Write-Host "[$ts] [$Level] $Msg" -ForegroundColor Red }
    elseif ($Level -eq 'WARN') { Write-Host "[$ts] [$Level] $Msg" -ForegroundColor Yellow }
    elseif ($Level -eq 'DEBUG' -and $ShowDetails) { Write-Host "[$ts] [$Level] $Msg" -ForegroundColor Gray }
    else { Write-Host "[$ts] [$Level] $Msg" }
}

# locate adb
# prefer resolving 'adb' via Get-Command so we get the full executable path from PATH
$resolved = Get-Command $AdbExe -ErrorAction SilentlyContinue
if ($resolved) {
    $AdbExe = $resolved.Source
} else {
    $candidates = @(
        "$env:ProgramFiles\Android\Android Studio\platform-tools\adb.exe",
        "$env:ProgramFiles(x86)\Android\android-sdk\platform-tools\adb.exe",
        "$env:ProgramFiles\Android\platform-tools\adb.exe",
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { $AdbExe = $c; break } }
}

if (-not (Test-Path $AdbExe -PathType Leaf)) {
    Write-Log "adb executable not found. Set -AdbExe to its full path or ensure adb is on PATH." "ERROR"
    exit 1
}

Write-Log "Using adb executable: $AdbExe" "DEBUG"

# Initial wait if specified (useful when running from Playnite after game start)
if ($InitialWait -gt 0) {
    Write-Log "Waiting $InitialWait seconds for system to stabilize..." "INFO"
    Start-Sleep -Seconds $InitialWait
}

function Run-AdbRaw {
    param([string[]]$ArgArray)
    # remove null/empty args to avoid calling 'adb' with no arguments (which prints help)
    $cleanArgs = @()
    if ($ArgArray) { 
        $cleanArgs = $ArgArray | Where-Object { $_ -ne $null -and $_ -ne '' -and $_.Trim() -ne '' }
    }
    if (-not $cleanArgs -or $cleanArgs.Count -eq 0) {
        Write-Log "Run-AdbRaw called with no arguments, refusing to run adb with empty args" "DEBUG"
        return @{ Success = $false; ExitCode = 1; Output = @('No args supplied') }
    }
    
    # Ensure proper argument separation and quoting
    $cmdLine = "`"$AdbExe`" " + ($cleanArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    Write-Log "Running: $cmdLine" "DEBUG"
    
    if ($WhatIf) { Write-Log "[WhatIf] $cmdLine" "INFO"; return @{ Success=$true; Output=@("[WhatIf]") ; ExitCode=0 } }
    if ($DryRun) { Write-Log "[DryRun] $cmdLine" "INFO"; return @{ Success=$true; Output=@("[DryRun]") ; ExitCode=0 } }

    # Execute using the call operator with proper argument array
    Write-Log "Exec: $AdbExe with args: [$($cleanArgs -join '], [')]" "DEBUG"
    try {
        $output = & $AdbExe $cleanArgs 2>&1
        $exit = $LASTEXITCODE
        Write-Log "ADB exit code: $exit" "DEBUG"
        return @{ Success = ($exit -eq 0); ExitCode = $exit; Output = $output }
    } catch {
        Write-Log "Exception running ADB: $($_.Exception.Message)" "ERROR"
        return @{ Success = $false; ExitCode = 1; Output = @($_.Exception.Message) }
    }
}

function Run-Adb {
    param([string[]]$ArgArray)
    # run adb with -s $Device prefix
    $argList = @("-s", $Device) + $ArgArray
    return Run-AdbRaw -ArgArray $argList
}

function Device-Listed {
    # returns $true if device string appears as "device" OR "offline" in adb devices output
    $r = Run-AdbRaw -ArgArray @('devices')
    if (-not $r.Success -and -not $WhatIf -and -not $DryRun) {
        Write-Log "Warning: adb devices returned non-zero exit code $($r.ExitCode)" "DEBUG"
    }
    # dump output lines for debugging
    foreach ($o in $r.Output) { Write-Log "adb devices output: $o" "DEBUG" }
    foreach ($line in $r.Output) {
        # Accept both "device" and "offline" status for BlueStacks compatibility
        if ($line -match "^\s*([^\s]+)\s+(device|offline)\s*$") {
            if ($matches[1] -eq $Device -or $matches[1] -eq $ConnectAddr -or $Device -like "$matches[1]*") {
                if ($matches[2] -eq "offline") {
                    Write-Log "Device $($matches[1]) found but offline - will attempt to use anyway (BlueStacks compatibility)" "WARN"
                }
                return $true
            }
        }
    }
    
    # fallback: try 'adb devices -l' (some adb servers include extra lines; -l gives a more consistent list)
    Write-Log "Falling back to 'adb devices -l'" "DEBUG"
    $r2 = Run-AdbRaw -ArgArray @('devices','-l')
    foreach ($o in $r2.Output) { Write-Log "adb devices -l output: $o" "DEBUG" }
    foreach ($line in $r2.Output) {
        # Accept both "device" and "offline" status
        if ($line -match "^\s*([^\s]+)\s+(device|offline)\b") {
            if ($matches[1] -eq $Device -or $matches[1] -eq $ConnectAddr -or $Device -like "$matches[1]*") {
                if ($matches[2] -eq "offline") {
                    Write-Log "Device $($matches[1]) found but offline - will attempt to use anyway (BlueStacks compatibility)" "WARN"
                }
                return $true
            }
        }
    }
    return $false
}

# ensure adb server is running before checking devices
Write-Log "Ensuring adb server is started" "DEBUG"
$srv = Run-AdbRaw -ArgArray @('start-server')
Write-Log "adb start-server exit $($srv.ExitCode). Output: $($srv.Output -join ' | ')" "DEBUG"

# Enhanced device connection with retry logic
function Wait-ForDevice {
    param([int]$MaxAttempts = $MaxRetries, [int]$DelaySeconds = $RetryDelay)
    
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Log "Checking for device (attempt $attempt/$MaxAttempts)..." "INFO"
        
        if (Device-Listed) {
            Write-Log "Device $Device is available" "INFO"
            return $true
        }
        
        if ($AutoConnect) {
            Write-Log "Device $Device not listed. Attempting adb connect $ConnectAddr" "INFO"
            $conn = Run-AdbRaw -ArgArray @('connect', $ConnectAddr)
            if (-not $conn.Success) {
                Write-Log "adb connect failed (exit $($conn.ExitCode)). Output:`n$($conn.Output -join '`n')" "WARN"
            } else {
                Write-Log "adb connect output: $($conn.Output -join ' | ')" "DEBUG"
            }
            
            # Wait a bit for connection to establish
            Start-Sleep -Seconds 2
            
            # Check again after connect attempt
            if (Device-Listed) {
                Write-Log "Device $Device connected successfully" "INFO"
                return $true
            }
        }
        
        if ($attempt -lt $MaxAttempts) {
            Write-Log "Device not available. Waiting $DelaySeconds seconds before retry..." "WARN"
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    
    return $false
}

# attempt auto-connect if needed with retry logic
if (-not (Wait-ForDevice)) {
    if ($AutoConnect) {
        Write-Log "Device still not available after $MaxRetries attempts. Aborting." "ERROR"
    } else {
        Write-Log "Device $Device not listed. Use -AutoConnect to attempt 'adb connect' or connect manually." "ERROR"
    }
    exit 2
}

# build timestamped folder for Pull or default for Push
$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
if ($Action -eq 'Pull') {
    if ($Timestamped) { $dest = Join-Path $LocalBase $timestamp } else { $dest = $LocalBase }
} else {
    $dest = $LocalBase
}

Write-Log "Action: $Action, Device: $Device, RemotePath: $RemotePath, LocalBase: $LocalBase" "INFO"

# Function to retry ADB operations with backoff
function Invoke-AdbWithRetry {
    param(
        [string[]]$AdbArgs,
        [string]$OperationName,
        [int]$MaxAttempts = $MaxRetries
    )
    
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Log "$OperationName (attempt $attempt/$MaxAttempts)..." "INFO"
        
        $result = Run-Adb -ArgArray $AdbArgs
        if ($result.Success) {
            Write-Log "$OperationName successful" "SUCCESS"
            return $result
        }
        
        Write-Log "$OperationName failed (exit $($result.ExitCode)). Output:`n$($result.Output -join "`n")" "WARN"
        
        if ($attempt -lt $MaxAttempts) {
            Write-Log "Retrying in $RetryDelay seconds..." "INFO"
            Start-Sleep -Seconds $RetryDelay
            
            # Re-verify device is still connected before retry
            if (-not (Device-Listed)) {
                Write-Log "Device disconnected. Attempting to reconnect..." "WARN"
                if (-not (Wait-ForDevice -MaxAttempts 2 -DelaySeconds 3)) {
                    Write-Log "Could not reconnect to device for retry" "ERROR"
                    return $result
                }
            }
        }
    }
    
    return $result
}

try {
    if ($Action -eq 'Pull') {
        if ($WhatIf) { Write-Log "WhatIf: prepare directory $dest" "INFO" }
        elseif (-not $DryRun) {
            # If not timestamped (direct mode), clear existing contents so pull overwrites cleanly
            if (-not $Timestamped -and (Test-Path $dest)) {
                Write-Log "Clearing existing contents of $dest" "DEBUG"
                Get-ChildItem -Path $dest -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (-not (Test-Path $dest)) { New-Item -Path $dest -ItemType Directory -Force | Out-Null }
        }

    Write-Log "Pulling from device:${Device}:${RemotePath} -> $dest" "INFO"
    $result = Invoke-AdbWithRetry -AdbArgs @('pull', $RemotePath, $dest) -OperationName "Pull operation"
        if (-not $result.Success) {
            Write-Log "adb pull failed after $MaxRetries attempts (exit $($result.ExitCode)). Output:`n$($result.Output -join "`n")" "ERROR"
            exit 2
        }
        Write-Log "Pull successful. Files saved to: $dest" "SUCCESS"
    } else {
        # Push: determine source folder
        $sourceFolder = $null
        if ($LocalSource) {
            if (-not (Test-Path $LocalSource)) { Write-Log "LocalSource not found: $LocalSource" "ERROR"; exit 4 }
            $sourceFolder = (Get-Item -LiteralPath $LocalSource).FullName
        } else {
            if (-not (Test-Path $LocalBase)) {
                Write-Log "Local base path not found: $LocalBase" "ERROR"; exit 3
            }
            $candidates = Get-ChildItem -Path $LocalBase -Directory | Sort-Object LastWriteTime -Descending
            if ($candidates.Count -eq 0) {
                Write-Log "No subfolders found under $LocalBase to push" "ERROR"; exit 4
            }
            $sourceFolder = $candidates[0].FullName
        }

    Write-Log "Pushing local folder $sourceFolder -> device:${Device}:${RemotePath}" "INFO"
    $result = Invoke-AdbWithRetry -AdbArgs @('push', $sourceFolder, $RemotePath) -OperationName "Push operation"
        if (-not $result.Success) {
            Write-Log "adb push failed after $MaxRetries attempts (exit $($result.ExitCode)). Output:`n$($result.Output -join "`n")" "ERROR"
            exit 5
        }
        Write-Log "Push successful." "SUCCESS"
    }
} catch {
    Write-Log "Unexpected error: $_" "ERROR"
    exit 99
}

param(
    [string]$InstanceName = "",  # e.g., "Pie64", "Nougat32", etc. If empty, returns first running instance
    [string]$ConfigPath = "C:\ProgramData\BlueStacks_nxt\bluestacks.conf",
    [switch]$ShowAll
)

function Get-BlueStacksADBPorts {
    param([string]$ConfigFile)
    
    if (-not (Test-Path $ConfigFile)) {
        Write-Error "BlueStacks config not found at: $ConfigFile"
        return @()
    }
    
    $ports = @()
    $content = Get-Content $ConfigFile
    
    foreach ($line in $content) {
        # Match lines like: bst.instance.Pie64.status.adb_port="5556"
        if ($line -match '^bst\.instance\.([^.]+)\.status\.adb_port="(\d+)"') {
            $instanceName = $matches[1]
            $port = $matches[2]
            
            $ports += [PSCustomObject]@{
                Instance = $instanceName
                Port = $port
                Address = "127.0.0.1:$port"
            }
        }
    }
    
    return $ports
}

try {
    $ports = Get-BlueStacksADBPorts -ConfigFile $ConfigPath
    
    if ($ports.Count -eq 0) {
        Write-Error "No BlueStacks ADB ports found in config file"
        exit 1
    }
    
    if ($ShowAll) {
        Write-Host "All BlueStacks instances and their ADB ports:"
        $ports | Format-Table -AutoSize
        exit 0
    }
    
    if ($InstanceName) {
        $targetPort = $ports | Where-Object { $_.Instance -eq $InstanceName }
        if (-not $targetPort) {
            Write-Error "Instance '$InstanceName' not found. Available instances: $($ports.Instance -join ', ')"
            exit 1
        }
        Write-Output $targetPort.Address
    } else {
        # Return first port (most commonly used)
        Write-Output $ports[0].Address
    }
    
} catch {
    Write-Error "Error reading BlueStacks config: $($_.Exception.Message)"
    exit 1
}