# Example-PlaynitePostScript.ps1
# Example script showing how to use ADB scripts with Playnite
# Copy this command to your Playnite game's Post-Script field

# Wait for game/emulator to fully initialize, then push saves with retry logic
powershell.exe -ExecutionPolicy Bypass -File "C:\Users\erict\OneDrive\Developer\Scripts\Public\Merge Game Saves\WinToADB.ps1" -UseLatest -AutoConnect -InitialWait 15 -MaxRetries 5 -RetryDelay 3 -ShowDetails

# Alternative: Using ADBtoWin.ps1 directly
# powershell.exe -ExecutionPolicy Bypass -File "C:\Users\erict\OneDrive\Developer\Scripts\Public\Merge Game Saves\ADBtoWin.ps1" -Action Push -AutoConnect -InitialWait 15 -MaxRetries 5 -RetryDelay 3 -ShowDetails

# For Pull (download saves from Android before game starts), use in Pre-Script:
# powershell.exe -ExecutionPolicy Bypass -File "C:\Users\erict\OneDrive\Developer\Scripts\Public\Merge Game Saves\ADBtoWin.ps1" -Action Pull -AutoConnect -InitialWait 5 -MaxRetries 3 -ShowDetails
