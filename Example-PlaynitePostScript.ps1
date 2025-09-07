# Example Playnite Script for Black Lily CR
# This runs BEFORE the game launches
powershell.exe -ExecutionPolicy Bypass -File "C:\Users\erict\OneDrive\Developer\Scripts\Public\Merge Game Saves\MergeGames.ps1" -Path 'C:\Users\erict\OneDrive\Saves\Android\BlackLilyCR\BlueStacks A11','C:\Users\erict\OneDrive\Saves\Android\BlackLilyCR\SwitchAndroid' -Archive "\\192.168.50.49\usb1\Backup\Saves\Automation\BlackLily"

# This runs WHILE the game is running
powershell.exe -ExecutionPolicy Bypass -File "C:\Users\erict\OneDrive\Developer\Scripts\Public\Merge Game Saves\WinToADB.ps1" -UseLatest -AutoConnect -InitialWait 15 -MaxRetries 5 -RetryDelay 3 -ShowDetails -RemotePath '/sdcard/Android/data/com.crunchyroll.gv.blacklilystale.game/files'
# This runs AFTER the game closes
powershell.exe -ExecutionPolicy Bypass -File "C:\Users\erict\OneDrive\Developer\Scripts\scripts\Save File\ADBtoOneDrive.ps1"
powershell.exe -ExecutionPolicy Bypass -File "C:\Users\erict\OneDrive\Developer\Scripts\Public\Merge Game Saves\MergeGames.ps1" -Path 'C:\Users\erict\OneDrive\Saves\Android\BlackLilyCR\BlueStacks A11','C:\Users\erict\OneDrive\Saves\Android\BlackLilyCR\SwitchAndroid' -Archive "\\192.168.50.49\usb1\Backup\Saves\Automation\BlackLily"