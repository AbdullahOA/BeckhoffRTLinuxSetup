# Beckhoff RT Linux Setup (unofficial)

> **Unofficial tool by Abdullah Omar, Beckhoff UAE.**
> Not an official Beckhoff product. Not supported, tested or endorsed by Beckhoff Automation GmbH & Co. KG.
> Use at your own risk, only on controllers you are allowed to modify. See [DISCLAIMER.txt](DISCLAIMER.txt).

Provisions a factory-fresh **Beckhoff RT Linux** controller (e.g. CX9240) from a Windows laptop
with a single Ethernet cable and no extra network setup:

1. Finds the controller via IPv6 link-local neighbor discovery (`ping ff02::1%idx` + `Get-NetNeighbor 00-01-05*`).
2. Creates/installs an SSH key (Administrator password typed once).
3. Opens a reverse SOCKS proxy (`ssh -R 1080`) so the controller reaches `deb.beckhoff.com` **through the laptop's internet** - no Windows ICS, no second cable.
4. Writes `/etc/apt/auth.conf.d/bhf.conf` from your myBeckhoff login, optionally adds the Beckhoff **testing** feed, runs `apt update`.
5. Lets you **pick the packages** to install from a live list of the Beckhoff repository (defaults: `tc31-xar-um`, `tf2000-hmi-server`, `tf1200-ui-client`).
6. Optionally initializes TcHmiSrv, opens TCP 2020 in nftables and enables the service; optionally sets up the TF1200 UI Client for a chosen Linux user (autologin/autostart, start URL, kiosk mode).
7. Applies DHCP or a static IPv4 address **last** via systemd-networkd (`networkctl reload`).

Based on the Beckhoff RT Linux manual, the TF2000/TF1200 InfoSys pages and the CX9240 setup guide.

## Download

Customers: grab the latest release - **[BeckhoffRTLinuxSetup.zip](https://github.com/HurtsInTheMeow/BeckhoffRTLinuxSetup/releases/latest/download/BeckhoffRTLinuxSetup.zip)** - extract it and run `BeckhoffRTLinuxSetup.exe`. `README.txt` inside has the step-by-step instructions.

Requirements: Windows 10/11 with the built-in *OpenSSH Client* (the tool offers to enable it if missing),
internet on the laptop (Wi-Fi is fine), an Ethernet cable to the controller, a myBeckhoff account.

Windows SmartScreen may show *"Windows protected your PC"* the first time: *More info -> Run anyway* (the file is unsigned).

## Using it

| Section | What you do |
|---|---|
| 1. Controller | Pick adapter -> **Discover** -> enter Administrator password (default `1`) -> **Connect**. First time only: a console window asks for the password once to install the SSH key. |
| 2. Repository & packages | myBeckhoff e-mail/password (empty = reuse the login stored on the controller). **Fetch package list...** opens a searchable check-list of the Beckhoff product packages in the feed (kernel/library/rebuilt-Debian packages behind a "show all" toggle); without it the defaults are installed. Optional testing feed (not for production) and delete-bhf.conf-afterwards. |
| 3. HMI / UI Client | *Set up HMI server* (optional): `TcHmiSrv --initialize` with the admin password (`__SystemAdministrator` on port 2020), firewall rule, enable service. UI Client user (Linux user, created if missing), autologin+autostart, start URL (`startUrl` in `config.json`), kiosk mode. |
| 4. IP address | Keep DHCP or set static address/prefix (+ optional gateway, DNS). Applied at the end; the session survives because it runs over IPv6 link-local. |
| 5. Options | Reverse proxy port, `apt full-upgrade` first. |

**Run setup** streams the controller's output into the log pane. Re-running on the same controller is safe - finished steps are detected and skipped.

## Repository layout

| File | Purpose |
|---|---|
| `BeckhoffRTLinuxSetup.cmd` | Self-launching script variant (batch header + the GUI script in one file) - same tool as the exe, for environments where a `.cmd` is easier than an unsigned `.exe`. |
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
