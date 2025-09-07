# MergeGames.ps1 - Sync game save files across multiple PCs with backup
param(
    [Parameter(Mandatory=$true, ValueFromRemainingArguments=$false)]
    [string[]]$Path,

    [string]$Archive = "$env:USERPROFILE\Documents\GameSaves\Archive",

    [switch]$DryRun,

    [switch]$ShowDetails,

    [string]$ConflictResolution = "Newest", # Newest, Largest, Manual

    [switch]$Help,
    
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$RemainingArgs
)

# Show help if requested
if ($Help) {
    Write-Host "MergeGames.ps1 - Sync game save files across multiple PCs"
    Write-Host ""
    Write-Host "Usage: MergeGames.ps1 -Path <path1>,<path2> [options]"
    Write-Host ""
    Write-Host "Parameters:"
    Write-Host "  -Path <path1>,<path2>     SMB paths to sync (comma-separated array)"
    Write-Host "  -Archive <path>           Archive location (default: %USERPROFILE%\OneDrive\Saves\Automation)"
    Write-Host "  -DryRun                   Show what would be done without making changes"
    Write-Host "  -ShowDetails              Show detailed logging"
    Write-Host "  -ConflictResolution       How to resolve conflicts: Newest, Largest, Manual (default: Newest)"
    Write-Host "  -Help                     Show this help message"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  MergeGames.ps1 -Path '\\192.168.1.100\d\Users\user\Gaes\GOG\Nukitashi\savedata','\\192.168.1.101\c\Apps\GOG\NUKITASHI\savedata'"
    Write-Host "  MergeGames.ps1 -Path '\\PC1\saves','\\PC2\saves' -DryRun -ShowDetails"
    exit 0
}

# Logging function (moved up so it's available for parameter-repair diagnostics)
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        "ERROR" { Write-Host $logMessage -ForegroundColor Red }
        "WARN" { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        "DEBUG" { if ($ShowDetails) { Write-Host $logMessage -ForegroundColor Gray } }
        default { Write-Host $logMessage }
    }
}

# Repair common parameter-binding issues when the caller passes a comma-separated list
# or when the shell binds extra path-like arguments to other parameters (e.g. ConflictResolution)
function Test-IsPathLike([string]$s) {
    if (-not $s) { return $false }
    return ($s -match '^(\\\\|[A-Za-z]:\\)')
}

# Handle parameter binding issues - collect all path-like arguments from various sources
if ($ShowDetails) {
    Write-Log "Initial parameter values:" "DEBUG"
    Write-Log "  Path: $($Path -join '; ')" "DEBUG"
    Write-Log "  RemainingArgs: $($RemainingArgs -join '; ')" "DEBUG"
    Write-Log "  ConflictResolution: $ConflictResolution" "DEBUG"
    Write-Log "  args: $($args -join '; ')" "DEBUG"
}

# Reconstruct paths from fragmented parameters
# PowerShell may split comma-separated paths across multiple parameters
$reconstructedPaths = @()

# Start with the first path
if ($Path.Count -gt 0) {
    $firstPath = $Path[0]
    
    # Check if ConflictResolution contains a path fragment that should be combined with the first path
    if ($ConflictResolution -match "^['`"]?[A-Za-z]:\\") {
        # ConflictResolution looks like it starts a new path
        $reconstructedPaths += $firstPath
        
        # Extract the path from ConflictResolution (remove leading quote if present)
        $secondPathStart = $ConflictResolution.TrimStart("'").TrimStart('"')
        
        # Check if RemainingArgs contains the rest of the second path
        if ($RemainingArgs -and $RemainingArgs.Count -gt 0) {
            # RemainingArgs likely contains fragments like: "A11\','C:\Users\...\SwitchAndroid'"
            $remainingText = $RemainingArgs -join ' '
            
            # Try to reconstruct the second path
            if ($remainingText -match "([A-Za-z]:\\[^']+)") {
                $secondPathComplete = $matches[1].TrimEnd("'").TrimEnd('"')
                $reconstructedPaths += $secondPathComplete
                Write-Log "Reconstructed second path: $secondPathComplete" "DEBUG"
            } else {
                # Fallback: combine ConflictResolution with what we can from RemainingArgs
                $reconstructedPaths += $secondPathStart
            }
        } else {
            $reconstructedPaths += $secondPathStart
        }
        
        # Reset ConflictResolution to default
        $ConflictResolution = "Newest"
    } else {
        # Normal case - check if the first path contains commas
        if ($firstPath.Contains(',')) {
            Write-Log "Detected comma-separated string in -Path parameter, splitting into multiple entries..." "DEBUG"
            $splitPaths = $firstPath -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") }
            $reconstructedPaths += $splitPaths
        } else {
            $reconstructedPaths += $firstPath
        }
    }
}

# Add any remaining arguments that look like complete paths
if ($RemainingArgs) {
    foreach ($arg in $RemainingArgs) {
        if ($arg -match '^[A-Za-z]:\\' -and -not $arg.Contains(',')) {
            Write-Log "Found complete remaining path argument: $arg -- adding to Path list" "DEBUG"
            $reconstructedPaths += $arg.Trim().Trim('"').Trim("'")
        }
    }
}

# Normalize and deduplicate Path entries
$Path = $reconstructedPaths | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | Select-Object -Unique

Write-Log "Final processed paths: $($Path -join '; ')" "DEBUG"

# Write-Log is defined above for use during parameter-repair diagnostics

# Function to test if a path is accessible
function Test-PathAccess {
    param([string]$Path)
    
    try {
        # Fast network connectivity check for UNC paths
        if ($Path -match '^\\([^\\]+)\\') {
            $hostname = $matches[1]
            Write-Log "Testing network connectivity to $hostname..." "DEBUG"
            
            # Quick ping test - use different method for older PowerShell
            try {
                if (Get-Command Test-Connection -ParameterName TimeoutSeconds -ErrorAction SilentlyContinue) {
                    # PowerShell 6+ with TimeoutSeconds parameter
                    $ping = Test-Connection -ComputerName $hostname -Count 1 -Quiet -TimeoutSeconds 1 -ErrorAction SilentlyContinue
                } else {
                    # Older PowerShell - use .NET ping with timeout
                    $pingObj = New-Object System.Net.NetworkInformation.Ping
                    $result = $pingObj.Send($hostname, 1000)  # 1 second timeout
                    $ping = ($result.Status -eq 'Success')
                    $pingObj.Dispose()
                }
                
                if (-not $ping) {
                    # Many networks block ICMP/ping while SMB still works. Don't fail early on ping failure.
                    Write-Log "Network host $hostname did not respond to ICMP/ping (may be blocked); will attempt filesystem access" "WARN"
                } else {
                    Write-Log "Network host $hostname is reachable via ICMP" "DEBUG"
                }
            } catch {
                # If the ping/check fails for any reason, don't assume the share is unreachable — try filesystem access below.
                Write-Log "Could not test connectivity to $hostname (ping failed); will attempt filesystem access" "WARN"
            }
        }
        
        if (Test-Path -LiteralPath $Path) {
            $null = Get-ChildItem -LiteralPath $Path -ErrorAction Stop
            return $true
        } else {
            # Try to create the directory if it doesn't exist
            Write-Log "Path does not exist, attempting to create: $Path" "WARN"
            try {
                New-Item -ItemType Directory -Path $Path -Force | Out-Null
                Write-Log "Successfully created directory: $Path" "SUCCESS"
                return $true
            } catch {
                Write-Log "Cannot create directory: $Path - $($_.Exception.Message)" "ERROR"
                return $false
            }
        }
    } catch {
        Write-Log "Cannot access path: $Path - $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Function to get all files with metadata
function Get-FileInventory {
    param([string]$Path)
    
    $inventory = @{}
    
    try {
        $files = Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction Stop
        
        foreach ($file in $files) {
            $relativePath = $file.FullName.Substring($Path.Length).TrimStart('\')
            $inventory[$relativePath] = @{
                FullPath = $file.FullName
                RelativePath = $relativePath
                LastWriteTime = $file.LastWriteTime
                Length = $file.Length
                Hash = $null  # Will calculate if needed
            }
        }
        
        Write-Log "Found $($inventory.Count) files in $Path" "DEBUG"
        return $inventory
        
    } catch {
        Write-Log "Error scanning path $Path : $($_.Exception.Message)" "WARN"
        return @{}
    }
}

# Function to calculate file hash
function Get-FileHashQuick {
    param([string]$FilePath)
    
    try {
        # Try PowerShell 4.0+ Get-FileHash first
        if (Get-Command Get-FileHash -ErrorAction SilentlyContinue) {
            $hash = Get-FileHash -LiteralPath $FilePath -Algorithm MD5
            return $hash.Hash
        } else {
            # Fallback for older PowerShell versions using .NET
            $md5 = [System.Security.Cryptography.MD5]::Create()
            $fileStream = [System.IO.File]::OpenRead($FilePath)
            $hashBytes = $md5.ComputeHash($fileStream)
            $fileStream.Close()
            $md5.Dispose()
            
            # Convert bytes to hex string
            $hashString = ""
            foreach ($byte in $hashBytes) {
                $hashString += $byte.ToString("X2")
            }
            return $hashString
        }
    } catch {
        Write-Log "Error calculating hash for $FilePath : $($_.Exception.Message)" "WARN"
        return $null
    }
}

# Function to create backup
function Backup-Inventory {
    param(
        [hashtable]$FileInventory,
        [string]$SourcePath,
        [string]$ArchivePath
    )
    
    try {
        # Extract IP and folder info from UNC path
        $pathInfo = if ($SourcePath -match '^\\\\([^\\]+)\\(.+)$') {
            $ip = $matches[1]
            $folder = $matches[2] -replace '\\', '_'
            "${ip}_${folder}"
        } else {
            $SourcePath -replace '[\\/:*?"<>|]', '_'
        }
        
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupDir = Join-Path $ArchivePath "$pathInfo\$timestamp"
        
        if ($DryRun) {
            Write-Log "[DRY RUN] Would create backup at: $backupDir" "INFO"
            return $backupDir
        }
        
        # Create backup directory
        if (-not (Test-Path $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }
        
        # Copy files to backup
        $copiedCount = 0
        foreach ($file in $FileInventory.Values) {
            $backupFile = Join-Path $backupDir $file.RelativePath
            $backupFileDir = Split-Path $backupFile -Parent
            
            if (-not (Test-Path $backupFileDir)) {
                New-Item -ItemType Directory -Path $backupFileDir -Force | Out-Null
            }
            
            Copy-Item -LiteralPath $file.FullPath -Destination $backupFile -Force
            $copiedCount++
        }
        
    Write-Log "Created backup with $copiedCount files at: $backupDir" "SUCCESS"
    return $backupDir
        
    } catch {
        Write-Log "Error creating backup: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Function to resolve file conflicts
function Resolve-FileConflict {
    param(
        [hashtable]$File1,
        [hashtable]$File2,
        [string]$ConflictResolution
    )
    
    # First check if files are identical
    if ($null -eq $File1.Hash) { $File1.Hash = Get-FileHashQuick $File1.FullPath }
    if ($null -eq $File2.Hash) { $File2.Hash = Get-FileHashQuick $File2.FullPath }
    
    if ($File1.Hash -eq $File2.Hash) {
        Write-Log "Files are identical: $($File1.RelativePath)" "DEBUG"
        return $File1  # Files are the same, return either one
    }
    
    Write-Log "Conflict detected for: $($File1.RelativePath)" "WARN"
    Write-Log "  File1: $($File1.LastWriteTime) ($($File1.Length) bytes) from $($File1.FullPath)" "WARN"
    Write-Log "  File2: $($File2.LastWriteTime) ($($File2.Length) bytes) from $($File2.FullPath)" "WARN"
    
    switch ($ConflictResolution) {
        "Newest" {
            if ($File1.LastWriteTime -gt $File2.LastWriteTime) {
                Write-Log "Resolving conflict: Using newer file from first location" "INFO"
                return $File1
            } else {
                Write-Log "Resolving conflict: Using newer file from second location" "INFO"
                return $File2
            }
        }
        "Largest" {
            if ($File1.Length -gt $File2.Length) {
                Write-Log "Resolving conflict: Using larger file from first location" "INFO"
                return $File1
            } else {
                Write-Log "Resolving conflict: Using larger file from second location" "INFO"
                return $File2
            }
        }
        "Manual" {
            Write-Host ""
            Write-Host "CONFLICT RESOLUTION REQUIRED" -ForegroundColor Yellow
            Write-Host "File: $($File1.RelativePath)"
            Write-Host "1. $($File1.FullPath)"
            Write-Host "   Modified: $($File1.LastWriteTime), Size: $($File1.Length) bytes"
            Write-Host "2. $($File2.FullPath)"
            Write-Host "   Modified: $($File2.LastWriteTime), Size: $($File2.Length) bytes"
            Write-Host ""
            
            do {
                $choice = Read-Host "Choose file to keep [1/2/s(kip)]"
                switch ($choice.ToLower()) {
                    "1" { 
                        Write-Log "Manual selection: Using file from first location" "INFO"
                        return $File1 
                    }
                    "2" { 
                        Write-Log "Manual selection: Using file from second location" "INFO"
                        return $File2 
                    }
                    "s" { 
                        Write-Log "Manual selection: Skipping file" "WARN"
                        return $null 
                    }
                    default { Write-Host "Invalid choice. Please enter 1, 2, or s." -ForegroundColor Red }
                }
            } while ($true)
        }
        default {
            Write-Log "Unknown conflict resolution method: $ConflictResolution" "ERROR"
            return $File1  # Default to first file
        }
    }
}

# Function to sync files between locations
function Sync-Files {
    param(
        [hashtable[]]$Inventories,
        [string[]]$Paths
    )
    
    # Create merged file list
    $allFiles = @{}
    
    # Collect all unique files
    for ($i = 0; $i -lt $Inventories.Count; $i++) {
        foreach ($relativePath in $Inventories[$i].Keys) {
            if (-not $allFiles.ContainsKey($relativePath)) {
                $allFiles[$relativePath] = @()
            }
            $allFiles[$relativePath] += $Inventories[$i][$relativePath]
        }
    }
    
    Write-Log "Processing $($allFiles.Count) unique files for synchronization" "INFO"
    
    $syncActions = @()
    
    foreach ($relativePath in $allFiles.Keys) {
        $fileVersions = $allFiles[$relativePath]
        # Find the source file (newest or resolved)
        if ($fileVersions.Count -eq 1) {
            $sourceFile = $fileVersions[0]
        } else {
            $resolvedFile = $fileVersions[0]
            for ($j = 1; $j -lt $fileVersions.Count; $j++) {
                $resolvedFile = Resolve-FileConflict -File1 $resolvedFile -File2 $fileVersions[$j] -ConflictResolution $ConflictResolution
                if (-not $resolvedFile) {
                    Write-Log "Skipping file due to manual skip: $relativePath" "WARN"
                    break
                }
            }
            $sourceFile = $resolvedFile
        }
        # Copy to all locations where missing or outdated
        for ($i = 0; $i -lt $Paths.Count; $i++) {
            $targetPath = Join-Path $Paths[$i] $relativePath
            $targetExists = $false
            foreach ($fileVersion in $fileVersions) {
                if ($fileVersion.FullPath -eq $targetPath) {
                    $targetExists = $true
                    # If not the resolved version, schedule update
                    if ($fileVersion.FullPath -ne $sourceFile.FullPath) {
                        $syncActions += @{
                            Action = "Copy"
                            Source = $sourceFile.FullPath
                            Target = $targetPath
                            RelativePath = $relativePath
                            Reason = "Updating with resolved version"
                        }
                    }
                }
            }
            if (-not $targetExists) {
                $syncActions += @{
                    Action = "Copy"
                    Source = $sourceFile.FullPath
                    Target = $targetPath
                    RelativePath = $relativePath
                    Reason = "File missing in target location (empty or new)"
                }
            }
        }
    }
    return $syncActions
}

# Function to execute sync actions
function Invoke-SyncActions {
    param([hashtable[]]$SyncActions)
    
    if ($SyncActions.Count -eq 0) {
        Write-Log "No sync actions required - all files are already synchronized" "SUCCESS"
        return
    }
    
    Write-Log "Executing $($SyncActions.Count) sync actions" "INFO"
    
    $successCount = 0
    $errorCount = 0
    
    foreach ($action in $SyncActions) {
        try {
            if ($DryRun) {
                Write-Log "[DRY RUN] Would copy: $($action.RelativePath)" "INFO"
                Write-Log "  From: $($action.Source)" "DEBUG"
                Write-Log "  To: $($action.Target)" "DEBUG"
                Write-Log "  Reason: $($action.Reason)" "DEBUG"
                $successCount++
            } else {
                # Check if target is on network and accessible before attempting
                $targetDir = Split-Path $action.Target -Parent
                $targetHost = ""
                if ($targetDir -match '^\\\\([^\\]+)\\') {
                    $targetHost = $matches[1]
                    # Quick connectivity check
                    try {
                        if (Get-Command Test-Connection -ParameterName TimeoutSeconds -ErrorAction SilentlyContinue) {
                            $ping = Test-Connection -ComputerName $targetHost -Count 1 -Quiet -TimeoutSeconds 1 -ErrorAction SilentlyContinue
                        } else {
                            $pingObj = New-Object System.Net.NetworkInformation.Ping
                            $result = $pingObj.Send($targetHost, 1000)
                            $ping = ($result.Status -eq 'Success')
                            $pingObj.Dispose()
                        }
                        
                        if (-not $ping) {
                            Write-Log "Target host $targetHost unreachable, skipping: $($action.RelativePath)" "WARN"
                            $errorCount++
                            continue
                        }
                    } catch {
                        Write-Log "Could not test connectivity to $targetHost, skipping: $($action.RelativePath)" "WARN"
                        $errorCount++
                        continue
                    }
                }
                
                # Ensure target directory exists
                if (-not (Test-Path $targetDir)) {
                    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                }
                
                Copy-Item -LiteralPath $action.Source -Destination $action.Target -Force
                Write-Log "Synced: $($action.RelativePath)" "SUCCESS"
                $successCount++
            }
        } catch {
            Write-Log "Error syncing $($action.RelativePath): $($_.Exception.Message)" "WARN"
            $errorCount++
        }
    }
    
    Write-Log "Sync completed: $successCount successful, $errorCount errors" "INFO"
}

# Main execution
try {
    Write-Log "Starting game save file synchronization" "INFO"
    Write-Log "Raw Path parameter: $Path" "DEBUG"
    Write-Log "Path count: $($Path.Count)" "DEBUG"
    Write-Log "Path type: $($Path.GetType().Name)" "DEBUG"
    
    # If we received a comma-separated string, split it
    if ($Path.Count -eq 1 -and $Path[0].Contains(',')) {
        Write-Log "Detected comma-separated string, splitting..." "DEBUG"
        $Path = $Path[0] -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") }
    }
    
    Write-Log "Paths after processing: $($Path -join ', ')" "INFO"
    Write-Log "Archive: $Archive" "INFO"
    Write-Log "Conflict Resolution: $ConflictResolution" "INFO"
    
    # Validate all paths are accessible
    $accessiblePaths = @()
    foreach ($hostPath in $Path) {
        if (Test-PathAccess -Path $hostPath) {
            $accessiblePaths += $hostPath
            Write-Log "Path accessible: $hostPath" "SUCCESS"
        } else {
            Write-Log "Path not accessible (skipping): $hostPath" "WARN"
        }
    }
    
    if ($accessiblePaths.Count -eq 0) {
        Write-Log "No accessible paths found. Cannot proceed with synchronization." "ERROR"
        exit 1
    } elseif ($accessiblePaths.Count -eq 1) {
        Write-Log "Only one accessible path found. Synchronization requires at least 2 paths, but continuing anyway for backup purposes." "WARN"
        # Continue with backup creation only
    } else {
        Write-Log "Found $($accessiblePaths.Count) accessible paths for synchronization" "SUCCESS"
    }
    
    # Create file inventories
    Write-Log "Scanning files in all locations..." "INFO"
    $inventories = @()
    foreach ($hostPath in $accessiblePaths) {
        $inventory = Get-FileInventory -Path $hostPath
        $inventories += $inventory
    }
    
    # Create backups before synchronization
    Write-Log "Creating backups..." "INFO"
    $backupPaths = @()
    for ($i = 0; $i -lt $accessiblePaths.Count; $i++) {
        if ($inventories[$i].Count -gt 0) {
            $backupPath = Backup-Inventory -FileInventory $inventories[$i] -SourcePath $accessiblePaths[$i] -ArchivePath $Archive
            if ($backupPath) {
                $backupPaths += $backupPath
            }
        }
    }
    
    # Generate sync actions (only if we have multiple accessible paths)
    if ($accessiblePaths.Count -ge 2) {
        Write-Log "Analyzing differences and generating sync plan..." "INFO"
    $syncActions = Sync-Files -Inventories $inventories -Paths $accessiblePaths

    # Execute sync actions
    Invoke-SyncActions -SyncActions $syncActions
    } else {
        Write-Log "Skipping synchronization (only one accessible path). Backup created successfully." "WARN"
    }
    
    Write-Log "Game save file synchronization completed successfully" "SUCCESS"
    
    if ($backupPaths.Count -gt 0) {
        Write-Log "Backups created at:" "INFO"
        foreach ($backupPath in $backupPaths) {
            Write-Log "  $backupPath" "INFO"
        }
    }

} catch {
    Write-Log "Unexpected error during synchronization: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}