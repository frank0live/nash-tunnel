#!/usr/bin/env bash
# ==============================================================================
#  Nash Tunnel — GRE + FRP + Backhaul (xray) + Watchdog + Panel
#  One-file installer & manager.  bash nash.sh            (interactive menu)
#                              bash nash.sh <command> ... (non-interactive)
#
#  Commands:
#    install-iran      Set up this server as the IRAN side (GRE server + frps + panel)
#    install-foreign   Set up this server as a FOREIGN node (GRE client + frpc + backhaul)
#    backhaul          Configure the xray backhaul between iran and foreign
#    watchdog          Install/refresh the watchdog timer
#    benchmark         Measure latency/loss to every configured node
#    failover          Switch the active foreign node (manual or automatic)
#    status            One-screen health report
#    panel             (Re)start the web panel
#    passwd            Change panel password
#    update            Pull latest version from git and reinstall
#    uninstall         Remove everything installed by this script
# ==============================================================================
set -uo pipefail

VERSION="1.0.2"
SELF="$(readlink -f "$0")"
SRC_DIR="$(cd "$(dirname "$SELF")" && pwd)"

INSTALL_DIR="/usr/local/bin"
CONF_DIR="${NASH_CONF_DIR:-/etc/nash}"
GRE_IF="nash-gre"
GRE_IRAN_IP="10.66.66.1"
GRE_FOREIGN_IP="10.66.66.2"
GRE_KEY_FILE="$CONF_DIR/gre.key"
NODES_FILE="${NODES_FILE:-$CONF_DIR/nodes.json}"
CONFIG_FILE="$CONF_DIR/config.json"
BACKHAUL_DIR="$CONF_DIR/backhaul"

C_OK=$'\033[0;32m'; C_ERR=$'\033[0;31m'; C_WARN=$'\033[1;33m'
C_INFO=$'\033[0;36m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_N=$'\033[0m'

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✔%s %s\n' "$C_OK" "$C_N" "$*"; }
warn() { printf '%s!%s %s\n' "$C_WARN" "$C_N" "$*"; }
err()  { printf '%s✘%s %s\n' "$C_ERR" "$C_N" "$*" >&2; }
step() { printf '\n%s▸ %s%s\n' "$C_INFO" "$*" "$C_N"; }

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "run as root"; exit 1; }
}

have() { command -v "$1" >/dev/null 2>&1; }

rand() { head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-"${1:-24}"; }

# digits only - ip link wants an integer for the GRE key
rand_num() {
  local n
  n=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' \n')
  [[ "$n" =~ ^[0-9]+$ ]] || n=$(( (RANDOM << 15 | RANDOM) % 4294967294 ))
  printf '%s' "$(( n % 4294967294 + 1 ))"
}

# hex only, that is what a REALITY shortId has to be
rand_hex() { od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | cut -c1-"${1:-16}"; }

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) err "unsupported arch $(uname -m)"; exit 1 ;;
  esac
}

public_ip() {
  local ip
  ip=$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null) || \
  ip=$(curl -4 -fsS --max-time 6 https://ifconfig.me 2>/dev/null) || ip=""
  printf '%s' "${ip:-unknown}"
}

# ---------------------------------------------------------------- dependencies
install_deps() {
  step "Installing dependencies"
  if have apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq curl wget tar unzip iproute2 iptables iputils-ping \
      jq python3 openssl ca-certificates >/dev/null 2>&1 || true
  elif have dnf; then
    dnf install -y -q curl wget tar unzip iproute iptables iputils jq python3 openssl >/dev/null 2>&1 || true
  elif have yum; then
    yum install -y -q curl wget tar unzip iproute iptables iputils jq python3 openssl >/dev/null 2>&1 || true
  fi
  ok "dependencies ready"
}

# ---------------------------------------------------------------- FRP binaries
install_frp() {
  local role="$1" arch ver
  arch=$(detect_arch)
  ver="${FRP_VERSION:-0.61.1}"
  if [[ -x "$INSTALL_DIR/frps" && -x "$INSTALL_DIR/frpc" ]]; then
    ok "frp already installed"
    return 0
  fi
  step "Downloading FRP $ver ($arch)"
  local tmp; tmp=$(mktemp -d)
  local url="https://github.com/fatedier/frp/releases/download/v${ver}/frp_${ver}_linux_${arch}.tar.gz"
  if ! curl -fsSL --max-time 90 "$url" -o "$tmp/frp.tgz"; then
    err "FRP download failed"; rm -rf "$tmp"; return 1
  fi
  tar -xzf "$tmp/frp.tgz" -C "$tmp" || { err "bad archive"; rm -rf "$tmp"; return 1; }
  install -m 755 "$tmp"/frp_*/frps "$INSTALL_DIR/frps"
  install -m 755 "$tmp"/frp_*/frpc "$INSTALL_DIR/frpc"
  rm -rf "$tmp"
  ok "frp installed"
}

# ---------------------------------------------------------------- GRE
gre_key() {
  mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
  # rebuild it if it is missing or still holds an old non-numeric key
  if [[ ! -s "$GRE_KEY_FILE" ]] || ! grep -qE '^[0-9]+$' "$GRE_KEY_FILE"; then
    rand_num > "$GRE_KEY_FILE"
  fi
  chmod 600 "$GRE_KEY_FILE"
  cat "$GRE_KEY_FILE"
}

write_gre_unit() {
  local mode="$1" peer="$2" local_ip="$3" remote_ip="$4" key="${5:-}"
  # both ends have to use the same key, so take the one we are handed
  if [[ -n "$key" ]]; then
    printf '%s\n' "$key" > "$GRE_KEY_FILE"; chmod 600 "$GRE_KEY_FILE"
  else
    key=$(gre_key)
  fi
  [[ "$key" =~ ^[0-9]+$ ]] || { err "GRE key must be digits only (got: '$key')"; return 1; }
  cat >/etc/systemd/system/nash-gre.service <<EOF
[Unit]
Description=Nash GRE tunnel ($mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/sbin/modprobe ip_gre
ExecStartPre=-/sbin/ip link del $GRE_IF
ExecStart=/sbin/ip link add $GRE_IF type gre local $local_ip remote $peer ttl 255 key $key
ExecStart=/sbin/ip addr add $remote_ip/30 dev $GRE_IF
ExecStart=/sbin/ip link set $GRE_IF mtu 1400 up
ExecStop=-/sbin/ip link del $GRE_IF

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable nash-gre.service >/dev/null 2>&1
  systemctl restart nash-gre.service || { err "GRE failed to start"; return 1; }
}

# ---------------------------------------------------------------- panel install
install_panel() {
  local role="$1" listen_port="${2:-8090}"
  step "Installing web panel"
  mkdir -p /opt/nash-panel/web
  install -m 755 "$SRC_DIR/panel/panel.py" /opt/nash-panel/panel.py
  install -m 644 "$SRC_DIR/web/index.html" /opt/nash-panel/web/index.html

  local pw="${NASH_PASSWORD:-$(rand 14)}"
  cat >"$CONFIG_FILE" <<EOF
{
  "listen": "0.0.0.0",
  "port": $listen_port,
  "title": "Nash Tunnel",
  "role": "$role",
  "gre_iface": "$GRE_IF",
  "frp_service": "$([[ $role == iran ]] && echo nash-frps || echo nash-frpc)",
  "xray_service": "nash-backhaul",
  "panel_service": "nash-panel",
  "watchdog_service": "nash-watchdog",
  "telegram": {"token": "", "chat_id": ""},
  "nodes": []
}
EOF
  chmod 600 "$CONFIG_FILE"

  cat >/etc/systemd/system/nash-panel.service <<EOF
[Unit]
Description=Nash Tunnel Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=NASH_CONFIG=$CONFIG_FILE
Environment=NASH_STATE=$CONF_DIR/panel.json
Environment=NASH_PASSWORD=$pw
ExecStart=/usr/bin/python3 /opt/nash-panel/panel.py
Restart=always
RestartSec=3
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable nash-panel.service >/dev/null 2>&1
  systemctl restart nash-panel.service
  sleep 1
  if curl -fsS --max-time 4 "http://127.0.0.1:$listen_port/api/health" >/dev/null 2>&1; then
    ok "panel running on :$listen_port"
    printf '\n%s  Panel: http://%s:%s   password: %s%s\n\n' "$C_B" "$(public_ip)" "$listen_port" "$pw" "$C_N"
  else
    err "panel did not answer on :$listen_port (journalctl -u nash-panel)"
  fi
}

# ---------------------------------------------------------------- FRP configs
write_frps() {
  local bind_port="${1:-7000}" token="${2:-$(rand 20)}"
  step "Writing frps config"
  mkdir -p "$CONF_DIR"
  cat >"$CONF_DIR/frps.toml" <<EOF
bindAddr = "0.0.0.0"
bindPort = $bind_port
auth.method = "token"
auth.token = "$token"
transport.maxPoolCount = 200
allowPorts = [{ start = 20000, end = 60000 }]
log.to = "console"
log.level = "info"
EOF
  chmod 600 "$CONF_DIR/frps.toml"
  cat >/etc/systemd/system/nash-frps.service <<EOF
[Unit]
Description=Nash FRP server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/frps -c $CONF_DIR/frps.toml
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable nash-frps.service >/dev/null 2>&1
  systemctl restart nash-frps.service
  sleep 1
  systemctl is-active --quiet nash-frps.service && ok "frps on :$bind_port (token saved in $CONF_DIR/frps.toml)" || err "frps failed"
}

write_frpc() {
  local server="$1" bind_port="$2" token="$3"
  step "Writing frpc config"
  mkdir -p "$CONF_DIR"
  cat >"$CONF_DIR/frpc.toml" <<EOF
serverAddr = "$server"
serverPort = $bind_port
auth.method = "token"
auth.token = "$token"
transport.poolCount = 20
transport.tcpMux = true
log.to = "console"
log.level = "info"

# --- example proxy: expose local ssh on the iran server port 22022
# [[proxies]]
# name = "ssh"
# type = "tcp"
# localIP = "127.0.0.1"
# localPort = 22
# remotePort = 22022
EOF
  chmod 600 "$CONF_DIR/frpc.toml"
  cat >/etc/systemd/system/nash-frpc.service <<EOF
[Unit]
Description=Nash FRP client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/frpc -c $CONF_DIR/frpc.toml
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable nash-frpc.service >/dev/null 2>&1
  systemctl restart nash-frpc.service
  sleep 1
  systemctl is-active --quiet nash-frpc.service && ok "frpc connected to $server:$bind_port" || warn "frpc not active yet (check $CONF_DIR/frpc.toml)"
}

# ---------------------------------------------------------------- Backhaul (xray)
install_xray() {
  have xray && { ok "xray present"; return 0; }
  step "Installing Xray"
  if ! bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1; then
    err "xray install failed"; return 1
  fi
  ok "xray installed"
}

backhaul_server() {
  local port="${1:-24443}" sni="${2:-www.microsoft.com}"
  step "Configuring backhaul server (foreign side)"
  install_xray || return 1
  mkdir -p "$BACKHAUL_DIR"
  local uuid; uuid=$(cat /proc/sys/kernel/random/uuid)
  local priv pub
  priv=$(/usr/local/bin/xray x25519 2>/dev/null | awk '/Private/{print $NF}')
  pub=$(/usr/local/bin/xray x25519 -i "$priv" 2>/dev/null | awk '/Public/{print $NF}')
  [[ -z "$pub" ]] && { err "x25519 failed"; return 1; }
  local sid; sid=$(rand_hex 16)

  cat >"$BACKHAUL_DIR/server.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0", "port": $port, "protocol": "vless",
    "settings": {"clients": [{"id": "$uuid", "flow": ""}], "decryption": "none"},
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "$sni:443", "serverNames": ["$sni"],
        "privateKey": "$priv", "shortIds": ["$sid"]
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {
      "finalRules": [
        {"action": "allow", "network": "tcp", "ip": ["127.0.0.1/32", "::1/128"]}
      ]
    }
  }]
}
EOF
  chmod 600 "$BACKHAUL_DIR/server.json"   # holds the REALITY private key
  cat >/etc/systemd/system/nash-backhaul.service <<EOF
[Unit]
Description=Nash Backhaul (xray server)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -c $BACKHAUL_DIR/server.json
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable nash-backhaul.service >/dev/null 2>&1
  systemctl restart nash-backhaul.service
  sleep 1
  systemctl is-active --quiet nash-backhaul.service && ok "backhaul server on :$port" || { err "backhaul server failed"; return 1; }

  cat >"$CONF_DIR/backhaul-client.txt" <<EOF
# Paste these into the IRAN server:
SERVER=$(public_ip)
PORT=$port
UUID=$uuid
PUBLIC_KEY=$pub
SHORT_ID=$sid
SNI=$sni
EOF
  chmod 600 "$CONF_DIR/backhaul-client.txt"
  say ""
  say "${C_B}--- IRAN side settings ---${C_N}"
  say "server  : $(public_ip):$port"
  say "uuid    : $uuid"
  say "pubkey  : $pub"
  say "shortId : $sid"
  say "sni     : $sni"
  say "${C_DIM}saved to $CONF_DIR/backhaul-client.txt${C_N}"
}

backhaul_client() {
  local server="$1" port="$2" uuid="$3" pub="$4" sid="$5" sni="$6"
  step "Configuring backhaul client (iran side)"
  install_xray || return 1
  mkdir -p "$BACKHAUL_DIR"

  # local ports forwarded through the tunnel: 22 (ssh), 7000 (frps), 8090 (panel)
  cat >"$BACKHAUL_DIR/client.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {"listen": "127.0.0.1", "port": 16022, "protocol": "dokodemo-door",
     "settings": {"address": "127.0.0.1", "port": 22, "network": "tcp"}},
    {"listen": "127.0.0.1", "port": 16080, "protocol": "dokodemo-door",
     "settings": {"address": "127.0.0.1", "port": 80, "network": "tcp"}}
  ],
  "outbounds": [{
    "protocol": "vless",
    "settings": {"vnext": [{"address": "$server", "port": $port,
      "users": [{"id": "$uuid", "encryption": "none"}]}]},
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "realitySettings": {"serverName": "$sni", "publicKey": "$pub",
                          "shortId": "$sid", "fingerprint": "chrome"}
    }
  }]
}
EOF
  chmod 600 "$BACKHAUL_DIR/client.json"
  cat >/etc/systemd/system/nash-backhaul.service <<EOF
[Unit]
Description=Nash Backhaul (xray client)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -c $BACKHAUL_DIR/client.json
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable nash-backhaul.service >/dev/null 2>&1
  systemctl restart nash-backhaul.service
  sleep 1
  systemctl is-active --quiet nash-backhaul.service && ok "backhaul client running" || err "backhaul client failed"
}

# ---------------------------------------------------------------- watchdog
install_watchdog() {
  step "Installing watchdog"
  # the watchdog shells out to $INSTALL_DIR/nash.sh, so keep a copy there
  if [[ -f "$SELF" && "$SELF" != "$INSTALL_DIR/nash.sh" ]]; then
    install -m 755 "$SELF" "$INSTALL_DIR/nash.sh"
  fi
  cat >"$INSTALL_DIR/nash-watchdog" <<'WDE'
#!/usr/bin/env bash
# Nash watchdog — checks units + tunnel, restarts what's down, alerts via telegram.
set -uo pipefail
CONF="/etc/nash/config.json"
[[ -f "$CONF" ]] || exit 0
get() { python3 -c "import json,sys;d=json.load(open('$CONF'));print(eval('d'+sys.argv[1]) or '')" "$1" 2>/dev/null; }
TOKEN=$(get "['telegram']['token']")
CHAT=$(get "['telegram']['chat_id']")
GRE_IF=$(get "['gre_iface']"); GRE_IF=${GRE_IF:-nash-gre}

alert() {
  [[ -n "$TOKEN" && -n "$CHAT" ]] || return 0
  curl -fsS --max-time 8 "https://api.telegram.org/bot$TOKEN/sendMessage" \
    -d "chat_id=$CHAT" -d "text=$1" -d "parse_mode=HTML" >/dev/null 2>&1 || true
}

restart_unit() {
  local u="$1"
  systemctl is-active --quiet "$u" || {
    systemctl restart "$u" >/dev/null 2>&1
    sleep 2
    if systemctl is-active --quiet "$u"; then
      alert "🔧 <b>$(hostname)</b>: $u was down — restarted OK"
    else
      alert "🚨 <b>$(hostname)</b>: $u is DOWN and restart failed"
    fi
  }
}

for u in nash-panel nash-frps nash-frpc nash-backhaul; do
  systemctl list-unit-files | grep -q "^$u.service" && restart_unit "$u"
done

# GRE link check
if ip link show "$GRE_IF" >/dev/null 2>&1; then
  state=$(cat "/sys/class/net/$GRE_IF/operstate" 2>/dev/null || echo down)
  if [[ "$state" != "up" ]]; then
    systemctl restart nash-gre >/dev/null 2>&1
    sleep 2
    [[ "$(cat /sys/class/net/$GRE_IF/operstate 2>/dev/null)" == "up" ]] \
      && alert "🔧 <b>$(hostname)</b>: GRE link was down — restored" \
      || alert "🚨 <b>$(hostname)</b>: GRE link is DOWN"
  fi
fi

# Failover: switch to the healthiest foreign node when the active one dies
if [[ -f /etc/nash/nodes.json ]]; then
  OUT=$(NASH_CONF_DIR=/etc/nash NODES_FILE=/etc/nash/nodes.json \
        bash /usr/local/bin/nash.sh failover auto 2>&1)
  if grep -q 'switched active node' <<<"$OUT"; then
    alert "🔀 <b>$(hostname)</b>: failover — active node switched
<pre>$(sed -n '1,12p' <<<"$OUT")</pre>"
  fi
fi
WDE
  chmod 755 "$INSTALL_DIR/nash-watchdog"

  cat >/etc/systemd/system/nash-watchdog.service <<EOF
[Unit]
Description=Nash watchdog check
After=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/nash-watchdog
EOF
  cat >/etc/systemd/system/nash-watchdog.timer <<EOF
[Unit]
Description=Run Nash watchdog every 60s

[Timer]
OnBootSec=45
OnUnitActiveSec=60
AccuracySec=5s
Unit=nash-watchdog.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now nash-watchdog.timer >/dev/null 2>&1
  ok "watchdog timer active (every 60s)"
}

# ---------------------------------------------------------------- benchmark
benchmark() {
  step "Benchmarking nodes"
  [[ -f "$NODES_FILE" ]] || { warn "no nodes configured ($NODES_FILE)"; return 0; }
  python3 - "$NODES_FILE" <<'PY'
import json, re, subprocess, sys, socket, time
nodes = json.load(open(sys.argv[1]))
rows = []
for n in nodes:
    host, port, name = n.get("host"), n.get("port"), n.get("name") or n.get("host")
    if not host:
        continue
    if port:
        t0 = time.time()
        try:
            with socket.create_connection((host, int(port)), timeout=4):
                ms, ok = round((time.time()-t0)*1000), True
        except Exception:
            ms, ok = None, False
        rows.append((name, host, f"tcp:{port}", ms, "-", ok))
    else:
        p = subprocess.run(["ping","-c","4","-W","2",host], capture_output=True, text=True)
        loss = re.search(r"(\d+)% packet loss", p.stdout)
        rtt  = re.search(r"rtt min/avg/max/mdev = [\d.]+/([\d.]+)/", p.stdout)
        rows.append((name, host, "icmp",
                     round(float(rtt.group(1)),1) if rtt else None,
                     (loss.group(1)+"%") if loss else "100%",
                     bool(rtt) and (loss is None or int(loss.group(1))<100)))
rows.sort(key=lambda r: (not r[5], r[3] if r[3] is not None else 9e9))
print(f"{'NODE':<18}{'HOST':<20}{'TYPE':<10}{'LATENCY':>9}{'LOSS':>7}  STATUS")
for name, host, typ, ms, loss, ok in rows:
    print(f"{name:<18}{host:<20}{typ:<10}{(str(ms)+' ms') if ms else '-':>9}{loss:>7}  {'OK' if ok else 'FAIL'}")
PY
}

# ---------------------------------------------------------------- failover
failover() {
  local mode="${1:-auto}"
  [[ -f "$NODES_FILE" ]] || { err "no nodes file ($NODES_FILE)"; return 1; }
  step "Failover check ($mode)"
  python3 - "$NODES_FILE" "$CONF_DIR/active-node" "$mode" <<'PY'
import json, socket, sys, time, os

nodes_path, state_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
nodes = json.load(open(nodes_path))
if not nodes:
    print("no nodes configured"); sys.exit(1)

def probe(n, timeout=3.0):
    host, port = n.get("host"), n.get("port") or 22
    t0 = time.time()
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True, round((time.time()-t0)*1000)
    except Exception:
        return False, None

results = [(n, *probe(n)) for n in nodes]
alive = [(n, ms) for n, ok, ms in results if ok]
alive.sort(key=lambda x: x[1])

for n, ok, ms in results:
    print(f"  {'OK  ' if ok else 'FAIL'}  {n.get('name') or n.get('host'):<20} "
          f"{n.get('host')}:{n.get('port') or 22}  {str(ms)+' ms' if ms else '-'}")

if not alive:
    print("!! every node is down"); sys.exit(2)

best = alive[0][0].get("name") or alive[0][0].get("host")
current = ""
if os.path.exists(state_path):
    current = open(state_path).read().strip()
os.makedirs(os.path.dirname(state_path) or ".", exist_ok=True)

print(f"\ncurrent: {current or '(none)'}   best: {best}")
if mode == "auto" and current and current != best:
    cur_alive = any((n.get("name") or n.get("host")) == current for n, _ in alive)
    if not cur_alive:
        open(state_path, "w").write(best + "\n")
        print(f"→ switched to {best} (previous node down)")
        sys.exit(10)
    print("→ current node healthy, no switch")
else:
    open(state_path, "w").write(best + "\n")
    print(f"→ active node = {best}")
PY
  local rc=$?
  case $rc in
    0) ok "failover check done" ;;
    2) err "all nodes down" ;;
    10) ok "switched active node" ;;
  esac
  return 0
}

# ---------------------------------------------------------------- status
status_report() {
  say ""
  say "${C_B}Nash Tunnel $VERSION${C_N}  —  $(hostname)  ($(public_ip))"
  say "${C_DIM}$(date)${C_N}"
  say ""
  printf '%-22s %s\n' "uptime" "$(uptime -p 2>/dev/null || uptime)"
  printf '%-22s %s\n' "load" "$(cut -d' ' -f1-3 /proc/loadavg)"
  printf '%-22s %s\n' "memory" "$(free -m | awk '/Mem:/{printf "%d/%d MB (%.0f%%)",$3,$2,$3*100/$2}')"
  printf '%-22s %s\n' "disk" "$(df -h / | awk 'NR==2{printf "%s/%s (%s)",$3,$2,$5}')"
  say ""
  for u in nash-panel nash-frps nash-frpc nash-backhaul nash-gre nash-watchdog.timer; do
    systemctl list-unit-files 2>/dev/null | grep -q "^$u" || continue
    st=$(systemctl is-active "$u" 2>/dev/null)
    if [[ "$st" == active ]]; then printf '%-22s %s✔ %s%s\n' "$u" "$C_OK" "$st" "$C_N"
    else printf '%-22s %s✘ %s%s\n' "$u" "$C_ERR" "$st" "$C_N"; fi
  done
  if ip link show "$GRE_IF" >/dev/null 2>&1; then
    printf '%-22s %s\n' "$GRE_IF" "$(cat /sys/class/net/$GRE_IF/operstate 2>/dev/null)"
  fi
  say ""
}

# ---------------------------------------------------------------- uninstall
uninstall_all() {
  step "Uninstalling Nash Tunnel"
  for u in nash-panel nash-frps nash-frpc nash-backhaul nash-gre nash-watchdog.timer nash-watchdog; do
    systemctl disable --now "$u" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$u.service" "/etc/systemd/system/$u.timer"
  done
  systemctl daemon-reload
  ip link del "$GRE_IF" >/dev/null 2>&1 || true
  rm -rf /opt/nash-panel "$CONF_DIR"
  rm -f "$INSTALL_DIR/frps" "$INSTALL_DIR/frpc" "$INSTALL_DIR/nash-watchdog" "$INSTALL_DIR/nash.sh"
  ok "removed (xray itself left in place)"
}

# ---------------------------------------------------------------- menu
menu() {
  # stdin is a drained pipe when the script comes in through curl|bash,
  # reads fail straight away and the menu loops forever, so grab the tty
  if [[ ! -t 0 ]]; then
    # in a subshell, or a missing /dev/tty prints an error
    if (exec 0</dev/tty) 2>/dev/null; then
      exec 0</dev/tty
    else
      say "no tty on stdin (piped install?)"
      say "run it non-interactively instead:"
      say "  bash $SELF status"
      say "  bash $SELF install-iran | install-foreign | watchdog | benchmark"
      exit 2
    fi
  fi
  while true; do
    say ""
    say "${C_B}┌─ Nash Tunnel $VERSION ────────────────────────┐${C_N}"
    say "  1) Status / health report"
    say "  2) Install as IRAN server   (GRE + frps + panel)"
    say "  3) Install as FOREIGN node  (GRE + frpc + backhaul)"
    say "  4) Backhaul: set up server side (foreign)"
    say "  5) Backhaul: set up client side (iran)"
    say "  6) Install / refresh watchdog"
    say "  7) Benchmark nodes"
    say "  7b) Failover check (switch to healthiest node)"
    say "  8) Restart panel"
    say "  9) Change panel password"
    say " 10) Uninstall everything"
    say "  0) Exit"
    say "${C_B}└──────────────────────────────────────────────┘${C_N}"
    read -rp "select: " ch
    case "$ch" in
      1) status_report ;;
      2) cmd_install_iran ;;
      3) cmd_install_foreign ;;
      4) read -rp "port [24443]: " p; read -rp "sni [www.microsoft.com]: " s
         backhaul_server "${p:-24443}" "${s:-www.microsoft.com}" ;;
      5) read -rp "server ip: " s; read -rp "port: " p; read -rp "uuid: " u
         read -rp "public key: " k; read -rp "short id: " i; read -rp "sni: " n
         backhaul_client "$s" "$p" "$u" "$k" "$i" "$n" ;;
      6) install_watchdog ;;
      7) benchmark ;;
      7b) failover auto ;;
      8) systemctl restart nash-panel && ok "panel restarted" ;;
      9) read -rsp "new password (min 8): " pw; echo
         python3 - "$pw" <<'PY'
import json,sys,hashlib,secrets
pw=sys.argv[1]
p="/etc/nash/panel.json"
d=json.load(open(p)); salt=secrets.token_hex(16)
d["salt"]=salt
d["password_hash"]=hashlib.pbkdf2_hmac("sha256",pw.encode(),salt.encode(),120000).hex()
d["sessions"]={}
json.dump(d,open(p,"w"),indent=2)
print("password changed")
PY
         systemctl restart nash-panel >/dev/null 2>&1 ;;
      10) read -rp "type YES to uninstall: " c; [[ "$c" == YES ]] && uninstall_all ;;
      0) exit 0 ;;
      *) warn "invalid choice" ;;
    esac
  done
}

# ---------------------------------------------------------------- commands
cmd_install_iran() {
  need_root; install_deps
  step "IRAN server setup"
  local pubip; pubip=$(public_ip)
  read -rp "foreign server IP (GRE peer): " peer
  [[ -n "$peer" ]] || { err "peer required"; return 1; }
  local grekey; grekey=$(gre_key)
  write_gre_unit "iran" "$peer" "$pubip" "$GRE_IRAN_IP" "$grekey" || return 1
  ok "GRE up: $pubip <-> $peer"
  say ""
  say "  ${C_B}GRE key: $grekey${C_N}"
  say "  ${C_DIM}use the same key on the FOREIGN node${C_N}"
  local bindp; read -rp "frps bind port [7000]: " bindp; bindp=${bindp:-7000}
  install_frp iran || return 1
  local frptok; frptok=$(rand 20)
  write_frps "$bindp" "$frptok"
  install_panel iran 8090
  install_watchdog
  say ""
  say "  ${C_B}--- FOREIGN node settings ---${C_N}"
  say "  iran IP     : $pubip"
  say "  GRE key     : $grekey"
  say "  frps port   : $bindp"
  say "  frp token   : $frptok"
  status_report
}

cmd_install_foreign() {
  need_root; install_deps
  step "FOREIGN node setup"
  local pubip; pubip=$(public_ip)
  read -rp "iran server IP (GRE peer): " peer
  [[ -n "$peer" ]] || { err "peer required"; return 1; }
  local grekey
  read -rp "GRE key from the IRAN server: " grekey
  [[ "$grekey" =~ ^[0-9]+$ ]] || { err "GRE key must be digits (copy it from IRAN)"; return 1; }
  write_gre_unit "foreign" "$peer" "$pubip" "$GRE_FOREIGN_IP" "$grekey" || return 1
  ok "GRE up: $pubip <-> $peer"
  local srv bp tok
  read -rp "iran server IP for frpc [same as peer]: " srv; srv=${srv:-$peer}
  read -rp "frps bind port [7000]: " bp; bp=${bp:-7000}
  read -rp "frp token: " tok
  install_frp foreign || return 1
  write_frpc "$srv" "$bp" "$tok"
  install_panel foreign 8091
  install_watchdog
  status_report
}

case "${1:-menu}" in
  install-iran)    shift; cmd_install_iran "$@" ;;
  install-foreign) shift; cmd_install_foreign "$@" ;;
  backhaul)        shift; backhaul_server "$@" ;;
  backhaul-client) shift; backhaul_client "$@" ;;
  watchdog)        need_root; install_watchdog ;;
  benchmark)       benchmark ;;
  failover)        shift; failover "${1:-auto}" ;;
  status)          status_report ;;
  panel)           need_root; systemctl restart nash-panel && ok "panel restarted" ;;
  uninstall)       need_root; uninstall_all ;;
  version|-v|--version) say "Nash Tunnel $VERSION" ;;
  menu|"")         menu ;;
  *) err "unknown command: $1"; say "try: bash $0"; exit 1 ;;
esac
