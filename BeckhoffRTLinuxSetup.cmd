<# : ---- launcher (cmd.exe reads this part, PowerShell ignores it) --------------------------
@echo off
setlocal
title Beckhoff RT Linux Setup (unofficial)
set "PS1=%TEMP%\BeckhoffRTLinuxSetup.ps1"
copy /y "%~f0" "%PS1%" >nul
if not exist "%PS1%" (
    echo Could not write %PS1%
    pause
    exit /b 1
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%PS1%"
exit /b 0
#>
<#
    Beckhoff RT Linux Setup - GUI edition
    Compile to .exe with:   .\Build-Exe.ps1     (uses the ps2exe module)
    Or run directly:        powershell -ExecutionPolicy Bypass -STA -File .\BeckhoffRTLinuxSetup.ps1

    Flow (same as the console version):
      1. Discover the controller on the selected adapter via IPv6 link-local
         (ping ff02::1%idx -> Get-NetNeighbor -LinkLayerAddress 00-01-05*).
      2. Connect: generate/install the SSH key (one-time console window for the
         Administrator password - OpenSSH only reads passwords from a real console),
         read the controller's interfaces.
      3. Run: push the embedded bash script, execute it over "ssh -R <port>"
         (reverse SOCKS proxy through this PC). sudo password, myBeckhoff login and
         HMI password are streamed to it over the SSH pipe - never in argv or files.
      4. The bash script installs tc31-xar-um, tf2000-hmi-server, tf1200-ui-client,
         initializes TcHmiSrv, opens TCP 2020, then applies DHCP/static last.
#>
$ErrorActionPreference = 'Continue'
$ToolVersion = '1.2.2'
$ToolAuthor  = 'Abdullah Omar, Beckhoff UAE'
$Disclaimer  = @"
UNOFFICIAL TOOL - PLEASE READ

This tool was created by $ToolAuthor as a personal convenience utility.
It is NOT an official Beckhoff product and is NOT supported, tested or endorsed
by Beckhoff Automation GmbH & Co. KG or any of its subsidiaries.

It will, on the controller you select:
  - install an SSH key and log in as Administrator
  - install packages from deb.beckhoff.com using your myBeckhoff account
  - initialize the TwinCAT HMI Server and change firewall rules
  - change the IP configuration if you choose "Static IPv4"

Use it only on controllers you are allowed to modify, and at your own risk.
For supported procedures refer to the official Beckhoff RT Linux documentation
(infosys.beckhoff.com) and your Beckhoff support contact.

Continue?
"@
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# =============================================================================== remote script
# Runs as root on the controller. In --from-stdin mode it expects on stdin:
#   <sudo already consumed the first line>  BHF-SECRETS-BEGIN  <email>  <password>  <hmi password>
$RemoteScript = @'
#!/usr/bin/env bash
# bhf-setup.sh - runs as root on a Beckhoff RT Linux controller (pushed by BeckhoffRTLinuxSetup)
set -euo pipefail

PROXY_PORT=1080; NET_MODE=dhcp; NET_IFACE=end0; NET_ADDR=""; NET_GW=""; NET_DNS=""
SET_TIME=""; UI_AUTOSTART=0; UI_URL=""; UI_KIOSK=""; UI_USER=Administrator; FULL_UPGRADE=0; DELETE_CREDS=0; FROM_STDIN=0
LIST_ONLY=0; TESTING=0; PACKAGES="tc31-xar-um tf2000-hmi-server tf1200-ui-client"
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
    --ui-url)       UI_URL=$2; shift 2 ;;
    --ui-kiosk)     UI_KIOSK=$2; shift 2 ;;
    --ui-user)      UI_USER=$2; shift 2 ;;
    --packages)     PACKAGES=$2; shift 2 ;;
    --testing)      TESTING=1; shift ;;
    --list-only)    LIST_ONLY=1; shift ;;
    --full-upgrade) FULL_UPGRADE=1; shift ;;
    --delete-creds) DELETE_CREDS=1; shift ;;
    --from-stdin)   FROM_STDIN=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

step() { printf "\n==> %s\n" "$*"; }
ok()   { printf "    %s\n" "$*"; }
warn() { printf "    ! %s\n" "$*"; }
die()  { printf "ERROR: %s\n" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo"
APT_PROXY_CONF=/etc/apt/apt.conf.d/99-bhf-setup-proxy
AUTH_CONF=/etc/apt/auth.conf.d/bhf.conf
HMI_MARK=/etc/TwinCAT/.bhf-setup-hmi-initialized
HOME_DIR=$(getent passwd "${SUDO_USER:-Administrator}" | cut -d: -f6)
cleanup() { rm -f "$APT_PROXY_CONF" "$HOME_DIR/bhf-setup.sh" 2>/dev/null || true; }
trap cleanup EXIT
export DEBIAN_FRONTEND=noninteractive

BHF_MAIL=""; BHF_PW=""; HMI_PW=""
if [[ $FROM_STDIN -eq 1 ]]; then
  while IFS= read -r line; do [[ "$line" == "BHF-SECRETS-BEGIN" ]] && break; done
  IFS= read -r BHF_MAIL || true
  IFS= read -r BHF_PW   || true
  IFS= read -r HMI_PW   || true
fi

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
write_creds() {
  local mail="$1" pw="$2"
  install -m 600 -o root -g root /dev/null "$AUTH_CONF"
  printf 'machine deb.beckhoff.com\nlogin %s\npassword %s\n\nmachine deb-mirror.beckhoff.com\nlogin %s\npassword %s\n' \
    "$mail" "$pw" "$mail" "$pw" > "$AUTH_CONF"
  ok "wrote $AUTH_CONF (root, 0600)"
}
ask_creds() {
  local mail pw
  while true; do read -rp "    myBeckhoff e-mail: " mail; [[ -n "$mail" ]] && break; done
  while true; do
    read -rsp "    myBeckhoff password: " pw; echo
    [[ -n "$pw" ]] || { warn "empty"; continue; }
    [[ "$pw" =~ [[:space:]] ]] && { warn "apt's netrc format cannot hold spaces - change the password on myBeckhoff first"; continue; }
    break
  done
  write_creds "$mail" "$pw"
}
step "myBeckhoff credentials for deb.beckhoff.com"
if [[ $FROM_STDIN -eq 1 ]]; then
  if   [[ -n "$BHF_MAIL" ]]; then write_creds "$BHF_MAIL" "$BHF_PW"
  elif [[ -f "$AUTH_CONF" ]]; then ok "keeping existing $AUTH_CONF (login: $(awk '/^login/{print $2; exit}' "$AUTH_CONF"))"
  else die "no myBeckhoff credentials supplied and $AUTH_CONF does not exist"; fi
elif [[ -f "$AUTH_CONF" ]]; then
  read -rp "    $AUTH_CONF exists (login: $(awk '/^login/{print $2; exit}' "$AUTH_CONF")). Keep it? [Y/n] " keep
  [[ "${keep,,}" == n* ]] && ask_creds
else
  ask_creds
fi

# ---- optional: Beckhoff testing feed --------------------------------------------
# InfoSys "Optional: Integrate testing area": add "-testing" to the suite in bhf.list.
# We keep the stable line and add the testing line next to it (apt picks the newest version).
if [[ $TESTING -eq 1 ]]; then
  step "Beckhoff testing feed (NOT for production systems)"
  BHF_LIST=/etc/apt/sources.list.d/bhf.list
  BHF_SRC=/etc/apt/sources.list.d/bhf.sources
  if [[ -f "$BHF_LIST" ]]; then
    if grep -qE 'deb\.beckhoff\.com/debian +[A-Za-z]+-testing' "$BHF_LIST"; then
      ok "testing feed already present in $BHF_LIST"
    else
      tl=$(grep -E '^deb .*deb\.beckhoff\.com/debian +[A-Za-z]+ +main' "$BHF_LIST" | head -1 | sed -E 's|(deb\.beckhoff\.com/debian +[A-Za-z]+)( +main)|\1-testing\2|')
      if [[ -n "$tl" ]]; then echo "$tl" >> "$BHF_LIST"; ok "added: $tl"
      else warn "could not find the stable entry in $BHF_LIST - add the testing suite manually"; fi
    fi
  elif [[ -f "$BHF_SRC" ]]; then
    if grep -qE '^Suites:.*-testing' "$BHF_SRC"; then ok "testing feed already present in $BHF_SRC"
    else sed -i -E 's/^(Suites:[[:space:]]*)([A-Za-z]+)([[:space:]]*)$/\1\2 \2-testing/' "$BHF_SRC"; ok "added -testing suite to $BHF_SRC"; fi
  else
    warn "no bhf.list / bhf.sources found - testing feed not added"
  fi
fi

# ---- apt update (retry on 401) ---------------------------------------------------
step "apt update"
for attempt in 1 2 3; do
  if apt-get update 2>&1 | tee /tmp/bhf-apt-update.log | grep -Ev '^(Get|Hit|Ign):'; then :; fi
  if grep -qE '401|Unauthorized' /tmp/bhf-apt-update.log; then
    warn "401 Unauthorized from deb.beckhoff.com - wrong myBeckhoff e-mail or password (attempt $attempt/3)"
    [[ $FROM_STDIN -eq 1 ]] && die "authentication failed - check the myBeckhoff login and run again"
    [[ $attempt -lt 3 ]] && ask_creds || die "authentication failed three times"
  elif grep -qE '^(E|Err):' /tmp/bhf-apt-update.log; then
    die "apt update failed - see above"
  else
    ok "package lists updated"; break
  fi
done
# ---- list-only: print what the Beckhoff feeds offer and stop ----------------------
if [[ $LIST_ONLY -eq 1 ]]; then
  step "Beckhoff package list"
  dpkg-query -W -f='${Package}\t${Version}\n' > /tmp/bhf-inst.tsv 2>/dev/null || true
  : > /tmp/bhf-avail.tsv
  for f in /var/lib/apt/lists/deb.beckhoff.com_*_Packages /var/lib/apt/lists/deb-mirror.beckhoff.com_*_Packages; do
    [[ -f "$f" ]] || continue
    # deb.beckhoff.com mirrors all of Debian. Classify:
    #   product = Beckhoff product (tc31-, tf2000-, tf610x-, te1000-, twincat-*, tcpkg, *beckhoff*, *bhf*)
    #   other   = Debian packages rebuilt/maintained by Beckhoff (+bhfN versions, kernel libs, DPDK ...)
    #   everything else (plain Debian mirror content) is dropped
    awk 'BEGIN{RS=""; FS="\n"} {
      p="";v="";d="";m="";h="";
      for(i=1;i<=NF;i++){
        if($i ~ /^Package: /) p=substr($i,10);
        else if($i ~ /^Version: /) v=substr($i,10);
        else if($i ~ /^Description: /) d=substr($i,14);
        else if($i ~ /^Maintainer: /) m=tolower($i);
        else if($i ~ /^Homepage: /) h=tolower($i);
      }
      if(p=="") next;
      if(p ~ /^(tc|tf|te|tx)[0-9][0-9][0-9x]?[0-9x]?-/ || p ~ /(beckhoff|bhf|twincat|tcpkg)/) c="product";
      else if(m ~ /beckhoff/ || h ~ /beckhoff/ || v ~ /bhf/) c="other";
      else next;
      print p "\t" v "\t" d "\t" c
    }' "$f" >> /tmp/bhf-avail.tsv
  done
  sort -t$'\t' -k1,1 -k2,2Vr /tmp/bhf-avail.tsv | awk -F'\t' '!seen[$1]++' > /tmp/bhf-avail-uniq.tsv
  np=$(awk -F'\t' '$4=="product"' /tmp/bhf-avail-uniq.tsv | wc -l); no=$(awk -F'\t' '$4=="other"' /tmp/bhf-avail-uniq.tsv | wc -l)
  ok "$np Beckhoff product packages, $no other Beckhoff-built packages (Debian mirror content filtered out)"
  echo "BHF-PKGS-BEGIN"
  awk -F'\t' 'NR==FNR{inst[$1]=$2; next} {print $1 "\t" $2 "\t" (($1 in inst)? inst[$1] : "") "\t" $3 "\t" $4}' /tmp/bhf-inst.tsv /tmp/bhf-avail-uniq.tsv
  echo "BHF-PKGS-END"
  exit 0
fi

[[ $FULL_UPGRADE -eq 1 ]] && { step "apt full-upgrade"; apt-get full-upgrade -y; }

# ---- packages ----------------------------------------------------------------
step "TwinCAT packages: $PACKAGES"
for pkg in $PACKAGES; do
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
if ! dpkg -s tf2000-hmi-server >/dev/null 2>&1; then
  ok "tf2000-hmi-server not installed - skipping HMI server setup"
elif [[ -f "$HMI_MARK" ]] || systemctl is-active --quiet TcHmiSrv.service; then
  ok "TcHmiSrv already initialized - skipping --initialize"
else
  if [[ $FROM_STDIN -eq 0 ]]; then
    while true; do
      read -rsp "    New HMI admin password (for http://<ip>:2020): " HMI_PW; echo
      read -rsp "    Repeat: " HMI_PW2; echo
      [[ -n "$HMI_PW" && "$HMI_PW" == "$HMI_PW2" ]] && break
      warn "empty or mismatch - try again"
    done
  fi
  if [[ -n "$HMI_PW" ]]; then
    TcHmiSrv --initialize --password="$HMI_PW"
    touch "$HMI_MARK"
    ok "TcHmiSrv initialized"
  else
    warn "no HMI password supplied - TcHmiSrv NOT initialized (run: sudo TcHmiSrv --initialize --password=...)"
  fi
fi
unset HMI_PW HMI_PW2 BHF_PW
if ! dpkg -s tf2000-hmi-server >/dev/null 2>&1; then :
elif [[ ! -f /etc/nftables.conf.d/20-hmi.conf ]]; then
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
if [[ -f "$HMI_MARK" ]]; then
  systemctl enable --now TcHmiSrv.service >/dev/null 2>&1 && ok "TcHmiSrv enabled and started" || warn "TcHmiSrv did not start - check: journalctl -u TcHmiSrv"
fi

# ---- TF1200 UI client ---------------------------------------------------------
UI_BIN=/etc/TwinCAT/Functions/TF1200-UI-Client/TF1200-UI-Client
if ! dpkg -s tf1200-ui-client >/dev/null 2>&1; then
  step "TF1200 UI Client"; ok "tf1200-ui-client not installed - skipping UI Client setup"
  UI_AUTOSTART=0; UI_URL=""; UI_KIOSK=""
fi
if [[ $UI_AUTOSTART -eq 1 ]]; then
  step "TF1200 UI Client - autologin + autostart for $UI_USER"
  SETUP=/etc/TwinCAT/Functions/TF1200-UI-Client/scripts/setup-full.sh
  if [[ -x "$SETUP" ]]; then
    "$SETUP" --user=$UI_USER --autologin --autostart
    ok "setup-full.sh done (takes effect after reboot)"
  else
    warn "$SETUP not found - run the TF1200 setup manually"
  fi
fi
# startUrl / kiosk mode live in ~/.config/TF1200-UI-Client/config.json (created on the client's
# first start, or with 'TF1200-UI-Client --exit'). Create or patch it.
if [[ -n "$UI_URL" || -n "$UI_KIOSK" ]]; then
  step "TF1200 UI Client - config.json for user $UI_USER"
  UI_HOME=$(getent passwd "$UI_USER" | cut -d: -f6 || true)
  if [[ -z "$UI_HOME" ]]; then
    warn "user '$UI_USER' does not exist on the controller (setup-full.sh creates it when autologin/autostart is ticked) - config.json skipped"
    UI_URL=""; UI_KIOSK=""
  fi
fi
if [[ -n "$UI_URL" || -n "$UI_KIOSK" ]]; then
  UI_DIR="$UI_HOME/.config/TF1200-UI-Client"; UI_CFG="$UI_DIR/config.json"
  if [[ ! -f "$UI_CFG" && -x "$UI_BIN" ]]; then
    # let the client write its own defaults first (needs no display for --exit on most builds)
    timeout 30 sudo -u "$UI_USER" env HOME="$UI_HOME" "$UI_BIN" --exit >/dev/null 2>&1 || true
  fi
  install -d -o "$UI_USER" -g "$UI_USER" -m 700 "$UI_DIR"
  if [[ -f "$UI_CFG" ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$UI_CFG" "$UI_URL" "$UI_KIOSK" <<'PY'
import json, sys
path, url, kiosk = sys.argv[1:4]
try:
    with open(path) as f: cfg = json.load(f)
except Exception:
    cfg = {}
if url:   cfg["startUrl"] = url
if kiosk: cfg["enableKioskMode"] = (kiosk == "1")
cfg.setdefault("configVersion", "1.5")
cfg.setdefault("autoUpdateConfig", True)
with open(path, "w") as f: json.dump(cfg, f, indent=2)
PY
    ok "patched $UI_CFG"
  elif [[ -f "$UI_CFG" ]]; then
    # no python: sed the keys in place, append them if missing
    esc=$(printf '%s' "$UI_URL" | sed -e 's/[\\&|]/\\&/g')
    if [[ -n "$UI_URL" ]]; then
      if grep -q '"startUrl"' "$UI_CFG"; then sed -i -E "s|\"startUrl\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"startUrl\": \"$esc\"|" "$UI_CFG"
      else sed -i "0,/{/s|{|{\n  \"startUrl\": \"$esc\",|" "$UI_CFG"; fi
    fi
    if [[ -n "$UI_KIOSK" ]]; then
      kb=$([[ "$UI_KIOSK" == "1" ]] && echo true || echo false)
      if grep -q '"enableKioskMode"' "$UI_CFG"; then sed -i -E "s|\"enableKioskMode\"[[:space:]]*:[[:space:]]*(true\|false)|\"enableKioskMode\": $kb|" "$UI_CFG"
      else sed -i "0,/{/s|{|{\n  \"enableKioskMode\": $kb,|" "$UI_CFG"; fi
    fi
    ok "patched $UI_CFG (sed)"
  else
    # nothing there yet: write a minimal file; the client fills in the rest (autoUpdateConfig)
    kb=$([[ "$UI_KIOSK" == "1" ]] && echo true || echo false)
    {
      echo "{"
      echo "  \"configVersion\": \"1.5\","
      echo "  \"autoUpdateConfig\": true,"
      [[ -n "$UI_URL" ]] && echo "  \"startUrl\": \"$UI_URL\","
      echo "  \"enableKioskMode\": $kb"
      echo "}"
    } > "$UI_CFG"
    ok "created $UI_CFG"
  fi
  chown "$UI_USER:$UI_USER" "$UI_CFG"; chmod 600 "$UI_CFG"
  [[ -n "$UI_URL" ]] && ok "startUrl = $UI_URL"
  [[ -n "$UI_KIOSK" ]] && ok "enableKioskMode = $([[ "$UI_KIOSK" == "1" ]] && echo true || echo false)"
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
$RemoteScript = $RemoteScript -replace "`r`n", "`n"

# =============================================================================== worker
# Runs in a background runspace so the window stays responsive. Talks back through $sync.
$WorkerScript = @'
param($sync)
$ErrorActionPreference = 'Continue'
$P = $sync.Params
function Log([string]$m) { $sync.Queue.Enqueue($m) }

function Quote-Arg([string]$a) {
    if ($a -eq '') { return '""' }   # keep empty args (ssh-keygen -N "")
    if ($a -match '[\s"]') { '"' + ($a -replace '(\\*)"', '$1$1\"') + '"' } else { $a }
}

# Run a process hidden, stream stdout to the log, feed optional stdin, return code/out/err.
function Invoke-Proc([string]$File, [string[]]$Arguments, [string]$StdIn, [switch]$Quiet, [string[]]$QuietBetween) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = ($Arguments | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($StdIn) { $p.StandardInput.Write($StdIn) }
    $p.StandardInput.Close()
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = New-Object System.Text.StringBuilder
    $mute = $false
    while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
        [void]$out.AppendLine($line)
        if ($QuietBetween) {
            if ($line -eq $QuietBetween[0]) { $mute = $true; continue }
            if ($line -eq $QuietBetween[1]) { $mute = $false; continue }
        }
        if (-not $Quiet -and -not $mute) { Log $line }
    }
    $p.WaitForExit()
    $err = $errTask.Result
    if ($err -and -not $Quiet) { ($err -split "`n") | Where-Object { $_.Trim() } | ForEach-Object { Log "  ssh: $($_.TrimEnd())" } }
    return @{ Code = $p.ExitCode; Out = $out.ToString(); Err = $err }
}

$sshHost = "$($P.User)@$($P.Target)"
$base    = @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=8', '-o', 'ServerAliveInterval=15')
$keyed   = $base + @('-o', 'BatchMode=yes', '-i', $P.KeyPath)

function Test-KeyLogin { (Invoke-Proc $P.SshExe ($keyed + @($sshHost, 'true')) -Quiet) }

try {
    # ------------------------------------------------------------------ phase: connect
    if ($P.Phase -eq 'connect') {
        Log "==> SSH key"
        if (-not (Test-Path $P.KeyPath)) {
            Log "    generating $($P.KeyPath) (ed25519, no passphrase)"
            $r = Invoke-Proc $P.SshKeygenExe @('-q', '-t', 'ed25519', '-f', $P.KeyPath, '-N', '', '-C', "beckhoff-setup@$env:COMPUTERNAME") -Quiet
            if ($r.Code -ne 0 -or -not (Test-Path $P.KeyPath)) { throw "ssh-keygen failed: $($r.Err)" }
        } else { Log "    using $($P.KeyPath)" }
        $pubKey = (Get-Content "$($P.KeyPath).pub" -Raw).Trim()

        if ($P.ResetHostKey) {
            Log "    forgetting stored host key for $($P.Target)"
            [void](Invoke-Proc $P.SshKeygenExe @('-R', $P.Target) -Quiet)
        }

        $t = Test-KeyLogin
        if ($t.Code -ne 0 -and $t.Err -match 'HOST IDENTIFICATION HAS CHANGED') {
            throw "known_hosts holds an OLD host key for $($P.Target) (controller re-imaged or replaced?). If that is expected, tick 'Forget stored host key' and connect again."
        }
        if ($t.Code -ne 0) {
            Log "    key not authorized yet - a console window opens now: type the $($P.User) password (factory default: 1)"
            Log "    and answer 'yes' if asked to trust the host key."
            $cmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && " +
                   "(grep -qxF '$pubKey' ~/.ssh/authorized_keys || echo '$pubKey' >> ~/.ssh/authorized_keys) && echo KEY_INSTALLED"
            $argLine = (($base + @('-o', 'PubkeyAuthentication=no', $sshHost, $cmd)) | ForEach-Object { Quote-Arg $_ }) -join ' '
            $proc = Start-Process -FilePath $P.SshExe -ArgumentList $argLine -Wait -PassThru
            if ($proc.ExitCode -ne 0) { throw "could not install the public key (exit $($proc.ExitCode)) - wrong password or host key problem" }
            $t = Test-KeyLogin
            if ($t.Code -ne 0) { throw "public key installed but key login still fails: $($t.Err)" }
        }
        Log "    key-based login OK"

        Log "==> Reading interfaces"
        $r = Invoke-Proc $P.SshExe ($keyed + @($sshHost, 'hostname; echo ---; ip -br link | grep -v ^lo; echo ---; ip -br -4 addr; echo ---; ls /etc/systemd/network/ 2>/dev/null')) -Quiet
        if ($r.Code -ne 0) { throw "could not query interfaces: $($r.Err)" }
        $sec = ($r.Out -replace "`r", '') -split "`n---`n"
        $sync.RemoteHost = $sec[0].Trim()
        $links = @(($sec[1] -split "`n") | Where-Object { $_ -match '\S' })
        $sync.Ifaces = @($links | ForEach-Object { ($_ -split '\s+')[0] })
        $mac = ($P.DeviceMac -replace '-', ':').ToLower()
        $hit = $links | Where-Object { $_ -match [regex]::Escape($mac) } | Select-Object -First 1
        $sync.ConnectedIface = if ($hit) { ($hit -split '\s+')[0] } else { $sync.Ifaces[0] }
        Log "    hostname: $($sync.RemoteHost)"
        $links | ForEach-Object { Log "    $_" }
        (($sec[2] -split "`n") | Where-Object { $_ -match '\S' }) | ForEach-Object { Log "    $_" }
        if ($sec.Count -gt 3 -and $sec[3].Trim()) { Log "    /etc/systemd/network: $(($sec[3] -split "`n" | Where-Object { $_ }) -join ', ')" }
        $sync.Ok = $true
        return
    }

    # ------------------------------------------------------------------ phases: fetch / run
    Log "==> Pushing provisioning script"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($P.RemoteScript))
    $chunk = 6000; $first = $true
    for ($i = 0; $i -lt $b64.Length; $i += $chunk) {
        $part = $b64.Substring($i, [Math]::Min($chunk, $b64.Length - $i))
        $redir = if ($first) { '>' } else { '>>' }
        $r = Invoke-Proc $P.SshExe ($keyed + @($sshHost, "printf %s '$part' $redir ~/bhf-setup.b64")) -Quiet
        if ($r.Code -ne 0) { throw "push failed: $($r.Err)" }
        $first = $false
    }
    $r = Invoke-Proc $P.SshExe ($keyed + @($sshHost, 'base64 -d ~/bhf-setup.b64 > ~/bhf-setup.sh && rm -f ~/bhf-setup.b64 && chmod 700 ~/bhf-setup.sh && bash -n ~/bhf-setup.sh && echo SCRIPT_OK')) -Quiet
    if ($r.Code -ne 0 -or $r.Out -notmatch 'SCRIPT_OK') { throw "script did not decode/parse on the controller: $($r.Err)" }
    Log "    staged as ~/bhf-setup.sh"

    $utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    $args = @('--from-stdin', '--proxy-port', $P.ProxyPort, '--set-time', "'$utc'")
    if ($P.Testing) { $args += '--testing' }

    if ($P.Phase -eq 'fetch') {
        $args += '--list-only'
        $remoteCmd = "sudo -S -k -p '' -- bash ~/bhf-setup.sh $($args -join ' ') 2>&1"
        $stdin = "$($P.AdminPw)`nBHF-SECRETS-BEGIN`n$($P.BhfMail)`n$($P.BhfPw)`n`n"
        Log "==> Fetching the Beckhoff package list over ssh -R $($P.ProxyPort) $sshHost"
        $r = Invoke-Proc $P.SshExe ($keyed + @('-R', "$($P.ProxyPort)", $sshHost, $remoteCmd)) -StdIn $stdin -QuietBetween 'BHF-PKGS-BEGIN', 'BHF-PKGS-END'
        if ($r.Out -match 'Sorry, try again|incorrect password attempt') { throw "sudo rejected the $($P.User) password" }
        if ($r.Code -ne 0) { throw "package list failed with code $($r.Code) - see log above" }
        $pkgs = @(); $in = $false
        foreach ($line in ($r.Out -split "`n")) {
            $line = $line.TrimEnd("`r")
            if ($line -eq 'BHF-PKGS-BEGIN') { $in = $true; continue }
            if ($line -eq 'BHF-PKGS-END')   { break }
            if (-not $in) { continue }
            $f = $line -split "`t"
            if ($f.Count -ge 2 -and $f[0]) { $pkgs += @{ Name = $f[0]; Version = $f[1]; Installed = $(if ($f.Count -ge 3) { $f[2] } else { '' }); Desc = $(if ($f.Count -ge 4) { $f[3] } else { '' }); Cat = $(if ($f.Count -ge 5 -and $f[4]) { $f[4] } else { 'product' }) } }
        }
        if ($pkgs.Count -eq 0) { throw "no packages found in the Beckhoff feed - check the myBeckhoff login and the log" }
        $sync.Packages = $pkgs
        Log "    $($pkgs.Count) packages listed"
        $sync.Ok = $true
        return
    }

    $args += @('--packages', "'$($P.Packages)'", '--ui-user', $P.UiUser)
    if ($P.NetMode -eq 'static') {
        $args += @('--static', $P.NetAddr, '--iface', $P.NetIface)
        if ($P.NetGw)  { $args += @('--gateway', $P.NetGw) }
        if ($P.NetDns) { $args += @('--dns', $P.NetDns) }
    } else { $args += @('--dhcp', '--iface', $P.NetIface) }
    if ($P.UiAutostart) { $args += '--ui-autostart' }
    if ($P.UiUrl)       { $args += @('--ui-url', $P.UiUrl) }
    if ($P.UiKiosk -ne $null) { $args += @('--ui-kiosk', $(if ($P.UiKiosk) { '1' } else { '0' })) }
    if ($P.FullUpgrade) { $args += '--full-upgrade' }
    if ($P.DeleteCreds) { $args += '--delete-creds' }

    # sudo -S reads the first stdin line as the password; -k forces a prompt even if a
    # timestamp is cached; 2>&1 on the sudo command merges everything into stdout.
    $remoteCmd = "sudo -S -k -p '' -- bash ~/bhf-setup.sh $($args -join ' ') 2>&1"
    $stdin = "$($P.AdminPw)`nBHF-SECRETS-BEGIN`n$($P.BhfMail)`n$($P.BhfPw)`n$($P.HmiPw)`n"

    Log "==> Running setup over ssh -R $($P.ProxyPort) $sshHost"
    Log "    (the controller fetches packages through this PC - keep the window open)"
    $r = Invoke-Proc $P.SshExe ($keyed + @('-R', "$($P.ProxyPort)", $sshHost, $remoteCmd)) -StdIn $stdin
    if ($r.Out -match 'Sorry, try again|incorrect password attempt') { throw "sudo rejected the $($P.User) password" }
    if ($r.Code -ne 0) { throw "remote setup exited with code $($r.Code) - see log above; re-running is safe" }
    $sync.Ok = $true
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    $sync.Ok = $false
}
finally {
    $sync.Done = $true
}
'@

# =============================================================================== GUI
$sync = [hashtable]::Synchronized(@{
    Queue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    Params = @{}; Done = $false; Ok = $false; Ifaces = @(); ConnectedIface = ''; RemoteHost = ''; Packages = @()
})
$script:worker = $null; $script:handle = $null; $script:phase = ''
$script:devices = @()
$DefaultPackages = @('tc31-xar-um', 'tf2000-hmi-server', 'tf1200-ui-client')
$script:selectedPackages = @($DefaultPackages)

$form = New-Object System.Windows.Forms.Form
$form.Text = "Beckhoff RT Linux Setup v$ToolVersion  -  UNOFFICIAL tool by $ToolAuthor"
$form.ClientSize = New-Object System.Drawing.Size(760, 882)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

function Add-Group([string]$Text, [int]$Y, [int]$H) {
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $Text; $g.Location = New-Object System.Drawing.Point(12, $Y); $g.Size = New-Object System.Drawing.Size(736, $H)
    $form.Controls.Add($g); $g
}
function Add-Label($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 130) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Location = New-Object System.Drawing.Point($X, ($Y + 3)); $l.Size = New-Object System.Drawing.Size($W, 20)
    $Parent.Controls.Add($l); $l
}
function Add-Text($Parent, [int]$X, [int]$Y, [int]$W, [switch]$Password, [string]$Default = '') {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($X, $Y); $t.Size = New-Object System.Drawing.Size($W, 23); $t.Text = $Default
    if ($Password) { $t.UseSystemPasswordChar = $true }
    $Parent.Controls.Add($t); $t
}
function Add-Combo($Parent, [int]$X, [int]$Y, [int]$W) {
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Location = New-Object System.Drawing.Point($X, $Y); $c.Size = New-Object System.Drawing.Size($W, 23); $c.DropDownStyle = 'DropDownList'
    $Parent.Controls.Add($c); $c
}
function Add-Check($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 300) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $Text; $c.Location = New-Object System.Drawing.Point($X, $Y); $c.Size = New-Object System.Drawing.Size($W, 22)
    $Parent.Controls.Add($c); $c
}
function Add-Button($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 120) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Location = New-Object System.Drawing.Point($X, $Y); $b.Size = New-Object System.Drawing.Size($W, 27)
    $Parent.Controls.Add($b); $b
}

# ---- 1. controller
$g1 = Add-Group '1. Controller' 10 120
Add-Label $g1 'Ethernet adapter' 12 26 | Out-Null
$cbAdapter = Add-Combo $g1 150 26 360
$btnDiscover = Add-Button $g1 'Discover' 520 24 100
Add-Label $g1 'Controller' 12 56 | Out-Null
$cbDevice = Add-Combo $g1 150 56 470
Add-Label $g1 'Administrator password' 12 86 | Out-Null
$txtAdminPw = Add-Text $g1 150 86 200 -Password -Default '1'
$chkResetHostKey = Add-Check $g1 'Forget stored host key (controller was re-imaged)' 370 86 340
$btnConnect = Add-Button $g1 'Connect' 630 24 90
$btnConnect.Enabled = $false

# ---- 2. myBeckhoff
$g2 = Add-Group '2. Beckhoff package repository (myBeckhoff account) and packages' 138 150
Add-Label $g2 'E-mail' 12 26 | Out-Null
$txtBhfMail = Add-Text $g2 150 26 300
Add-Label $g2 'Password' 12 56 | Out-Null
$txtBhfPw = Add-Text $g2 150 56 300 -Password
$lblBhfHint = Add-Label $g2 'Leave both empty to keep an existing /etc/apt/auth.conf.d/bhf.conf on the controller' 460 26 270
$lblBhfHint.Size = New-Object System.Drawing.Size(270, 50)
$chkDeleteCreds = Add-Check $g2 'Delete bhf.conf from the controller when finished' 12 84 330
$chkTesting = Add-Check $g2 'Add Beckhoff testing feed (NOT for production systems)' 370 84 350
$btnFetch = Add-Button $g2 'Fetch package list...' 12 112 150
$btnFetch.Enabled = $false
$lblPackages = Add-Label $g2 '' 170 114 555
function Update-PackageLabel {
    $n = $script:selectedPackages.Count
    $txt = if ($n) { ($script:selectedPackages -join ', ') } else { '(none)' }
    if ($txt.Length -gt 90) { $txt = $txt.Substring(0, 87) + '...' }
    $lblPackages.Text = "Install ($n): $txt"
}
Update-PackageLabel

# ---- 3. HMI
$g3 = Add-Group '3. TwinCAT HMI Server (TF2000) / UI Client (TF1200)' 296 118
Add-Label $g3 'HMI admin password' 12 26 | Out-Null
$txtHmiPw = Add-Text $g3 150 26 200 -Password
Add-Label $g3 'Repeat' 12 56 | Out-Null
$txtHmiPw2 = Add-Text $g3 150 56 200 -Password
Add-Label $g3 'UI Client user' 370 26 100 | Out-Null
$txtUiUser = Add-Text $g3 475 26 130 -Default 'Administrator'
$lblUiUserHint = Add-Label $g3 '(Linux user; created if missing)' 610 26 120
$lblUiUserHint.Size = New-Object System.Drawing.Size(120, 40)
$chkUiAutostart = Add-Check $g3 'TF1200: autologin + autostart for that user' 370 56 360
Add-Label $g3 'UI Client start URL' 12 86 | Out-Null
$txtUiUrl = Add-Text $g3 150 86 300 -Default 'http://127.0.0.1:2020/'
$chkUiKiosk = Add-Check $g3 'Kiosk mode (full screen, no menu bar)' 460 86 270

# ---- 4. network
$g4 = Add-Group '4. Controller IP address (applied last, via systemd-networkd)' 422 130
$rbDhcp = New-Object System.Windows.Forms.RadioButton
$rbDhcp.Text = 'Keep DHCP / auto (factory default)'; $rbDhcp.Location = New-Object System.Drawing.Point(15, 26); $rbDhcp.Size = New-Object System.Drawing.Size(260, 22); $rbDhcp.Checked = $true
$rbStatic = New-Object System.Windows.Forms.RadioButton
$rbStatic.Text = 'Static IPv4'; $rbStatic.Location = New-Object System.Drawing.Point(290, 26); $rbStatic.Size = New-Object System.Drawing.Size(120, 22)
$g4.Controls.AddRange(@($rbDhcp, $rbStatic))
Add-Label $g4 'Interface' 12 56 | Out-Null
$cbIface = Add-Combo $g4 150 56 120
$lblIfaceHint = Add-Label $g4 '(filled after Connect)' 280 56 200
Add-Label $g4 'Address / prefix' 12 86 | Out-Null
$txtAddr = Add-Text $g4 150 86 160 -Default '192.168.1.100/24'
Add-Label $g4 'Gateway (optional)' 320 86 120 | Out-Null
$txtGw = Add-Text $g4 445 86 130
Add-Label $g4 'DNS (optional)' 585 86 90 | Out-Null
$txtDns = Add-Text $g4 675 86 55
$txtDns.Size = New-Object System.Drawing.Size(55, 23)
foreach ($c in @($txtAddr, $txtGw, $txtDns)) { $c.Enabled = $false }
$rbStatic.Add_CheckedChanged({ foreach ($c in @($txtAddr, $txtGw, $txtDns)) { $c.Enabled = $rbStatic.Checked } })

# ---- 5. options
$g5 = Add-Group '5. Options' 560 58
Add-Label $g5 'Reverse proxy port' 12 24 | Out-Null
$txtProxyPort = Add-Text $g5 150 24 70 -Default '1080'
$chkFullUpgrade = Add-Check $g5 'apt full-upgrade before installing packages' 240 24 320

# ---- run / log
$btnRun = Add-Button $form 'Run setup' 12 628 140
$btnRun.Enabled = $false
$lblStatus = Add-Label $form 'Pick the adapter connected to the controller, then Discover.' 170 630 570
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.ScrollBars = 'Vertical'; $txtLog.WordWrap = $false
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.Location = New-Object System.Drawing.Point(12, 664); $txtLog.Size = New-Object System.Drawing.Size(736, 186)
$txtLog.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($txtLog)
$lblFooter = Add-Label $form "Unofficial tool by $ToolAuthor - not an official or supported Beckhoff product. Use at your own risk." 12 856 736
$lblFooter.ForeColor = [System.Drawing.Color]::DarkRed

function Log([string]$m) { $txtLog.AppendText($m + "`r`n") }
function Set-Status([string]$m) { $lblStatus.Text = $m }
function Show-Error([string]$m) { [System.Windows.Forms.MessageBox]::Show($form, $m, 'Beckhoff RT Linux Setup', 'OK', 'Error') | Out-Null }

function Test-IPv4([string]$s) { $ip = $null; [System.Net.IPAddress]::TryParse($s, [ref]$ip) -and $ip.AddressFamily -eq 'InterNetwork' }

# ---- preflight
$sshExe    = (Get-Command ssh -ErrorAction SilentlyContinue).Source
$keygenExe = (Get-Command ssh-keygen -ErrorAction SilentlyContinue).Source
if (-not $sshExe -or -not $keygenExe) {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "The Windows 'OpenSSH Client' feature is not installed on this PC.`n`nInstall it now? Windows will ask for administrator permission.",
        'Beckhoff RT Linux Setup', 'YesNo', 'Question')
    if ($r -eq 'Yes') {
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList `
                '-NoProfile -ExecutionPolicy Bypass -Command "Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"'
        } catch {}
        $sysSsh = Join-Path $env:SystemRoot 'System32\OpenSSH'
        if (Test-Path (Join-Path $sysSsh 'ssh.exe')) { $env:Path = "$env:Path;$sysSsh" }
        $sshExe    = (Get-Command ssh -ErrorAction SilentlyContinue).Source
        $keygenExe = (Get-Command ssh-keygen -ErrorAction SilentlyContinue).Source
    }
    if (-not $sshExe -or -not $keygenExe) {
        Show-Error "OpenSSH client is still not available. Enable it via Settings > Apps > Optional features > 'OpenSSH Client', then start this tool again."
        return
    }
}
$keyPath = Join-Path (Join-Path $env:USERPROFILE '.ssh') 'id_ed25519'

$adapters = @(Get-NetAdapter -Physical | Where-Object { $_.MediaType -eq '802.3' } | Sort-Object ifIndex)
foreach ($a in $adapters) { [void]$cbAdapter.Items.Add(("{0}  (ifIndex {1}, {2})" -f $a.Name, $a.ifIndex, $a.Status)) }
$up = @($adapters | Where-Object Status -eq 'Up')
if ($up.Count -ge 1) { $cbAdapter.SelectedIndex = [Array]::IndexOf($adapters.ifIndex, $up[0].ifIndex) }
elseif ($adapters.Count) { $cbAdapter.SelectedIndex = 0 }

# ---- discover
$btnDiscover.Add_Click({
    if ($cbAdapter.SelectedIndex -lt 0) { Show-Error 'No Ethernet adapter selected.'; return }
    $idx = $adapters[$cbAdapter.SelectedIndex].ifIndex
    $cbDevice.Items.Clear(); $script:devices = @()
    Set-Status "Discovering on interface %$idx ..."
    Log "==> ping ff02::1%$idx  /  Get-NetNeighbor -LinkLayerAddress 00-01-05*"
    [System.Windows.Forms.Application]::DoEvents()
    $found = @()
    foreach ($try in 1..2) {
        & ping -n 2 -w 1000 "ff02::1%$idx" | Out-Null
        Start-Sleep -Seconds 1
        $found = @(Get-NetNeighbor -AddressFamily IPv6 -InterfaceIndex $idx -LinkLayerAddress '00-01-05*' -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -like 'fe80:*' -and $_.State -ne 'Unreachable' } | Sort-Object IPAddress -Unique)
        if ($found.Count) { break }
    }
    if (-not $found.Count) {
        Log "    nothing with a Beckhoff MAC answered on ifIndex $idx"
        Set-Status 'No controller found - check the cable and adapter, then Discover again.'
        return
    }
    foreach ($n in $found) {
        $addr = "$(($n.IPAddress -split '%')[0])%$idx"
        $script:devices += [pscustomobject]@{ Target = $addr; Mac = $n.LinkLayerAddress }
        [void]$cbDevice.Items.Add("$addr    MAC $($n.LinkLayerAddress)")
        Log "    found $addr  MAC $($n.LinkLayerAddress)"
    }
    $cbDevice.SelectedIndex = 0
    $btnConnect.Enabled = $true
    Set-Status "$($found.Count) controller(s) found - match the MAC with the name plate, enter the password, Connect."
})

# ---- package selection dialog
function Show-PackageDialog($pkgs) {
    $dlg = New-Object System.Windows.Forms.Form
    $nProd = @($pkgs | Where-Object { $_.Cat -eq 'product' }).Count
    $dlg.Text = "Beckhoff packages available from the repository ($nProd products, $($pkgs.Count - $nProd) other)"
    $dlg.ClientSize = New-Object System.Drawing.Size(860, 520)
    $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $hdr = New-Object System.Windows.Forms.Label
    $hdr.Text = 'Tick the packages to install. Installed ones are marked; ticking them is harmless (apt skips them).'
    $hdr.Location = New-Object System.Drawing.Point(12, 10); $hdr.Size = New-Object System.Drawing.Size(640, 20)
    $dlg.Controls.Add($hdr)
    $chkAll = New-Object System.Windows.Forms.CheckBox
    $chkAll.Text = 'Show all Beckhoff-built packages (kernel, libraries, rebuilt Debian tools) - not only TwinCAT products'
    $chkAll.Location = New-Object System.Drawing.Point(210, 482); $chkAll.Size = New-Object System.Drawing.Size(440, 27)
    $dlg.Controls.Add($chkAll)
    $lblF = New-Object System.Windows.Forms.Label; $lblF.Text = 'Search:'; $lblF.Location = New-Object System.Drawing.Point(660, 10); $lblF.Size = New-Object System.Drawing.Size(50, 20)
    $txtF = New-Object System.Windows.Forms.TextBox; $txtF.Location = New-Object System.Drawing.Point(712, 7); $txtF.Size = New-Object System.Drawing.Size(136, 23)
    $dlg.Controls.AddRange(@($lblF, $txtF))
    $lst = New-Object System.Windows.Forms.CheckedListBox
    $lst.Location = New-Object System.Drawing.Point(12, 34); $lst.Size = New-Object System.Drawing.Size(836, 440)
    $lst.CheckOnClick = $true; $lst.Font = New-Object System.Drawing.Font('Consolas', 9); $lst.HorizontalScrollbar = $true
    $dlg.Controls.Add($lst)
    # checked state lives in a hashtable so filtering the visible list never loses a tick
    $checked = @{}
    foreach ($pk in $pkgs) { $checked[$pk.Name] = ($script:selectedPackages -contains $pk.Name) }
    $visible = @()   # names shown in the list, in order
    $script:dlgBuilding = $false
    $rebuild = {
        $script:dlgBuilding = $true
        $lst.BeginUpdate(); $lst.Items.Clear()
        $vis = New-Object System.Collections.ArrayList
        $q = $txtF.Text.Trim().ToLower()
        foreach ($pk in $pkgs) {
            if ($pk.Cat -ne 'product' -and -not $chkAll.Checked -and -not $checked[$pk.Name]) { continue }
            if ($q -and ($pk.Name.ToLower().IndexOf($q) -lt 0) -and ($pk.Desc.ToLower().IndexOf($q) -lt 0)) { continue }
            $ver = if ($pk.Installed) { "installed $($pk.Installed)" } else { $pk.Version }
            [void]$vis.Add($pk.Name)                      # record the name BEFORE ticking (ItemCheck fires on SetItemChecked)
            $i = $lst.Items.Add(("{0,-30} {1,-26} {2}" -f $pk.Name, $ver, $pk.Desc))
            if ($checked[$pk.Name]) { $lst.SetItemChecked($i, $true) }
        }
        $script:dlgVisible = $vis.ToArray()
        $lst.EndUpdate()
        $script:dlgBuilding = $false
    }
    $lst.Add_ItemCheck({
        param($sender, $e)
        if ($script:dlgBuilding) { return }
        $name = $script:dlgVisible[$e.Index]
        if ($name) { $checked[$name] = ($e.NewValue -eq 'Checked') }
    })
    $txtF.Add_TextChanged({ & $rebuild })
    $chkAll.Add_CheckedChanged({ & $rebuild })
    & $rebuild
    $bDef = New-Object System.Windows.Forms.Button; $bDef.Text = 'Defaults'; $bDef.Location = New-Object System.Drawing.Point(12, 484); $bDef.Size = New-Object System.Drawing.Size(90, 27)
    $bNone = New-Object System.Windows.Forms.Button; $bNone.Text = 'None';    $bNone.Location = New-Object System.Drawing.Point(108, 484); $bNone.Size = New-Object System.Drawing.Size(90, 27)
    $bOk = New-Object System.Windows.Forms.Button;  $bOk.Text = 'OK';      $bOk.Location = New-Object System.Drawing.Point(662, 484); $bOk.Size = New-Object System.Drawing.Size(90, 27); $bOk.DialogResult = 'OK'
    $bCan = New-Object System.Windows.Forms.Button; $bCan.Text = 'Cancel';  $bCan.Location = New-Object System.Drawing.Point(758, 484); $bCan.Size = New-Object System.Drawing.Size(90, 27); $bCan.DialogResult = 'Cancel'
    $bDef.Add_Click({ foreach ($k in @($checked.Keys)) { $checked[$k] = ($DefaultPackages -contains $k) }; & $rebuild })
    $bNone.Add_Click({ foreach ($k in @($checked.Keys)) { $checked[$k] = $false }; & $rebuild })
    $dlg.Controls.AddRange(@($bDef, $bNone, $bOk, $bCan))
    $dlg.AcceptButton = $bOk; $dlg.CancelButton = $bCan
    if ($dlg.ShowDialog($form) -eq 'OK') {
        $sel = @()
        foreach ($pk in $pkgs) { if ($checked[$pk.Name]) { $sel += $pk.Name } }
        $script:selectedPackages = $sel
        Update-PackageLabel
        Log "==> Packages selected: $(if ($sel.Count) { $sel -join ' ' } else { '(none)' })"
    }
    $dlg.Dispose()
}

$btnFetch.Add_Click({
    if ($cbDevice.SelectedIndex -lt 0) { Show-Error 'Connect to the controller first.'; return }
    $errs = @()
    if (-not $txtAdminPw.Text) { $errs += 'Administrator password is required (sudo).' }
    if (($txtBhfMail.Text -ne '') -ne ($txtBhfPw.Text -ne '')) { $errs += 'myBeckhoff: enter both e-mail and password, or neither.' }
    if ($txtBhfPw.Text -match '\s') { $errs += "myBeckhoff password contains whitespace - apt's netrc format cannot store that." }
    $port = 0
    if (-not [int]::TryParse($txtProxyPort.Text, [ref]$port) -or $port -lt 1024 -or $port -gt 65535) { $errs += 'Proxy port must be 1024-65535.' }
    if ($errs.Count) { Show-Error ($errs -join "`n"); return }
    $d = $script:devices[$cbDevice.SelectedIndex]
    Set-Status 'Fetching the package list (apt update through this PC) ...'
    Start-Worker 'fetch' @{
        Phase = 'fetch'; SshExe = $sshExe; SshKeygenExe = $keygenExe; KeyPath = $keyPath
        User = 'Administrator'; Target = $d.Target; DeviceMac = $d.Mac; RemoteScript = $RemoteScript
        AdminPw = $txtAdminPw.Text; BhfMail = $txtBhfMail.Text.Trim(); BhfPw = $txtBhfPw.Text
        ProxyPort = $port; Testing = $chkTesting.Checked
    }
})

# ---- worker start/finish
function Start-Worker([string]$Phase, [hashtable]$Params) {
    $sync.Params = $Params; $sync.Done = $false; $sync.Ok = $false
    $script:phase = $Phase
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
    $script:worker = [powershell]::Create(); $script:worker.Runspace = $rs
    [void]$script:worker.AddScript($WorkerScript).AddArgument($sync)
    $script:handle = $script:worker.BeginInvoke()
    foreach ($c in @($btnDiscover, $btnConnect, $btnRun, $btnFetch)) { $c.Enabled = $false }
    $form.UseWaitCursor = $true
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
    while ($sync.Queue.Count -gt 0) { Log $sync.Queue.Dequeue() }
    if ($script:worker -and $sync.Done) {
        try { [void]$script:worker.EndInvoke($script:handle) } catch {}
        $script:worker.Runspace.Close(); $script:worker.Dispose(); $script:worker = $null
        $form.UseWaitCursor = $false
        $btnDiscover.Enabled = $true; $btnConnect.Enabled = ($cbDevice.Items.Count -gt 0)
        if ($script:phase -eq 'connect') {
            if ($sync.Ok) {
                $cbIface.Items.Clear()
                foreach ($i in $sync.Ifaces) { [void]$cbIface.Items.Add($i) }
                if ($cbIface.Items.Count) { $cbIface.SelectedIndex = [Math]::Max(0, $cbIface.Items.IndexOf($sync.ConnectedIface)) }
                $lblIfaceHint.Text = "(you are connected on $($sync.ConnectedIface))"
                $btnRun.Enabled = $true; $btnFetch.Enabled = $true
                Set-Status "Connected to $($sync.RemoteHost). Fill in sections 2-4 (optionally pick packages), then Run setup."
            } else { Set-Status 'Connect failed - see log.' }
        } elseif ($script:phase -eq 'fetch') {
            $btnRun.Enabled = $true; $btnFetch.Enabled = $true
            if ($sync.Ok) { Set-Status "$($sync.Packages.Count) packages listed - pick what to install."; Show-PackageDialog $sync.Packages }
            else { Set-Status 'Fetching the package list failed - see log.' }
        } else {
            if ($sync.Ok) {
                Set-Status 'Setup finished.'
                $msg = "Provisioning finished on $($sync.RemoteHost)."
                if ($sync.Params.NetMode -eq 'static') {
                    $ip = ($sync.Params.NetAddr -split '/')[0]
                    $msg += "`n`nStatic address: $ip on $($sync.Params.NetIface)`nSSH: ssh Administrator@$ip`nHMI: http://${ip}:2020`n`nSet this PC's adapter into the same subnet to use it."
                }
                $msg += "`n`nFallback: ssh Administrator@$($sync.Params.Target)"
                [System.Windows.Forms.MessageBox]::Show($form, $msg, 'Beckhoff RT Linux Setup', 'OK', 'Information') | Out-Null
            } else { Set-Status 'Setup failed - see log. Re-running is safe.'; $btnRun.Enabled = $true }
        }
    }
})
$timer.Start()

# ---- connect
$btnConnect.Add_Click({
    if ($cbDevice.SelectedIndex -lt 0) { Show-Error 'Select a controller first.'; return }
    if (-not $txtAdminPw.Text) { Show-Error 'Enter the Administrator password (factory default: 1).'; return }
    $d = $script:devices[$cbDevice.SelectedIndex]
    Set-Status "Connecting to $($d.Target) ..."
    Start-Worker 'connect' @{
        Phase = 'connect'; SshExe = $sshExe; SshKeygenExe = $keygenExe; KeyPath = $keyPath
        User = 'Administrator'; Target = $d.Target; DeviceMac = $d.Mac
        ResetHostKey = $chkResetHostKey.Checked
    }
})

# ---- run
$btnRun.Add_Click({
    $d = $script:devices[$cbDevice.SelectedIndex]
    $errs = @()
    if (-not $txtAdminPw.Text) { $errs += 'Administrator password is required (sudo).' }
    if (($txtBhfMail.Text -ne '') -ne ($txtBhfPw.Text -ne '')) { $errs += 'myBeckhoff: enter both e-mail and password, or neither.' }
    if ($txtBhfPw.Text -match '\s') { $errs += "myBeckhoff password contains whitespace - apt's netrc format cannot store that; change it on myBeckhoff first." }
    if ($txtHmiPw.Text -ne $txtHmiPw2.Text) { $errs += 'HMI passwords do not match.' }
    if (-not $txtHmiPw.Text -and ($script:selectedPackages -contains 'tf2000-hmi-server')) { $errs += 'HMI admin password is required (TcHmiSrv --initialize).' }
    if ($script:selectedPackages.Count -eq 0) { $errs += 'No packages selected - use "Fetch package list..." to pick at least one.' }
    $uiUser = $txtUiUser.Text.Trim()
    if ($uiUser -notmatch '^[a-z_][a-z0-9_-]{0,31}$' -and $uiUser -ne 'Administrator') { $errs += 'UI Client user must be a valid Linux user name (lowercase letters, digits, - and _), or Administrator.' }
    $port = 0
    if (-not [int]::TryParse($txtProxyPort.Text, [ref]$port) -or $port -lt 1024 -or $port -gt 65535) { $errs += 'Proxy port must be 1024-65535.' }
    if ($cbIface.SelectedIndex -lt 0) { $errs += 'No controller interface selected - Connect first.' }
    $uiUrl = $txtUiUrl.Text.Trim()
    if ($uiUrl -and ($uiUrl -notmatch '^(https?|file)://\S+$' -or $uiUrl -match '["\\]')) { $errs += 'UI Client start URL must look like http://127.0.0.1:2020/ (or https:// / file://), without quotes or spaces.' }
    if ($rbStatic.Checked) {
        if (-not ($txtAddr.Text -match '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$' -and (Test-IPv4 $Matches[1]) -and [int]$Matches[2] -ge 1 -and [int]$Matches[2] -le 30)) { $errs += 'Static address must look like 192.168.1.100/24.' }
        if ($txtGw.Text -and -not (Test-IPv4 $txtGw.Text)) { $errs += 'Gateway is not a valid IPv4 address.' }
        if ($txtDns.Text -and -not (Test-IPv4 $txtDns.Text)) { $errs += 'DNS is not a valid IPv4 address.' }
    }
    if ($errs.Count) { Show-Error ($errs -join "`n"); return }

    Set-Status 'Running setup - the controller downloads through this PC, keep the window open ...'
    Start-Worker 'run' @{
        Phase = 'run'; SshExe = $sshExe; SshKeygenExe = $keygenExe; KeyPath = $keyPath
        User = 'Administrator'; Target = $d.Target; DeviceMac = $d.Mac
        RemoteScript = $RemoteScript
        AdminPw = $txtAdminPw.Text; BhfMail = $txtBhfMail.Text.Trim(); BhfPw = $txtBhfPw.Text; HmiPw = $txtHmiPw.Text
        NetMode = $(if ($rbStatic.Checked) { 'static' } else { 'dhcp' })
        NetIface = $cbIface.SelectedItem; NetAddr = $txtAddr.Text.Trim(); NetGw = $txtGw.Text.Trim(); NetDns = $txtDns.Text.Trim()
        ProxyPort = $port; UiAutostart = $chkUiAutostart.Checked; UiUrl = $uiUrl; UiKiosk = $chkUiKiosk.Checked; UiUser = $uiUser
        Packages = ($script:selectedPackages -join ' '); Testing = $chkTesting.Checked
        FullUpgrade = $chkFullUpgrade.Checked; DeleteCreds = $chkDeleteCreds.Checked
    }
})

$form.Add_FormClosing({
    if ($script:worker -and -not $sync.Done) {
        $r = [System.Windows.Forms.MessageBox]::Show($form, 'A setup is still running. Closing now may leave the controller half-configured. Close anyway?', 'Beckhoff RT Linux Setup', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $_.Cancel = $true; return }
        try { [void]$script:worker.Stop() } catch {}
    }
})

$answer = [System.Windows.Forms.MessageBox]::Show($Disclaimer, "Beckhoff RT Linux Setup v$ToolVersion - unofficial tool", 'YesNo', 'Warning', 'Button2')
if ($answer -ne 'Yes') { return }

Log "Beckhoff RT Linux Setup v$ToolVersion - unofficial tool by $ToolAuthor (not a Beckhoff product)"
Log "OpenSSH: $sshExe"
Log "Key: $keyPath"
[void]$form.ShowDialog()
