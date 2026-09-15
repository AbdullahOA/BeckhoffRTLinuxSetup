#Requires -Version 5.1
<#
.SYNOPSIS
    Provisions a factory-fresh Beckhoff RT Linux controller (e.g. CX9240) from a Windows PC.

.DESCRIPTION
    Runs on the Windows engineering PC that is cabled directly to the controller. It:

      1. Finds the controller on the chosen Ethernet adapter via IPv6 link-local neighbor
         discovery (ping ff02::1%<idx>  ->  Get-NetNeighbor -LinkLayerAddress 00-01-05*).
      2. Generates an ed25519 SSH key pair if you don't have one and installs the public key
         in ~/.ssh/authorized_keys on the controller (you type the Administrator password
         once; factory default is "1").
      3. Asks whether to keep DHCP or set a static IPv4 address (address/prefix, optional
         gateway + DNS) on the controller's interface.
      4. Pushes an embedded bash script to the controller and runs it over
         "ssh -t -R <port> ..." so the controller reaches deb.beckhoff.com through a
         reverse SOCKS proxy on this PC (no Windows ICS / second cable needed).
         On the controller the script:
           - syncs the clock (TLS breaks if the RTC is wrong)
           - configures apt to use socks5h://127.0.0.1:<port> (temporary)
           - asks for your myBeckhoff e-mail/password and writes /etc/apt/auth.conf.d/bhf.conf (0600)
           - apt update; installs tc31-xar-um, tf2000-hmi-server, tf1200-ui-client
           - initializes TcHmiSrv (asks for the HMI admin password), opens TCP 2020 in nftables,
             enables + starts TcHmiSrv; optionally runs the TF1200 autologin/autostart setup
           - applies the DHCP/static network choice LAST via systemd-networkd (networkctl reload)
             - the SSH session survives because it runs over the IPv6 link-local address
           - removes the temporary apt proxy config and itself

    Sources: Beckhoff RT Linux manual v1.3 (ch. 3.2, 3.3, 5.1-5.4, 6.2, 6.3, 7.3),
             Beckhoff Linux Setup Guide v3.1 (phases 3, 6, 10-17).

.PARAMETER Target
    Skip discovery and use this host, e.g. "fe80::201:5ff:fea3:c9fa%13" or "192.168.1.100".
.PARAMETER InterfaceIndex
    Windows adapter index (the number after % in ipconfig). Prompted if omitted.
.PARAMETER User
    Linux login. Default: Administrator.
.PARAMETER ProxyPort
    Port for the reverse SOCKS proxy on the controller. Default: 1080.
.PARAMETER ResetHostKey
    Remove the stored SSH host key for the target first (use after re-imaging the controller).
.PARAMETER UiAutostart
    Run the TF1200 setup-full.sh with --autologin --autostart for the Administrator user.
.PARAMETER FullUpgrade
    Also run "apt full-upgrade -y" after apt update.
.PARAMETER DeleteCredentials
    Delete /etc/apt/auth.conf.d/bhf.conf when the installation is finished.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Setup-BeckhoffRTLinux.ps1
.EXAMPLE
    .\Setup-BeckhoffRTLinux.ps1 -InterfaceIndex 13 -UiAutostart
.EXAMPLE
    .\Setup-BeckhoffRTLinux.ps1 -Target 192.168.1.100 -ResetHostKey
#>
[CmdletBinding()]
param(
    [string]$Target,
    [int]$InterfaceIndex,
    [string]$User = 'Administrator',
    [ValidateRange(1024, 65535)][int]$ProxyPort = 1080,
    [switch]$ResetHostKey,
    [switch]$UiAutostart,
    [switch]$FullUpgrade,
    [switch]$DeleteCredentials
)

# 'Continue' on purpose: ssh/ssh-keygen write progress to stderr, which 'Stop' would turn into
# terminating errors in Windows PowerShell 5.1. Every native call checks $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'

# ----------------------------------------------------------------------------- helpers
function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "    $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text){ Write-Host "    $Text" -ForegroundColor Yellow }
function Fail([string]$Text)       { Write-Host "`nERROR: $Text" -ForegroundColor Red; exit 1 }

function Read-Choice([string]$Prompt, [string[]]$Options, [int]$Default = 0) {
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $mark = if ($i -eq $Default) { '*' } else { ' ' }
        Write-Host ("  [{0}]{1} {2}" -f ($i + 1), $mark, $Options[$i])
    }
    while ($true) {
        $raw = Read-Host "$Prompt [1-$($Options.Count)] (Enter = $($Default + 1))"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        if ($raw -match '^\d+$' -and [int]$raw -ge 1 -and [int]$raw -le $Options.Count) { return ([int]$raw - 1) }
        Write-Warn2 "Please enter a number between 1 and $($Options.Count)."
    }
}

function Test-IPv4([string]$s) {
    $ip = $null
    return ([System.Net.IPAddress]::TryParse($s, [ref]$ip) -and $ip.AddressFamily -eq 'InterNetwork')
}

function Read-IPv4Cidr([string]$Prompt, [string]$Default) {
    while ($true) {
        $raw = Read-Host "$Prompt (Enter = $Default)"
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $Default }
        if ($raw -match '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$' -and (Test-IPv4 $Matches[1]) -and [int]$Matches[2] -ge 1 -and [int]$Matches[2] -le 30) {
            return $raw
        }
        Write-Warn2 "Use the form A.B.C.D/prefix, e.g. 192.168.1.100/24"
    }
}

function Read-IPv4Optional([string]$Prompt) {
    while ($true) {
        $raw = Read-Host "$Prompt (Enter = none)"
        if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
        if (Test-IPv4 $raw) { return $raw }
        Write-Warn2 "Not a valid IPv4 address."
    }
}

# Native command wrapper: PowerShell 5.1 and 7 differ in how they pass "" arguments,
# so passphrase-less keygen needs a version-specific form.
function New-SshKey([string]$Path) {
    $comment = "beckhoff-setup@$env:COMPUTERNAME"
    if ($PSVersionTable.PSVersion -ge [version]'7.3') {
        & ssh-keygen -q -t ed25519 -f $Path -N "" -C $comment
    } else {
        & ssh-keygen -q -t ed25519 -f $Path -N '""' -C $comment
    }
    if ($LASTEXITCODE -ne 0) { Fail "ssh-keygen failed." }
}

# ----------------------------------------------------------------------------- preflight
Write-Step "Preflight"
foreach ($tool in 'ssh', 'ssh-keygen') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Fail "'$tool' not found. Install 'OpenSSH Client' (Settings > Apps > Optional features)."
    }
}
Write-Ok "OpenSSH client: $((Get-Command ssh).Source)"

# ----------------------------------------------------------------------------- 1. discovery
$deviceMac = $null
if ([string]::IsNullOrWhiteSpace($Target)) {
    Write-Step "Select the Ethernet adapter connected to the controller"
    if (-not $InterfaceIndex) {
        $adapters = @(Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' } | Sort-Object ifIndex)
        if ($adapters.Count -eq 0) { Fail "No Ethernet adapter is Up. Plug the cable into the controller and retry." }
        if ($adapters.Count -eq 1) {
            $InterfaceIndex = $adapters[0].ifIndex
            Write-Ok "Using '$($adapters[0].Name)' (ifIndex $InterfaceIndex)"
        } else {
            $labels = $adapters | ForEach-Object { "{0}  (ifIndex {1}, {2})" -f $_.Name, $_.ifIndex, $_.LinkSpeed }
            $InterfaceIndex = $adapters[(Read-Choice 'Adapter' $labels)].ifIndex
        }
    }

    Write-Step "Discovering Beckhoff devices on interface %$InterfaceIndex (IPv6 link-local)"
    # All-nodes multicast ping forces every IPv6 host on the link into the neighbor cache.
    # A timeout here is normal; what matters is the neighbor table afterwards.
    & ping -n 2 -w 1000 "ff02::1%$InterfaceIndex" | Out-Null
    Start-Sleep -Seconds 1

    $neighbors = @(Get-NetNeighbor -AddressFamily IPv6 -InterfaceIndex $InterfaceIndex -LinkLayerAddress '00-01-05*' -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like 'fe80:*' -and $_.State -ne 'Unreachable' } |
        Sort-Object IPAddress -Unique)

    if ($neighbors.Count -eq 0) {
        # second attempt with a longer ping - some links need a moment after link-up
        & ping -n 4 -w 1500 "ff02::1%$InterfaceIndex" | Out-Null
        Start-Sleep -Seconds 2
        $neighbors = @(Get-NetNeighbor -AddressFamily IPv6 -InterfaceIndex $InterfaceIndex -LinkLayerAddress '00-01-05*' -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -like 'fe80:*' -and $_.State -ne 'Unreachable' } |
            Sort-Object IPAddress -Unique)
    }
    if ($neighbors.Count -eq 0) {
        Fail "No device with a Beckhoff MAC (00-01-05-*) answered on ifIndex $InterfaceIndex. Check the cable / adapter, or pass -Target manually."
    }

    $pick = 0
    if ($neighbors.Count -gt 1) {
        Write-Warn2 "Several Beckhoff devices found - match the MAC with the name plate:"
        $labels = $neighbors | ForEach-Object { "{0}   MAC {1}   ({2})" -f $_.IPAddress, $_.LinkLayerAddress, $_.State }
        $pick = Read-Choice 'Device' $labels
    }
    $deviceMac = $neighbors[$pick].LinkLayerAddress
    $bare = ($neighbors[$pick].IPAddress -split '%')[0]
    $Target = "$bare%$InterfaceIndex"
    Write-Ok "Controller: $Target   MAC $deviceMac"
} else {
    Write-Ok "Using target from command line: $Target"
}

$sshHost = "$User@$Target"
$sshOpts = @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=8', '-o', 'ServerAliveInterval=15')

if ($ResetHostKey) {
    Write-Step "Removing stored host key for $Target"
    & ssh-keygen -R $Target 2>&1 | Out-Null
}

# ----------------------------------------------------------------------------- 2. SSH keys
Write-Step "SSH key setup"
$sshDir  = Join-Path $env:USERPROFILE '.ssh'
$keyPath = Join-Path $sshDir 'id_ed25519'
if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
if (-not (Test-Path $keyPath)) {
    Write-Ok "No key found - generating $keyPath (ed25519, no passphrase)"
    New-SshKey $keyPath
} else {
    Write-Ok "Using existing key $keyPath"
}
$pubKey = (Get-Content "$keyPath.pub" -Raw -ErrorAction SilentlyContinue)
if (-not $pubKey) { Fail "Public key $keyPath.pub not found." }
$pubKey = $pubKey.Trim()

# Probe key login. A re-imaged / swapped controller presents a new host key while known_hosts
# still holds the old one - OpenSSH then refuses to connect at all, so handle that here.
function Test-KeyLogin {
    $out = (& ssh @sshOpts -o BatchMode=yes -i $keyPath $sshHost 'true' 2>&1) | Out-String
    if ($LASTEXITCODE -eq 0) { return $true }
    if ($out -match 'HOST IDENTIFICATION HAS CHANGED') {
        Write-Warn2 "known_hosts holds an OLD host key for $Target (controller re-imaged or replaced?)."
        Write-Warn2 "If you did not expect that, stop here - it can also mean a man-in-the-middle."
        $ans = Read-Host "    Remove the stale entry and trust the controller's current key? [Y/n]"
        if ($ans -match '^[nN]') { Fail "Aborted. Fix known_hosts by hand or re-run with -ResetHostKey." }
        & ssh-keygen -R $Target 2>&1 | Out-Null
        & ssh @sshOpts -o BatchMode=yes -i $keyPath $sshHost 'true' 2>$null
        return ($LASTEXITCODE -eq 0)
    }
    return $false
}

if (-not (Test-KeyLogin)) {
    Write-Warn2 "Key not yet authorized on the controller. You will be asked for the $User password"
    Write-Warn2 "(factory default is '1'). Type 'yes' if asked to trust the host key."
    $installKeyCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && " +
                     "(grep -qxF '$pubKey' ~/.ssh/authorized_keys || echo '$pubKey' >> ~/.ssh/authorized_keys) && echo KEY_INSTALLED"
    & ssh @sshOpts -o PubkeyAuthentication=no $sshHost $installKeyCmd
    if ($LASTEXITCODE -ne 0) { Fail "Could not install the public key. Wrong password, host unreachable, or host key problem (see above)." }

    & ssh @sshOpts -o BatchMode=yes -i $keyPath $sshHost 'true' 2>$null
    if ($LASTEXITCODE -ne 0) { Fail "Public key installed but key login still fails. Check ~/.ssh permissions on the controller." }
}
Write-Ok "Key-based login works."

# ----------------------------------------------------------------------------- 3. network choice
Write-Step "Reading the controller's network interfaces"
$ifaceDump = & ssh @sshOpts -o BatchMode=yes -i $keyPath $sshHost 'hostname; echo ---; ip -br link | grep -v ^lo; echo ---; ip -br -4 addr; echo ---; ls /etc/systemd/network/ 2>/dev/null'
if ($LASTEXITCODE -ne 0) { Fail "Could not query interfaces." }
$sections   = ($ifaceDump -join "`n") -split "`n---`n"
$remoteHost = $sections[0].Trim()
$linkLines  = @($sections[1] -split "`n" | Where-Object { $_ -match '\S' })
$addrLines  = @($sections[2] -split "`n" | Where-Object { $_ -match '\S' })
$netFiles   = @($sections[3] -split "`n" | Where-Object { $_ -match '\S' })

Write-Ok "Hostname: $remoteHost"
Write-Host "    Links:";       $linkLines | ForEach-Object { Write-Host "      $_" }
Write-Host "    IPv4 today:";  $addrLines | ForEach-Object { Write-Host "      $_" }
if ($netFiles.Count) { Write-Host "    /etc/systemd/network:"; $netFiles | ForEach-Object { Write-Host "      $_" } }

# Interface names as seen on the controller (end0, end1, eno1, ...)
$remoteIfaces = @($linkLines | ForEach-Object { ($_ -split '\s+')[0] })
# The interface we are physically talking to has the MAC we discovered
$connectedIface = $null
if ($deviceMac) {
    $macLinux = $deviceMac.ToLower().Replace('-', ':')
    $hit = $linkLines | Where-Object { $_ -match [regex]::Escape($macLinux) } | Select-Object -First 1
    if ($hit) { $connectedIface = ($hit -split '\s+')[0] }
}
if (-not $connectedIface) { $connectedIface = $remoteIfaces | Select-Object -First 1 }

Write-Step "IP configuration for the controller"
$netMode = Read-Choice 'Address mode' @("Keep DHCP / auto (link-local) - factory default", "Set a static IPv4 address") 0

$netArgs = @('--dhcp')
if ($netMode -eq 1) {
    $ifaceIdx = [Math]::Max(0, [Array]::IndexOf($remoteIfaces, $connectedIface))
    $netIface = $remoteIfaces[(Read-Choice "Interface to configure (you are connected on '$connectedIface')" $remoteIfaces $ifaceIdx)]
    $netAddr  = Read-IPv4Cidr "Static address with prefix" '192.168.1.100/24'
    $netGw    = Read-IPv4Optional "Default gateway"
    $netDns   = ''
    if ($netGw) { $netDns = Read-IPv4Optional "DNS server" }
    $netArgs  = @('--static', $netAddr, '--iface', $netIface)
    if ($netGw)  { $netArgs += @('--gateway', $netGw) }
    if ($netDns) { $netArgs += @('--dns', $netDns) }
    Write-Ok "Will write /etc/systemd/network/10-$netIface-static.network -> $netAddr"
} else {
    $netArgs += @('--iface', $connectedIface)
    Write-Ok "Keeping DHCP on $connectedIface (any earlier static file for it will be removed)."
}

# ----------------------------------------------------------------------------- 4. remote script
# Single-quoted here-string: nothing is expanded by PowerShell, bash sees it verbatim.
$remoteScript = @'
#!/usr/bin/env bash
# bhf-setup.sh - runs as root on a Beckhoff RT Linux controller, pushed by Setup-BeckhoffRTLinux.ps1
set -euo pipefail

PROXY_PORT=1080; NET_MODE=dhcp; NET_IFACE=end0; NET_ADDR=""; NET_GW=""; NET_DNS=""
SET_TIME=""; UI_AUTOSTART=0; FULL_UPGRADE=0; DELETE_CREDS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --proxy-port)   PROXY_PORT=$2; shift 2 ;;
    --dhcp)         NET_MODE=dhcp; shift ;;
    --static)       NET_MODE=static; NET_ADDR=$2; shift 2 ;;
    --iface)        NET_IFACE=$2; shift 2 ;;
    --gateway)      NET_GW=$2; shift 2 ;;
    --dns)          NET_DNS=$2; shift 2 ;;
    --set-time)     SET_TIME=$2; shift 2 ;;
    --ui-autostart) UI_AUTOSTART=1; shift ;;
    --full-upgrade) FULL_UPGRADE=1; shift ;;
    --delete-creds) DELETE_CREDS=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

C='\033[1;36m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
step() { printf "\n${C}==> %s${N}\n" "$*"; }
ok()   { printf "${G}    %s${N}\n" "$*"; }
warn() { printf "${Y}    %s${N}\n" "$*"; }
die()  { printf "${R}ERROR: %s${N}\n" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo"
APT_PROXY_CONF=/etc/apt/apt.conf.d/99-bhf-setup-proxy
AUTH_CONF=/etc/apt/auth.conf.d/bhf.conf
HMI_MARK=/etc/TwinCAT/.bhf-setup-hmi-initialized
cleanup() { rm -f "$APT_PROXY_CONF" "$HOME_DIR/bhf-setup.sh" 2>/dev/null || true; }
HOME_DIR=$(getent passwd "${SUDO_USER:-Administrator}" | cut -d: -f6)
trap cleanup EXIT
export DEBIAN_FRONTEND=noninteractive

# ---- clock -------------------------------------------------------------------
step "System clock"
if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
  ok "already NTP-synchronized: $(date -u)"
elif [[ -n "$SET_TIME" ]]; then
  date -u -s "$SET_TIME" >/dev/null && ok "set from PC: $(date -u)"
fi

# ---- reverse SOCKS proxy from the engineering PC ------------------------------
step "Reverse SOCKS proxy (127.0.0.1:$PROXY_PORT -> engineering PC)"
ss -ltn 2>/dev/null | grep -q "127.0.0.1:$PROXY_PORT " || warn "nothing is listening on port $PROXY_PORT - was this started with 'ssh -R $PROXY_PORT'?"
if command -v curl >/dev/null; then
  if curl -s --max-time 15 --proxy "socks5h://127.0.0.1:$PROXY_PORT" -o /dev/null -w '%{http_code}' https://deb.beckhoff.com/ | grep -qE '^[1-5][0-9]{2}$'; then
    ok "deb.beckhoff.com reachable through the tunnel"
  else
    die "cannot reach deb.beckhoff.com through the tunnel (is the PC online? is port $PROXY_PORT free on the controller?)"
  fi
else
  warn "curl not present - skipping tunnel test, apt will tell us"
fi
cat > "$APT_PROXY_CONF" <<EOF
// temporary - written by bhf-setup.sh, removed on exit
Acquire::http::Proxy  "socks5h://127.0.0.1:$PROXY_PORT";
Acquire::https::Proxy "socks5h://127.0.0.1:$PROXY_PORT";
EOF

# ---- myBeckhoff credentials ---------------------------------------------------
step "myBeckhoff credentials for deb.beckhoff.com"
write_creds() {
  local mail pw
  while true; do
    read -rp "    myBeckhoff e-mail: " mail
    [[ -n "$mail" ]] && break
  done
  while true; do
    read -rsp "    myBeckhoff password: " pw; echo
    [[ -n "$pw" ]] || { warn "empty"; continue; }
    [[ "$pw" =~ [[:space:]] ]] && { warn "apt's netrc format cannot hold spaces - change the password on myBeckhoff first"; continue; }
    break
  done
  install -m 600 -o root -g root /dev/null "$AUTH_CONF"
  printf 'machine deb.beckhoff.com\nlogin %s\npassword %s\n\nmachine deb-mirror.beckhoff.com\nlogin %s\npassword %s\n' \
    "$mail" "$pw" "$mail" "$pw" > "$AUTH_CONF"
  ok "wrote $AUTH_CONF (root, 0600)"
}
if [[ -f "$AUTH_CONF" ]]; then
  read -rp "    $AUTH_CONF exists (login: $(awk '/^login/{print $2; exit}' "$AUTH_CONF")). Keep it? [Y/n] " keep
  [[ "${keep,,}" == n* ]] && write_creds
else
  write_creds
fi

# ---- apt update (retry on 401) ---------------------------------------------------
step "apt update"
for attempt in 1 2 3; do
  if apt-get update 2>&1 | tee /tmp/bhf-apt-update.log | grep -Ev '^(Get|Hit|Ign):'; then :; fi
  if grep -qE '401|Unauthorized' /tmp/bhf-apt-update.log; then
    warn "401 Unauthorized from deb.beckhoff.com - wrong myBeckhoff credentials (attempt $attempt/3)"
    [[ $attempt -lt 3 ]] && write_creds || die "authentication failed three times"
  elif grep -qE '^(E|Err):' /tmp/bhf-apt-update.log; then
    die "apt update failed - see above"
  else
    ok "package lists updated"; break
  fi
done
[[ $FULL_UPGRADE -eq 1 ]] && { step "apt full-upgrade"; apt-get full-upgrade -y; }

# ---- packages ----------------------------------------------------------------
step "TwinCAT packages"
for pkg in tc31-xar-um tf2000-hmi-server tf1200-ui-client; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    ok "$pkg already installed ($(dpkg-query -W -f='${Version}' "$pkg"))"
  else
    printf "    installing %s ...\n" "$pkg"
    apt-get install -y "$pkg"
    ok "$pkg installed ($(dpkg-query -W -f='${Version}' "$pkg"))"
  fi
done
systemctl is-active --quiet TcSystemServiceUm && ok "TcSystemServiceUm is running" || warn "TcSystemServiceUm not active - check: systemctl status TcSystemServiceUm"

# ---- TF2000 HMI server: initialize, firewall, enable -----------------------------
step "TwinCAT HMI Server (TcHmiSrv)"
if [[ -f "$HMI_MARK" ]] || systemctl is-active --quiet TcHmiSrv.service; then
  ok "TcHmiSrv already initialized - skipping --initialize"
else
  while true; do
    read -rsp "    New HMI admin password (for http://<ip>:2020): " HMI_PW; echo
    read -rsp "    Repeat: " HMI_PW2; echo
    [[ -n "$HMI_PW" && "$HMI_PW" == "$HMI_PW2" ]] && break
    warn "empty or mismatch - try again"
  done
  TcHmiSrv --initialize --password="$HMI_PW"
  unset HMI_PW HMI_PW2
  touch "$HMI_MARK"
  ok "TcHmiSrv initialized"
fi
if [[ ! -f /etc/nftables.conf.d/20-hmi.conf ]]; then
  cat > /etc/nftables.conf.d/20-hmi.conf <<'EOF'
table inet filter {
  chain input {
    # accept TcHmi (TF2000) - written by bhf-setup.sh
    tcp dport 2020 accept
  }
}
EOF
  systemctl reload nftables
  ok "firewall: TCP 2020 opened (/etc/nftables.conf.d/20-hmi.conf)"
else
  ok "firewall rule for 2020 already present"
fi
systemctl enable --now TcHmiSrv.service >/dev/null 2>&1 && ok "TcHmiSrv enabled and started" || warn "TcHmiSrv did not start - check: journalctl -u TcHmiSrv"

# ---- TF1200 UI client ---------------------------------------------------------
if [[ $UI_AUTOSTART -eq 1 ]]; then
  step "TF1200 UI Client - autologin + autostart for Administrator"
  SETUP=/etc/TwinCAT/Functions/TF1200-UI-Client/scripts/setup-full.sh
  if [[ -x "$SETUP" ]]; then
    "$SETUP" --user=Administrator --autologin --autostart
    ok "config: /home/Administrator/.config/TF1200-UI-Client/config.json"
  else
    warn "$SETUP not found - run the TF1200 setup manually"
  fi
fi

# ---- credentials retention -----------------------------------------------------
if [[ $DELETE_CREDS -eq 1 ]]; then rm -f "$AUTH_CONF"; ok "$AUTH_CONF deleted (re-create it before the next apt install)"; fi

# ---- network - done LAST so nothing above can lose the session --------------------
step "Network: $NET_MODE on $NET_IFACE"
NET_FILE="/etc/systemd/network/10-${NET_IFACE}-static.network"
if [[ "$NET_MODE" == "static" ]]; then
  {
    echo "[Match]"; echo "Name=$NET_IFACE"; echo
    echo "[Network]"; echo "Address=$NET_ADDR"
    [[ -n "$NET_GW" ]]  && echo "Gateway=$NET_GW"
    [[ -n "$NET_DNS" ]] && echo "DNS=$NET_DNS"
    echo "LinkLocalAddressing=ipv6"
  } > "$NET_FILE"
  chmod 644 "$NET_FILE"
  networkctl reload
  ok "wrote $NET_FILE and reloaded systemd-networkd"
else
  if [[ -f "$NET_FILE" ]]; then rm -f "$NET_FILE"; networkctl reload; ok "removed $NET_FILE - back to DHCP (20-wired.network)"; else ok "no static file present - DHCP stays"; fi
fi
sleep 2
ip -br -4 addr | grep -v '^lo' | sed 's/^/      /'

# ---- summary ------------------------------------------------------------------
step "Done"
IPV4=$(ip -4 -o addr show dev "$NET_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
[[ -n "$IPV4" ]] && ok "SSH:  ssh Administrator@$IPV4" 
[[ -n "$IPV4" ]] && ok "HMI:  http://$IPV4:2020"
ok "the IPv6 link-local address still works as a fallback"
warn "if the Administrator password is still the factory default '1', change it now: passwd"
'@

$remoteScript = $remoteScript -replace "`r`n", "`n"

# ----------------------------------------------------------------------------- 5. push + run
Write-Step "Pushing the provisioning script to $remoteHost"
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScript))
# Base64 in chunks keeps every ssh command line comfortably under the Windows 32 K limit.
$chunkSize = 6000
$first = $true
for ($i = 0; $i -lt $b64.Length; $i += $chunkSize) {
    $chunk = $b64.Substring($i, [Math]::Min($chunkSize, $b64.Length - $i))
    $redir = if ($first) { '>' } else { '>>' }
    & ssh @sshOpts -o BatchMode=yes -i $keyPath $sshHost "printf %s '$chunk' $redir ~/bhf-setup.b64"
    if ($LASTEXITCODE -ne 0) { Fail "Failed to push the script." }
    $first = $false
}
& ssh @sshOpts -o BatchMode=yes -i $keyPath $sshHost 'base64 -d ~/bhf-setup.b64 > ~/bhf-setup.sh && rm -f ~/bhf-setup.b64 && chmod 700 ~/bhf-setup.sh && bash -n ~/bhf-setup.sh && echo SCRIPT_OK'
if ($LASTEXITCODE -ne 0) { Fail "Script did not decode/parse on the controller." }
Write-Ok "Script staged as ~/bhf-setup.sh"

$utcNow = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
$remoteArgs = @('--proxy-port', $ProxyPort, '--set-time', "'$utcNow'") + $netArgs
if ($UiAutostart)       { $remoteArgs += '--ui-autostart' }
if ($FullUpgrade)       { $remoteArgs += '--full-upgrade' }
if ($DeleteCredentials) { $remoteArgs += '--delete-creds' }
$remoteCmd = "sudo bash ~/bhf-setup.sh $($remoteArgs -join ' ')"

Write-Step "Running the setup over ssh -t -R $ProxyPort $sshHost"
Write-Warn2 "The controller will fetch packages through THIS PC. Keep this window open and the PC online."
Write-Warn2 "sudo will ask for the $User password on the controller; the script then asks for your myBeckhoff login."
Write-Host ""
& ssh @sshOpts -t -i $keyPath -R $ProxyPort $sshHost $remoteCmd
$rc = $LASTEXITCODE
Write-Host ""
if ($rc -eq 0) {
    Write-Ok "Provisioning finished."
    if ($netMode -eq 1) {
        $newIp = ($netAddr -split '/')[0]
        Write-Ok "Static address applied: $newIp on $netIface"
        Write-Ok "Set this PC's adapter to the same subnet (e.g. $($newIp -replace '\.\d+$', '.10')) and use: ssh $User@$newIp"
        Write-Ok "HMI: http://${newIp}:2020"
    }
    Write-Ok "Fallback address: ssh $sshHost"
} else {
    Fail "Remote setup exited with code $rc - scroll up for the failing step. Re-running the script is safe (steps are idempotent)."
}
