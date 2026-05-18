# Mod Merger

Windows tool for merging Twilight Princess texture packs, converting PNG to DDS, downloading GameBanana mods, and installing mods to a GameCube ISO.

## Quick start

1. Download the latest **Release** zip or clone this repo.
2. Keep all files in one folder (do not move scripts away from images).
3. Double-click **`Start Mod Merger.vbs`** (no PowerShell window).
4. Edit **`gamebanana-mods.txt`** in the same folder (one `https://gamebanana.com/dl/...` URL per line).
5. Downloaded mod `.zip` files are saved in that same folder.

## Requirements

- Windows 10/11
- PowerShell 5.1+ (included with Windows)
- **texconv.exe** for PNG→DDS (place in `tools\texconv.exe` or configure in app)
- Optional: Python 3.12 + gclib for **Install to ISO**

## Main files

| File | Purpose |
|------|---------|
| `Start Mod Merger.vbs` | Launch the GUI |
| `Texturepack-Merge-GUI.ps1` | Main application |
| `Texturepack-Merge-Launcher.ps1` | Startup wrapper |
| `gamebanana-mods.txt` | GameBanana download links |
| `tools/InstallModToGcm.py` | ISO install helper |

## Portable layout

Copy the whole folder anywhere (USB, Desktop, another PC). The app folder is always where `Texturepack-Merge-GUI.ps1` lives:

- `gamebanana-mods.txt` — link list  
- Downloaded mods — same folder  

## License

Use and modify for personal modding. GameBanana mods are subject to their authors' terms.
