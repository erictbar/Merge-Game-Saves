# MergeGames.ps1 - Sync game save files across multiple PCs with backup
param(
    [Parameter(Mandatory=$true, ValueFromRemainingArguments=$false)]
    [string[]]$Path,

    [string]$Archive = "$env:USERPROFILE\Documents\GameSaves\Archive",

    [string[]]$Ignore = @(),

    [switch]$DryRun,

    [switch]$ShowDetails,

    [string]$ConflictResolution = "Newest", # Newest, Largest, Manual

    [switch]$Help,
    
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$RemainingArgs
)

# Set ErrorActionPreference to prevent external callers (like Playnite) from affecting error handling
$ErrorActionPreference = 'Continue'

# Show help if requested
if ($Help) {
    Write-Host "MergeGames.ps1 - Sync game save files across multiple PCs"
    Write-Host ""
    Write-Host "Usage: MergeGames.ps1 -Path <path1>,<path2> [options]"
    Write-Host ""
    Write-Host "Parameters:"
    Write-Host "  -Path <path1>,<path2>     SMB paths to sync (comma-separated array)"
    Write-Host "  -Archive <path>           Archive location (default: %USERPROFILE%\OneDrive\Saves\Automation)"
    Write-Host "  -Ignore <item1>,<item2>   Ignore directory names, file extensions, or exact file names"
    Write-Host "  --Eden <titleId> <path>   Create <path>.zip with entries under <titleId>/ for Eden on Android"
    Write-Host "  -DryRun                   Show what would be done without making changes"
    Write-Host "  -ShowDetails              Show detailed logging"
    Write-Host "  -ConflictResolution       How to resolve conflicts: Newest, Largest, Manual (default: Newest)"
    Write-Host "  -Help                     Show this help message"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  MergeGames.ps1 -Path '\\192.168.1.100\d\Users\user\Gaes\GOG\Nukitashi\savedata','\\192.168.1.101\c\Apps\GOG\NUKITASHI\savedata'"
    Write-Host "  MergeGames.ps1 -Path '\\PC1\saves','\\PC2\saves' -DryRun -ShowDetails"
    Write-Host "  MergeGames.ps1 -Path '\\PC1\saves','\\PC2\saves' -Ignore 'Unity','.log','Player-prev.log'"
    Write-Host "  MergeGames.ps1 -Path '\\PC1\saves','\\PC2\saves' --Eden '0100b280106a0000' 'Y:\Backup\Saves\Emulators\Eden\Aviary Attorney_ Definitive Edition'"
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

function Parse-ExtendedArguments {
    param(
        [string[]]$Arguments,
        [string]$FallbackEdenPath
    )

    $parsedArgs = @{
        Eden = $null
        UnhandledArgs = @()
    }

    if (-not $Arguments) {
        return $parsedArgs
    }

    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $argument = $Arguments[$i]

        switch -Regex ($argument) {
            '^--?Eden$' {
                if ($parsedArgs.Eden) {
                    throw "Eden export can only be specified once."
                }

                if ($i + 1 -ge $Arguments.Count) {
                    throw "Eden export requires a title ID and destination path."
                }

                $titleId = $Arguments[$i + 1].Trim().Trim('"').Trim("'")
                $i++

                if (-not $titleId) {
                    throw "Eden export title ID cannot be empty."
                }

                $destinationFragments = @()
                while ($i + 1 -lt $Arguments.Count) {
                    $nextArgument = $Arguments[$i + 1]
                    if ($nextArgument -match '^--?[A-Za-z]') {
                        break
                    }

                    $destinationFragments += $nextArgument
                    $i++
                }

                if ($destinationFragments.Count -eq 0 -and $FallbackEdenPath) {
                    $destinationFragments += $FallbackEdenPath
                }

                if ($destinationFragments.Count -eq 0) {
                    throw "Eden export requires a destination path."
                }

                $destinationPath = (($destinationFragments | ForEach-Object {
                    $_.Trim().Trim('"').Trim("'")
                }) -join ' ').Trim().TrimEnd('\\')

                if (-not $destinationPath) {
                    throw "Eden export destination path cannot be empty."
                }

                $parsedArgs.Eden = @{
                    TitleId = $titleId
                    OutputPath = $destinationPath
                }
            }
            default {
                $parsedArgs.UnhandledArgs += $argument
            }
        }
    }

    return $parsedArgs
}

function Get-EdenZipPath {
    param([string]$OutputPath)

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

    if ($OutputPath -match '\.zip$') {
        $directory = Split-Path $OutputPath -Parent
        $fileName = [System.IO.Path]::GetFileNameWithoutExtension($OutputPath)
        return (Join-Path $directory "$fileName`_$timestamp.zip")
    }

    return "$OutputPath`_$timestamp.zip"
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
# PowerShell command-line parsing may split paths with spaces across multiple parameters
$reconstructedPaths = @()
$defaultArchivePath = "$env:USERPROFILE\Documents\GameSaves\Archive"

# Determine whether -Ignore/--Ignore was explicitly provided by the caller.
# If it wasn't, any values bound to $Ignore are likely path fragments from broken parsing.
# NOTE: $PSBoundParameters.ContainsKey() is true even for values that landed on these
# parameters via accidental positional binding (a side effect of mis-split path fragments),
# so it cannot be used as a signal here. $MyInvocation.Line is also unreliable - it is empty
# when the script is invoked via "powershell.exe -File ...". The only trustworthy source of
# the literal tokens the process received is the raw process command line.
$rawCommandLineArgs = [Environment]::GetCommandLineArgs()
$invocationHasIgnoreFlag = @($rawCommandLineArgs | Where-Object { $_ -match '(?i)^--?Ignore$' }).Count -gt 0
$ignoreExplicitlySpecified = $invocationHasIgnoreFlag

$invocationHasArchiveFlag = @($rawCommandLineArgs | Where-Object { $_ -match '(?i)^-Archive$' }).Count -gt 0
$archiveExplicitlySpecified = $invocationHasArchiveFlag

# Valid ConflictResolution values
$validConflictResolutions = @("Newest", "Largest", "Manual")

# Check if ConflictResolution contains a path fragment instead of a valid option
$conflictIsPathFragment = $false
if ($ConflictResolution -and $ConflictResolution -notin $validConflictResolutions) {
    Write-Log "ConflictResolution parameter contains non-standard value: '$ConflictResolution' - treating as path fragment" "DEBUG"
    $conflictIsPathFragment = $true
}

$extendedArgs = Parse-ExtendedArguments -Arguments $RemainingArgs -FallbackEdenPath $(if ($conflictIsPathFragment) { $ConflictResolution } else { $null })
$RemainingArgs = $extendedArgs.UnhandledArgs
$EdenExport = $extendedArgs.Eden

if ($ignoreExplicitlySpecified -and -not $invocationHasIgnoreFlag -and $Ignore.Count -gt 0) {
    $ignoreContainsPathFragments = @($Ignore | Where-Object { $_ -match '[\\/]' -or $_ -match '^[A-Za-z]:' }).Count -gt 0
    if ($ignoreContainsPathFragments) {
        Write-Log "Ignore appears to contain path fragments (no explicit -Ignore flag); reclassifying as path fragments" "DEBUG"
        $ignoreExplicitlySpecified = $false
    }
}

if ($archiveExplicitlySpecified -and -not $invocationHasArchiveFlag -and $Archive -and $Archive -ne $defaultArchivePath) {
    $archiveLooksLikeSimpleToken = $Archive -match '^[^\\/:]+$'
    $likelyBindingCorruption = $conflictIsPathFragment -or
        $RemainingArgs.Count -gt 0 -or
        (@($Ignore | Where-Object { $_ -match '[\\/]' -or $_ -match '^[A-Za-z]:' }).Count -gt 0)

    if ($archiveLooksLikeSimpleToken -and $likelyBindingCorruption) {
        Write-Log "Archive appears to contain a path fragment (no explicit -Archive flag); reclassifying as path fragment" "DEBUG"
        $archiveExplicitlySpecified = $false
    }
}

if ($ignoreExplicitlySpecified -and $Ignore.Count -gt 0 -and $RemainingArgs.Count -gt 0) {
    $ignoreContinuations = @()
    while ($RemainingArgs.Count -gt 0 -and -not (Test-IsPathLike $RemainingArgs[0])) {
        $ignoreContinuations += $RemainingArgs[0]
        $RemainingArgs = @($RemainingArgs | Select-Object -Skip 1)
    }
    $Ignore += $ignoreContinuations
}

if ($archiveExplicitlySpecified -and $Archive -and $Archive -match ',') {
    Write-Log "Archive contains comma-separated fragments; reclassifying as path fragments" "DEBUG"
    $archiveExplicitlySpecified = $false
}

if ($EdenExport) {
    if ($conflictIsPathFragment -and $EdenExport.OutputPath.TrimEnd('\\') -eq $ConflictResolution.Trim().Trim('"').Trim("'").TrimEnd('\\')) {
        $ConflictResolution = "Newest"
        $conflictIsPathFragment = $false
    }

    Write-Log "Eden export requested for title ID $($EdenExport.TitleId) -> $(Get-EdenZipPath -OutputPath $EdenExport.OutputPath)" "DEBUG"
}

# Collect all potential path fragments from Path, ConflictResolution, and RemainingArgs
$allFragments = @()
if ($Path) { $allFragments += $Path }
if (-not $archiveExplicitlySpecified -and $Archive -and $Archive -ne $defaultArchivePath) {
    Write-Log "Archive was not explicitly specified; treating Archive value as path fragment: $Archive" "DEBUG"
    $allFragments += $Archive
    $Archive = $defaultArchivePath
}
if (-not $ignoreExplicitlySpecified -and $Ignore.Count -gt 0) {
    Write-Log "Ignore rules were not explicitly specified; treating Ignore values as path fragments: $($Ignore -join ' | ')" "DEBUG"
    $allFragments += $Ignore
    $Ignore = @()
}
if ($conflictIsPathFragment) { $allFragments += $ConflictResolution }
if ($RemainingArgs) { $allFragments += $RemainingArgs }

Write-Log "All parameter fragments: $($allFragments -join ' | ')" "DEBUG"

# Strategy: Reassemble paths by identifying UNC/drive-letter boundaries
# A new path starts with \\ or X:\ 
$currentPath = ""
foreach ($fragment in $allFragments) {
    $fragment = $fragment.Trim().Trim('"').Trim("'").Trim()
    
    # Skip empty fragments
    if (-not $fragment) { continue }
    
    # Check if this fragment starts a new path
    if ($fragment -match '^(\\\\|[A-Za-z]:\\)') {
        # Save the previous path if we have one
        if ($currentPath) {
            $reconstructedPaths += $currentPath.TrimEnd('\')
            Write-Log "Reconstructed path: $currentPath" "DEBUG"
        }
        # Start building new path
        $currentPath = $fragment
    } else {
        # This is a continuation fragment (space-separated part of current path)
        if ($currentPath) {
            # Append with a space
            $currentPath += " $fragment"
        } else {
            # Orphan fragment with no preceding path start - treat as standalone
            $currentPath = $fragment
        }
    }
}

# Don't forget the last path being built
if ($currentPath) {
    $reconstructedPaths += $currentPath.TrimEnd('\')
    Write-Log "Reconstructed path: $currentPath" "DEBUG"
}

# Process comma-separated paths within individual elements
$finalPaths = @()
foreach ($pathItem in $reconstructedPaths) {
    if ($pathItem.Contains(',')) {
        Write-Log "Detected comma-separated string in path element, splitting: '$pathItem'" "DEBUG"
        $splitPaths = $pathItem -split ',' | ForEach-Object { 
            $_.Trim().Trim('"').Trim("'").Trim().TrimEnd('\')
        } | Where-Object { $_ }
        $finalPaths += $splitPaths
    } else {
        $finalPaths += $pathItem.TrimEnd('\')
    }
}

$reconstructedPaths = $finalPaths

# Reset ConflictResolution to default if it was actually a path fragment
if ($conflictIsPathFragment) {
    Write-Log "Resetting ConflictResolution from '$ConflictResolution' to 'Newest' (was path fragment)" "DEBUG"
    $ConflictResolution = "Newest"
}

# Normalize and deduplicate Path entries
$Path = $reconstructedPaths | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | Select-Object -Unique
$Ignore = $Ignore | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ -ne '' } | Select-Object -Unique

Write-Log "Final processed paths: $($Path -join '; ')" "DEBUG"
if ($Ignore.Count -gt 0) {
    Write-Log "Ignoring: $($Ignore -join '; ')" "DEBUG"
}

# Write-Log is defined above for use during parameter-repair diagnostics

# Function to test if a path is accessible with timeout
function Test-PathAccess {
    param([string]$Path)
    
    try {
        # Fast network connectivity check for UNC paths
        if ($Path -match '^\\\\([^\\]+)\\') {
            $hostname = $matches[1]
            Write-Log "Testing network connectivity to $hostname..." "DEBUG"
            
            # Quick TCP port test for SMB (port 445) - faster than ping
            try {
                $tcpClient = New-Object System.Net.Sockets.TcpClient
                $connectTask = $tcpClient.ConnectAsync($hostname, 445)
                $timeout = 2000  # 2 second timeout
                
                if ($connectTask.Wait($timeout)) {
                    $tcpClient.Close()
                    Write-Log "Network host $hostname is reachable on SMB port 445" "DEBUG"
                } else {
                    $tcpClient.Close()
                    Write-Log "Network host $hostname is not reachable (timeout after 2s) - skipping" "WARN"
                    return $false
                }
            } catch {
                Write-Log "Network host $hostname is not reachable - skipping" "WARN"
                return $false
            }
        }
        
        if (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue) {
            try {
                $null = Get-ChildItem -LiteralPath $Path -ErrorAction Stop
                return $true
            } catch {
                Write-Log "Cannot access path: $Path - $($_.Exception.Message)" "WARN"
                return $false
            }
        } else {
            # Try to create the directory if it doesn't exist
            Write-Log "Path does not exist, attempting to create: $Path" "DEBUG"
            try {
                New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
                Write-Log "Successfully created directory: $Path" "SUCCESS"
                return $true
            } catch {
                Write-Log "Cannot create directory (network may be offline): $Path" "WARN"
                return $false
            }
        }
    } catch {
        Write-Log "Cannot access path (network may be offline): $Path" "WARN"
        return $false
    }
}

# Function to test whether a file matches an ignore rule
function Test-IsIgnoredFile {
    param(
        [System.IO.FileInfo]$File,
        [string]$RootPath,
        [string[]]$IgnoreRules
    )

    if (-not $IgnoreRules -or $IgnoreRules.Count -eq 0) {
        return $false
    }

    $relativePath = $File.FullName.Substring($RootPath.Length).TrimStart('\')
    $directoryNames = (Split-Path $relativePath -Parent) -split '\\' | Where-Object { $_ }

    foreach ($rule in $IgnoreRules) {
        if ($rule.StartsWith('.')) {
            if ($File.Extension -ieq $rule) {
                return $true
            }
        } elseif ($File.Name -ieq $rule -or $directoryNames -contains $rule) {
            return $true
        }
    }

    return $false
}

# Function to get all files with metadata
function Get-FileInventory {
    param(
        [string]$Path,
        [string[]]$IgnoreRules
    )
    
    $inventory = @{}
    
    try {
        $files = Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction Stop
        
        foreach ($file in $files) {
            if (Test-IsIgnoredFile -File $file -RootPath $Path -IgnoreRules $IgnoreRules) {
                Write-Log "Ignoring: $($file.FullName)" "DEBUG"
                continue
            }

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
        if (-not (Test-Path $backupDir -ErrorAction Stop)) {
            New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop | Out-Null
        }
        
        # Copy files to backup
        $copiedCount = 0
        foreach ($file in $FileInventory.Values) {
            $backupFile = Join-Path $backupDir $file.RelativePath
            $backupFileDir = Split-Path $backupFile -Parent
            
            if (-not (Test-Path $backupFileDir -ErrorAction Stop)) {
                New-Item -ItemType Directory -Path $backupFileDir -Force -ErrorAction Stop | Out-Null
            }
            
            Copy-Item -LiteralPath $file.FullPath -Destination $backupFile -Force -ErrorAction Stop
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

function Get-MergedFilePlan {
    param([hashtable[]]$Inventories)

    $allFiles = @{}

    for ($i = 0; $i -lt $Inventories.Count; $i++) {
        foreach ($relativePath in $Inventories[$i].Keys) {
            if (-not $allFiles.ContainsKey($relativePath)) {
                $allFiles[$relativePath] = @()
            }

            $allFiles[$relativePath] += $Inventories[$i][$relativePath]
        }
    }

    $mergedFiles = @{}

    foreach ($relativePath in $allFiles.Keys) {
        $fileVersions = $allFiles[$relativePath]

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

        if ($sourceFile) {
            $mergedFiles[$relativePath] = @{
                SourceFile = $sourceFile
                FileVersions = $fileVersions
            }
        }
    }

    return $mergedFiles
}

# Function to sync files between locations
function Sync-Files {
    param(
        [hashtable]$MergedFiles,
        [string[]]$Paths
    )

    Write-Log "Processing $($MergedFiles.Count) unique files for synchronization" "INFO"
    
    $syncActions = @()
    
    foreach ($relativePath in $MergedFiles.Keys) {
        $sourceFile = $MergedFiles[$relativePath].SourceFile
        $fileVersions = $MergedFiles[$relativePath].FileVersions

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

function Export-EdenPackage {
    param(
        [hashtable]$MergedFiles,
        [string]$TitleId,
        [string]$OutputPath
    )

    if (-not $MergedFiles -or $MergedFiles.Count -eq 0) {
        Write-Log "Skipping Eden export because there are no files to package." "WARN"
        return $null
    }

    $zipPath = Get-EdenZipPath -OutputPath $OutputPath

    if ($DryRun) {
        Write-Log "[DRY RUN] Would create Eden package at: $zipPath" "INFO"
        Write-Log "[DRY RUN] Would include $($MergedFiles.Count) files under $TitleId/" "INFO"
        return $zipPath
    }

    try {
        $zipDirectory = Split-Path $zipPath -Parent
        if ($zipDirectory -and -not (Test-Path -LiteralPath $zipDirectory -ErrorAction SilentlyContinue)) {
            New-Item -ItemType Directory -Path $zipDirectory -Force -ErrorAction Stop | Out-Null
        }

        if (Test-Path -LiteralPath $zipPath -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction Stop
        }

        Add-Type -AssemblyName System.IO.Compression

        $fileStream = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew)
        try {
            $zipArchive = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                foreach ($relativePath in ($MergedFiles.Keys | Sort-Object)) {
                    $sourceFile = $MergedFiles[$relativePath].SourceFile
                    $entryPath = ($TitleId.Trim('/')) + '/' + ($relativePath.TrimStart('\\') -replace '\\', '/')
                    $entry = $zipArchive.CreateEntry($entryPath, [System.IO.Compression.CompressionLevel]::Optimal)
                    $entryStream = $entry.Open()

                    try {
                        $sourceStream = [System.IO.File]::OpenRead($sourceFile.FullPath)
                        try {
                            $sourceStream.CopyTo($entryStream)
                        } finally {
                            $sourceStream.Dispose()
                        }
                    } finally {
                        $entryStream.Dispose()
                    }
                }
            } finally {
                $zipArchive.Dispose()
            }
        } finally {
            $fileStream.Dispose()
        }

        Write-Log "Created Eden package with $($MergedFiles.Count) files at: $zipPath" "SUCCESS"
        return $zipPath
    } catch {
        Write-Log "Error creating Eden package: $($_.Exception.Message)" "ERROR"
        return $null
    }
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
                if (-not (Test-Path $targetDir -ErrorAction Stop)) {
                    New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction Stop | Out-Null
                }
                
                Copy-Item -LiteralPath $action.Source -Destination $action.Target -Force -ErrorAction Stop
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
    if ($Ignore.Count -gt 0) {
        Write-Log "Ignore rules: $($Ignore -join ', ')" "INFO"
    }
    Write-Log "Conflict Resolution: $ConflictResolution" "INFO"
    if ($EdenExport) {
        Write-Log "Eden export: $($EdenExport.TitleId) -> $(Get-EdenZipPath -OutputPath $EdenExport.OutputPath)" "INFO"
    }
    
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
        $inventory = Get-FileInventory -Path $hostPath -IgnoreRules $Ignore
        $inventories += $inventory
    }

    $mergedFiles = Get-MergedFilePlan -Inventories $inventories
    
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
    $syncActions = Sync-Files -MergedFiles $mergedFiles -Paths $accessiblePaths

    # Execute sync actions
    Invoke-SyncActions -SyncActions $syncActions
    } else {
        Write-Log "Skipping synchronization (only one accessible path). Backup created successfully." "WARN"
    }

    $edenPackagePath = $null
    if ($EdenExport) {
        Write-Log "Creating Eden export package..." "INFO"
        $edenPackagePath = Export-EdenPackage -MergedFiles $mergedFiles -TitleId $EdenExport.TitleId -OutputPath $EdenExport.OutputPath
    }
    
    Write-Log "Game save file synchronization completed successfully" "SUCCESS"
    
    if ($backupPaths.Count -gt 0) {
        Write-Log "Backups created at:" "INFO"
        foreach ($backupPath in $backupPaths) {
            Write-Log "  $backupPath" "INFO"
        }
    }

    if ($edenPackagePath) {
        Write-Log "Eden package created at: $edenPackagePath" "INFO"
    }

} catch {
    Write-Log "Unexpected error during synchronization: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}