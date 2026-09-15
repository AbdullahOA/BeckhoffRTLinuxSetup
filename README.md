# Beckhoff RT Linux Setup (unofficial)

> **Unofficial tool by Abdullah Omar, Beckhoff UAE.**
> Not an official Beckhoff product. Not supported, tested or endorsed by Beckhoff Automation GmbH & Co. KG.
> Use at your own risk, only on controllers you are allowed to modify. See [DISCLAIMER.txt](DISCLAIMER.txt).

Provisions a factory-fresh **Beckhoff RT Linux** controller (e.g. CX9240) from a Windows laptop
with a single Ethernet cable and no extra network setup:

1. Finds the controller via IPv6 link-local neighbor discovery (`ping ff02::1%idx` + `Get-NetNeighbor 00-01-05*`).
2. Creates/installs an SSH key (Administrator password typed once).
3. Opens a reverse SOCKS proxy (`ssh -R 1080`) so the controller reaches `deb.beckhoff.com` **through the laptop's internet** - no Windows ICS, no second cable.
4. Writes `/etc/apt/auth.conf.d/bhf.conf` from your myBeckhoff login, runs `apt update`, installs
   `tc31-xar-um`, `tf2000-hmi-server`, `tf1200-ui-client`.
5. Initializes TcHmiSrv, opens TCP 2020 in nftables, enables the service, optionally sets up TF1200 autologin/autostart.
6. Applies DHCP or a static IPv4 address **last** via systemd-networkd (`networkctl reload`).

Based on the Beckhoff RT Linux manual v1.3 and the CX9240 setup guide (see InfoSys).

## For customers / users

Download **`BeckhoffRTLinuxSetup.cmd`** and double-click it. That's the whole package - it opens a setup window.

Requirements: Windows 10/11 with the built-in *OpenSSH Client* (the tool offers to enable it if missing),
internet on the laptop (Wi-Fi is fine), an Ethernet cable to the controller, a myBeckhoff account.

Steps in the window: pick adapter -> **Discover** -> enter Administrator password (factory default `1`) -> **Connect**
(the first time a console window asks for the same password once, to install the SSH key) -> fill in
myBeckhoff login, HMI password, DHCP/static -> **Run setup**. Keep the window open and the laptop online.

Windows SmartScreen may show *"Windows protected your PC"* the first time: *More info -> Run anyway* (the file is unsigned).

## Repository layout

| File | Purpose |
|---|---|
| `BeckhoffRTLinuxSetup.cmd` | **Customer package.** Self-launching: batch header + the GUI script in one file. |
| `BeckhoffRTLinuxSetup.ps1` | GUI source (WinForms). The `.cmd` is this file with a 13-line launcher on top. |
| `Setup-BeckhoffRTLinux.ps1` | Console/CLI version of the same workflow (`-Target`, `-InterfaceIndex`, `-ResetHostKey`, ...). |
| `Build-Release.bat` / `Build-Release.ps1` | Optional: compile to `.exe` (ps2exe) and build a Windows installer (Inno Setup). |
| `BeckhoffRTLinuxSetup.iss` | Inno Setup installer definition used by `Build-Release`. |
| `DISCLAIMER.txt` | Shown in the installer and at startup. |

## Building an exe / installer (optional)

```
Build-Release.bat
```
Produces `build\BeckhoffRTLinuxSetup.exe` and `dist\BeckhoffRTLinuxSetup-Setup-<version>.exe`.
Needs internet once (ps2exe module from the PowerShell Gallery, Inno Setup via winget).
Note: ps2exe embeds the script as text - it is packaging, not obfuscation. Nothing sensitive is in the script;
all credentials are typed at runtime and sent to the controller over the SSH pipe only.

## Updating the customer package

Edit `BeckhoffRTLinuxSetup.ps1`, bump `$ToolVersion`, then regenerate the `.cmd`:

```powershell
$hdr = (Get-Content BeckhoffRTLinuxSetup.cmd -Raw) -replace '(?s)#>.*$', "#>`r`n"
Set-Content BeckhoffRTLinuxSetup.cmd -Value ($hdr + (Get-Content BeckhoffRTLinuxSetup.ps1 -Raw)) -Encoding UTF8 -NoNewline
```

## Security notes

- Secrets (sudo password, myBeckhoff login, HMI password) are streamed to the controller over the SSH pipe, never passed as arguments or written to files on the PC.
- `bhf.conf` on the controller is created root-only (0600); tick *Delete bhf.conf when finished* to remove it.
- The temporary apt proxy config is removed automatically when the run ends.
- Change the Administrator password from the factory default after setup (`passwd`).

## License

MIT - see [LICENSE](LICENSE).
