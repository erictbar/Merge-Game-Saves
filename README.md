# Merge Game Saves PowerShell Script

This script allows you to merge save files from multiple sources (such as different PCs or network locations) and archive them for backup or synchronization purposes. It is especially useful for synchronizing game saves between different devices or users.

## Requirements

This assumes you have multiple PCs that are on a local SMB network, with your passwords saved, i.e. in Windows Credentials Manager, to play the same game.
PowerShell Core is used, it is possible the PowerShell included on Windows will work but this has only been tested with PowerShell 7.5.x

Playnite's feature to input a Script to Excute before starting a game and after exiting is used to make sure this runs and syncs your games properly.

## Usage

### Command Example

```powershell
pwsh.exe -ExecutionPolicy Bypass -File "C:\Path\To\MergeGames.ps1" -Path "\\<IP1>\<Location of Save Data>","\\<IP2>\<Location of Save Data>" -Archive "C:\Path\To\Archive\Folder"
```

- Replace `<IP1>` and `<IP2>` with the IP addresses or hostnames of your source machines.
- Replace `<User1>` and `<User2>` with the Windows usernames on each machine.
- Replace the rest of the file path with the folder that contains all the saves for the game.
- The `-Archive` parameter specifies the folder where merged saves will be archived.

### Example

```powershell
pwsh.exe -ExecutionPolicy Bypass -File "C:\Scripts\MergeGames.ps1" -Path "\\192.168.1.10\c\Users\Alice\AppData\Roaming\suyu\nand\user\save\0000000000000000\GAMEID","\\192.168.1.11\c\Users\Bob\AppData\Roaming\suyu\nand\user\save\0000000000000000\GAMEID" -Archive "C:\Saves\Nintendo\Switch\GameName"
```

## Using with Playnite

You can configure Playnite to run this script automatically before and after launching a game to keep your saves synchronized.

### Steps:
1. Open Playnite and go to the game you want to synchronize saves for.
2. Edit the game and go to the **Scripts** tab.
3. Add the following command to the **Pre-Script** and/or **Post-Script** fields:

   ```powershell
   pwsh.exe -ExecutionPolicy Bypass -File "C:\Path\To\MergeGames.ps1" -Path "\\<IP1>\<Location of Save Data>","\\<IP2>\<Location of Save Data>" -Archive "C:\Path\To\Archive\Folder"
   ```

4. Adjust the paths and parameters as needed for your setup.

#### Example Playnite Script Settings

![Example Playnite Script Settings](example_playnite.png)

*Above: Playnite's script settings for a game, showing where to add the PowerShell command.*

## Parameters
- `-Path` (required): Comma-separated list of save directories to merge.
- `-Archive` (optional, recommended): Path to the folder where the merged save will be archived.

## ADB Scripts for Android Devices

This repository also includes scripts for transferring save files between Windows and Android devices via ADB:

### ADBtoWin.ps1
The main script that can both pull saves from Android to Windows and push saves from Windows to Android.

**Pull saves from Android (ADB to Win):**
```powershell
pwsh.exe -ExecutionPolicy Bypass -File "ADBtoWin.ps1" -Action Pull -AutoConnect -ShowDetails
```

**Push saves to Android (Win to ADB):**
```powershell
pwsh.exe -ExecutionPolicy Bypass -File "ADBtoWin.ps1" -Action Push -AutoConnect -ShowDetails
```

### WinToADB.ps1
A dedicated wrapper script for pushing saves from Windows to Android with additional convenience features:

```powershell
# Push latest timestamped folder automatically
pwsh.exe -ExecutionPolicy Bypass -File "WinToADB.ps1" -UseLatest -AutoConnect -ShowDetails

# Push specific folder
pwsh.exe -ExecutionPolicy Bypass -File "WinToADB.ps1" -LocalSource "C:\Saves\SpecificFolder" -AutoConnect

# Dry run to see what would be pushed
pwsh.exe -ExecutionPolicy Bypass -File "WinToADB.ps1" -UseLatest -DryRun -ShowDetails

# For Playnite: Wait 10 seconds after game start, then push with retries
pwsh.exe -ExecutionPolicy Bypass -File "WinToADB.ps1" -UseLatest -AutoConnect -InitialWait 10 -MaxRetries 5
```

#### Using with Playnite
When running from Playnite's Post-Script (after game starts), use timing parameters to handle ADB startup delays:

**Recommended Playnite Post-Script command:**
```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\Path\To\WinToADB.ps1" -Action Push -AutoConnect -InitialWait 15 -MaxRetries 5 -RetryDelay 3 -ShowDetails
```

This command:
- Waits 15 seconds for the game/emulator to fully start
- Automatically connects to ADB if needed
- Retries up to 5 times with 3-second delays
- Shows detailed logging for troubleshooting

### PushToADB.ps1
A simple alias script that demonstrates basic Win->ADB transfer using the existing ADBtoWin.ps1.

#### ADB Script Parameters
- `-Device`: ADB device address (default: 127.0.0.1:5555)
- `-AutoConnect`: Automatically attempt ADB connection
- `-RemotePath`: Target path on Android device
- `-LocalBase`: Base local folder containing saves
- `-LocalSource`: Explicit source folder to push
- `-UseLatest`: (WinToADB only) Automatically select latest timestamped subfolder
- `-InitialWait`: Seconds to wait before starting ADB operations (useful for Playnite)
- `-MaxRetries`: Number of times to retry ADB operations (default: 3)
- `-RetryDelay`: Seconds between retries (default: 5)
- `-ConnectTimeout`: Seconds to wait for device connection (default: 10)
- `-DryRun`: Show what would be done without making changes
- `-ShowDetails`: Show detailed logging


## Notes
- Ensure network paths are accessible and you have the necessary permissions.
- The script can be run manually or automated via Playnite or other launchers.
- For best results, run the script both before and after playing to synchronize the latest saves.
- Currently, archiving will create a new copy of your save file every time it runs. This can potentially use a lot of space
---