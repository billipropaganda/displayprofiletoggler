# Display Profile Toggler

Double-click to flip a monitor between two resolution + refresh rate + DPI scaling profiles. Zero dependencies, Win32 only.

## Usage

### .exe (recommended)
```
# Open settings GUI
display-switcher.exe -OpenGui

# Toggle profile (after saving config)
display-switcher.exe
```

### .ps1 (or run directly)
```
powershell -File display-switcher.ps1 -OpenGui
powershell -File display-switcher.ps1
```

1. Run with `-OpenGui`
2. Pick your monitor, set **Profile A** and **Profile B** (resolution + scale)
3. Click **Save Config**
4. Double-click the exe to toggle anytime

## How it works

- Resolution/refresh set via `ChangeDisplaySettingsEx`
- DPI scaling set via `HKCU\Control Panel\Desktop\PerMonitorSettings` (no admin)
