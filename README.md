# ROG Ally X Software Restore (no reset)

A PowerShell script that reinstalls the ASUS/ROG software stack on the **ROG Ally X (RC72LA)**,
covering the drivers, services and apps that ASUS Cloud Recovery would put back, **without
resetting Windows and without deleting anything**.

> Unofficial community tool. Not affiliated with or endorsed by ASUS. Use at your own risk.

## Why

Cloud Recovery fixes a broken Armoury Crate SE or missing drivers, but it wipes the device.
This script gets the same software back while your games, files and settings stay where they are.

## What it does

The script pulls the live RC72LA download catalog from ASUS's own support API
(`rog.asus.com` → `dlcdnets.asus.com`). This is the same catalog the ASUS support page and MyASUS
use. For each item the script:

- downloads the newest version and **checks its digital signature** before running it
- uses the **silent install switches ASUS publishes** for that package
- installs only drivers whose **hardware is actually in your unit**. Ally X units ship with
  different G-sensors, card readers and fingerprint readers, and the script picks the right one.

Order of operations:

1. Admin check, restore point, and a snapshot of current services, apps and drivers for rollback
2. `DISM /RestoreHealth` and `sfc /scannow` (repair only, no component cleanup)
3. Stop hung Armoury Crate processes
4. AMD Chipset → AMD Graphics → ASUS System Control Interface v3 → Armoury Crate Control Interface
5. Device drivers: Wi-Fi, Bluetooth, Realtek audio, TI speaker amp, G-sensor, card reader,
   joystick, Raikiri Pro controller, fingerprint
6. Dolby Atmos
7. Microsoft Store apps via winget: MyASUS, GlideX, Realtek Audio Console
8. **Armoury Crate SE**. Its installer has no silent mode, so tap **Install** when it appears.
   The script waits up to 45 minutes for you.
9. Pending Windows Update drivers (firmware skipped unless `-IncludeFirmware`)
10. Re-bind ASUS/AMD drivers, re-register ASUS/AMD/Realtek/Dolby apps
11. Set the core ASUS/ROG services to Automatic and start them (on-demand updaters are left alone)
12. Summary listing any device still in an error state and anything that failed

**Skipped on purpose:** "MyASUS in WinRE for USB" (that is the Cloud Recovery reset tool) and
the MCU/BIOS firmware, unless you pass `-IncludeFirmware`.

## How to run

1. Download `Restore-RogAllyX.ps1` to the Ally X (e.g. into `Downloads`).
2. **Plug the Ally into power.** The AMD graphics driver is large.
3. Press **Win + X** and choose **Terminal (Admin)**. Accept the UAC prompt.
4. Run:

```powershell
cd $env:USERPROFILE\Downloads
Unblock-File .\Restore-RogAllyX.ps1

# Preview what would be installed (changes nothing)
powershell.exe -ExecutionPolicy Bypass -File .\Restore-RogAllyX.ps1 -ListOnly

# Run it
powershell.exe -ExecutionPolicy Bypass -File .\Restore-RogAllyX.ps1
```

5. Restart when it finishes, then open **Armoury Crate SE → Update Center**.

### Options

| Switch | Effect |
|---|---|
| `-ListOnly` | Show the install plan only, change nothing |
| `-IncludeFirmware` | Also apply MCU firmware and firmware from Windows Update |
| `-SkipHealthCheck` | Skip DISM/SFC |
| `-SkipWindowsUpdate` | Skip the Windows Update driver pass |
| `-SkipStore` | Skip MyASUS / GlideX / Realtek Audio Console |
| `-PackageDir <folder>` | Also apply extra `.inf/.appx/.msix/.exe/.msi` files you supply |
| `-Model <code>` | Use another model's catalog (untested; default `RC72LA`) |

## Logs and rollback

Each run writes to `C:\ProgramData\RogAllyRestore\<timestamp>\`:
`transcript.log`, `services-before.csv`, `services-after.csv`, `appx-before.csv`,
`drivers-before.txt`, `problem-devices-before.csv`. Downloads are cached in
`C:\ProgramData\RogAllyRestore\Downloads\` and reused on re-runs.
A System Restore point is created before any change.

## Warnings in the log that are normal

- `0x80073D02` ("in use"): the app was open. It is already registered.
- `0x80073D06` ("higher version installed"): an older copy in `C:\eSupport` was skipped.
- `Failed to start service 'ASUS Update Service (asus/asusm)'` or `AsusROGLSLService`: these are
  on-demand updaters that start and stop by themselves.

## Tested on

ROG Ally X RC72LA, BIOS 312, Windows 11 build 26300. One unit, so please open an issue with
your `transcript.log` if something behaves differently on yours.

## License

MIT. See [LICENSE](LICENSE). ASUS, ROG, Armoury Crate and related names are trademarks of
ASUSTeK Computer Inc. All installers are downloaded directly from ASUS servers at run time.
None are redistributed here.
