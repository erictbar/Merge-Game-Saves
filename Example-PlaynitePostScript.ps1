# Example Playnite Post-Script for Black Lily CR
# This runs AFTER the game closes

# Step 1: Pull latest saves from Android device to local BlueStacks folder
Write-Host "[Playnite] Pulling saves from Android device..."
& powershell.exe -ExecutionPolicy Bypass -File "C:\Users\erict\OneDrive\Developer\Scripts\scripts\Save File\ADBtoOneDrive.ps1"

# Step 2: Sync between BlueStacks and Switch save folders
Write-Host "[Playnite] Syncing save files between platforms..."
& powershell.exe -ExecutionPolicy Bypass -File "C:\Users\erict\OneDrive\Developer\Scripts\Public\Merge Game Saves\MergeGames.ps1" -Path 'C:\Users\erict\OneDrive\Saves\Android\BlackLilyCR\BlueStacks A11','C:\Users\erict\OneDrive\Saves\Android\BlackLilyCR\SwitchAndroid' -Archive "\\192.168.50.49\usb1\Backup\Saves\Automation\BlackLily"

Write-Host "[Playnite] Save synchronization completed!"