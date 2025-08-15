# createSyncScript.ps1
# Interactive script to generate Playnite sync commands for MergeGames.ps1

function Parse-ExistingCommand($cmd) {
    $scriptPath = ""
    $locations = @()
    $archive = ""

    # Extract script path from -File parameter  
    if ($cmd -match '-File\s+"([^"]+)"') {
        $scriptPath = $matches[1]
    }

    # Extract everything after -Path up to next switch or end
    if ($cmd -match '-Path\s+(.+?)(?:\s+-Archive|\s*$)') {
        $pathValue = $matches[1].Trim()
        
        # Remove outer quotes if present
        if ($pathValue.StartsWith('"') -and $pathValue.EndsWith('"')) {
            $pathValue = $pathValue.Substring(1, $pathValue.Length - 2)
        } elseif ($pathValue.StartsWith("'") -and $pathValue.EndsWith("'")) {
            $pathValue = $pathValue.Substring(1, $pathValue.Length - 2)
        }
        
        # Split on commas and clean each location
        $locations = $pathValue -split ',' | ForEach-Object {
            $loc = $_.Trim()
            # Remove quotes from individual locations
            if ($loc.StartsWith('"') -and $loc.EndsWith('"')) {
                $loc = $loc.Substring(1, $loc.Length - 2)
            } elseif ($loc.StartsWith("'") -and $loc.EndsWith("'")) {
                $loc = $loc.Substring(1, $loc.Length - 2)
            }
            $loc
        }
    }
    
    # Extract archive path
    if ($cmd -match '-Archive\s+"([^"]+)"') {
        $archive = $matches[1]
    }

    return @{ 
        ScriptPath = $scriptPath
        Locations = $locations
        Archive = $archive 
    }
}

# Main script logic
Write-Host "=== MergeGames.ps1 Command Builder ===" -ForegroundColor Cyan
Write-Host ""

# Option to import existing command
$existingCmd = Read-Host "Paste existing command to modify (or press Enter to start fresh)"

if ($existingCmd) {
    Write-Host "Parsing existing command..." -ForegroundColor Yellow
    $parsed = Parse-ExistingCommand $existingCmd
    $scriptPath = $parsed.ScriptPath
    $saveLocations = $parsed.Locations
    $archiveFolder = $parsed.Archive
    
    Write-Host "Found:" -ForegroundColor Green
    Write-Host "  Script: $scriptPath"
    Write-Host "  Locations: $($saveLocations.Count) paths"
    $saveLocations | ForEach-Object { Write-Host "    $_" }
    if ($archiveFolder) { Write-Host "  Archive: $archiveFolder" }
} else {
    # Start fresh
    $defaultScript = "C:\Users\erict\OneDrive\Developer\Scripts\Public\Merge Game Saves\MergeGames.ps1"
    $scriptPath = Read-Host "MergeGames.ps1 path [$defaultScript]"
    if (-not $scriptPath) { $scriptPath = $defaultScript }
    
    if (-not (Test-Path $scriptPath)) {
        Write-Host "Script not found: $scriptPath" -ForegroundColor Red
        exit 1
    }

    # Get initial locations
    Write-Host "Enter save locations (minimum 2):"
    $saveLocations = @()
    do {
        $loc = Read-Host "Location $(($saveLocations.Count + 1)) (or Enter to finish)"
        if ($loc) { $saveLocations += $loc }
    } while ($loc -and $saveLocations.Count -lt 10)
    
    if ($saveLocations.Count -lt 2) {
        Write-Host "Need at least 2 locations" -ForegroundColor Red
        exit 1
    }

    $archiveFolder = Read-Host "Archive folder (optional)"
}

# Add more locations
Write-Host ""
Write-Host "Add more locations:" -ForegroundColor Yellow
do {
    $newLoc = Read-Host "Additional location (or Enter to finish)"
    if ($newLoc) { $saveLocations += $newLoc }
} while ($newLoc)

# Build final command
$pathsArg = "'" + ($saveLocations -join "','") + "'"
$archiveArg = if ($archiveFolder) { " -Archive `"$archiveFolder`"" } else { "" }

$finalCommand = "powershell.exe -ExecutionPolicy Bypass -File `"$scriptPath`" -Path $pathsArg$archiveArg"

Write-Host ""
Write-Host "=== Generated Command ===" -ForegroundColor Cyan
Write-Host $finalCommand -ForegroundColor Green
Write-Host ""
Write-Host "Copy this command into Playnite!" -ForegroundColor Yellow
