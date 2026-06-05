#!/bin/bash

# ═══════════════════════════════════════════════════════════
#  GOLDFRP - FRP Reverse Tunnel Manager
#  Wraps fatedier/frp (frps + frpc) with a colored TUI
# ═══════════════════════════════════════════════════════════

FRPS_BIN="/usr/local/bin/frps"
FRPC_BIN="/usr/local/bin/frpc"
CONFIG_DIR="/etc/frp"
LOG_DIR="/var/log/frp"
TUNNEL_DB="/root/.goldfrp_tunnels.json"
DEFAULT_VERSION="0.69.1"
VERSION_FILE="/etc/frp/.version"

# GitHub mirror prefixes (used when github.com is filtered).
# Empty string = direct GitHub. Others are verified-working proxies.
GH_MIRRORS=(
    ""
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    "https://ghproxy.net/"
)

# Minimum acceptable archive size in bytes (reject HTML error pages / truncated files)
MIN_ARCHIVE_SIZE=3000000

# ─────────────────────────── Colors ───────────────────────────
declare -A COLORS=(
    [RESET]='\033[0m'
    [RED]='\033[38;5;196m'
    [GREEN]='\033[38;5;46m'
    [PINK]='\033[38;5;213m'
    [CYAN]='\033[38;5;51m'
    [YELLOW]='\033[38;5;226m'
    [ORANGE]='\033[38;5;208m'
    [BLUE]='\033[38;5;39m'
    [OLIVE]='\033[38;5;142m'
    [PURPLE]='\033[38;5;141m'
    [TEAL]='\033[38;5;43m'
)

# Background message styles (white text on solid background)
BG_GREEN='\033[48;5;28m\033[97m'
BG_RED='\033[48;5;160m\033[97m'
BG_YELLOW='\033[48;5;172m\033[97m'
C_RESET='\033[0m'

print_color() {
    echo -e "${COLORS[$1]}${2}${COLORS[RESET]}"
}

msg_ok()   { echo -e "${BG_GREEN}  ✓ ${1}  ${C_RESET}"; }
msg_err()  { echo -e "${BG_RED}  ✗ ${1}  ${C_RESET}"; }
msg_warn() { echo -e "${BG_YELLOW}  ⚠ ${1}  ${C_RESET}"; }

clear_screen() { printf "\033c"; }

print_logo() {
    echo ""
    echo -e "${COLORS[PINK]}   ██████╗  ${COLORS[CYAN]}██████╗  ${COLORS[YELLOW]}██╗     ${COLORS[ORANGE]}██████╗  ${COLORS[BLUE]}███████╗${COLORS[OLIVE]}██████╗ ${COLORS[PURPLE]}██████╗ ${COLORS[RESET]}"
    echo -e "${COLORS[PINK]}  ██╔════╝  ${COLORS[CYAN]}██╔══██╗ ${COLORS[YELLOW]}██║     ${COLORS[ORANGE]}██╔══██╗ ${COLORS[BLUE]}██╔════╝${COLORS[OLIVE]}██╔══██╗${COLORS[PURPLE]}██╔══██╗${COLORS[RESET]}"
    echo -e "${COLORS[PINK]}  ██║  ███╗ ${COLORS[CYAN]}██║  ██║ ${COLORS[YELLOW]}██║     ${COLORS[ORANGE]}██║  ██║ ${COLORS[BLUE]}█████╗  ${COLORS[OLIVE]}██████╔╝${COLORS[PURPLE]}██████╔╝${COLORS[RESET]}"
    echo -e "${COLORS[PINK]}  ██║   ██║ ${COLORS[CYAN]}██║  ██║ ${COLORS[YELLOW]}██║     ${COLORS[ORANGE]}██║  ██║ ${COLORS[BLUE]}██╔══╝  ${COLORS[OLIVE]}██╔══██╗${COLORS[PURPLE]}██╔═══╝ ${COLORS[RESET]}"
    echo -e "${COLORS[PINK]}  ╚██████╔╝ ${COLORS[CYAN]}██████╔╝ ${COLORS[YELLOW]}███████╗${COLORS[ORANGE]}██████╔╝ ${COLORS[BLUE]}██║     ${COLORS[OLIVE]}██║  ██║${COLORS[PURPLE]}██║     ${COLORS[RESET]}"
    echo -e "${COLORS[PINK]}   ╚═════╝  ${COLORS[CYAN]}╚═════╝  ${COLORS[YELLOW]}╚══════╝${COLORS[ORANGE]}╚═════╝  ${COLORS[BLUE]}╚═╝     ${COLORS[OLIVE]}╚═╝  ╚═╝${COLORS[PURPLE]}╚═╝     ${COLORS[RESET]}"
    echo ""
    print_color "CYAN"   "        F R P   R E V E R S E   T U N N E L   M A N A G E R"
    print_color "ORANGE" "  ═══════════════════════════════════════════════════════════════"
    echo ""

    if [[ -f "$FRPS_BIN" && -f "$FRPC_BIN" ]]; then
        local ver
        ver=$(cat "$VERSION_FILE" 2>/dev/null || echo "?")
        print_color "GREEN" "  ✓ FRP Installed   (v${ver})"
    else
        print_color "RED" "  ✗ FRP Not Installed"
    fi
    echo ""
}

print_header() {
    clear_screen
    print_logo
}

press_enter() {
    echo ""
    print_color "ORANGE" "Press Enter to continue..."
    read -r
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_err "This script must be run as root"
        exit 1
    fi
}

# ─────────────────────────── Helpers ───────────────────────────
init_tunnel_db() {
    [[ -f "$TUNNEL_DB" ]] || echo "{}" > "$TUNNEL_DB"
}

save_tunnel_info() {
    local service="$1" name="$2" role="$3" port="$4" dest="$5" proto="$6"
    init_tunnel_db
    local tmp
    tmp=$(mktemp)
    jq --arg s "$service" --arg n "$name" --arg r "$role" \
       --arg p "$port" --arg d "$dest" --arg pr "$proto" \
       '.[$s] = {name:$n, role:$r, port:$p, destination:$d, protocol:$pr}' \
       "$TUNNEL_DB" > "$tmp" 2>/dev/null && mv "$tmp" "$TUNNEL_DB" || rm -f "$tmp"
}

get_tunnel_info() {
    init_tunnel_db
    jq -r --arg s "$1" '.[$s] // empty' "$TUNNEL_DB" 2>/dev/null
}

delete_tunnel_info() {
    init_tunnel_db
    local tmp
    tmp=$(mktemp)
    jq --arg s "$1" 'del(.[$s])' "$TUNNEL_DB" > "$tmp" 2>/dev/null && mv "$tmp" "$TUNNEL_DB" || rm -f "$tmp"
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]
}

validate_ip() {
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && return 0
    [[ "$1" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]] && return 0
    return 1
}

# Accept an IPv4/IPv6 address OR a domain name (needed for CDN tunnels)
validate_host() {
    validate_ip "$1" && return 0
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] && return 0
    return 1
}

check_port_in_use() {
    ss -tuln 2>/dev/null | grep -q ":${1} "
}

generate_token() {
    openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | xxd -p
}

generate_pass() {
    openssl rand -hex 6 2>/dev/null || head -c 6 /dev/urandom | xxd -p
}

get_next_port() {
    local p="$1"
    while check_port_in_use "$p"; do ((p++)); done
    echo "$p"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7l|armv7)   echo "arm" ;;
        armv6l)         echo "arm" ;;
        i386|i686)      echo "386" ;;
        mips64)         echo "mips64" ;;
        *)              echo "" ;;
    esac
}

list_tunnels() {
    local t=()
    for s in /etc/systemd/system/frp-*.service; do
        [[ -f "$s" ]] && t+=("$(basename "$s" .service)")
    done
    echo "${t[@]}"
}

apply_sysctl() {
    sysctl -w net.core.rmem_max=134217728 >/dev/null 2>&1
    sysctl -w net.core.wmem_max=134217728 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_rmem="4096 87380 67108864" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 65536 67108864" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null 2>&1
}

# Sets globals: PROTO (frp transport.protocol), PROTO_LABEL (display),
#               PROTO_MUX (true/false), PROTO_TLS (true/false)
ask_protocol() {
    echo ""
    print_color "CYAN" "Select tunnel transport protocol:"
    echo ""
    print_color "PINK"   "  [1] TCP        (most compatible)"
    print_color "CYAN"   "  [2] KCP        (UDP based, fast under packet loss)"
    print_color "YELLOW" "  [3] QUIC       (UDP based, modern, low latency)"
    print_color "ORANGE" "  [4] WS         (websocket, single connection)"
    print_color "PURPLE" "  [5] WSMUX      (websocket + multiplex, CDN friendly)"
    print_color "TEAL"   "  [6] WSSMUX     (websocket + multiplex + TLS, best for CDN)"
    echo ""
    print_color "PINK" "Select (1-6):"
    read -r _p
    PROTO=""; PROTO_LABEL=""; PROTO_MUX="true"; PROTO_TLS="true"
    case "$_p" in
        1) PROTO="tcp";       PROTO_LABEL="tcp";    PROTO_MUX="true";  PROTO_TLS="true"  ;;
        2) PROTO="kcp";       PROTO_LABEL="kcp";    PROTO_MUX="true";  PROTO_TLS="true"  ;;
        3) PROTO="quic";      PROTO_LABEL="quic";   PROTO_MUX="false"; PROTO_TLS="true"  ;;
        4) PROTO="websocket"; PROTO_LABEL="ws";     PROTO_MUX="false"; PROTO_TLS="false" ;;
        5) PROTO="websocket"; PROTO_LABEL="wsmux";  PROTO_MUX="true";  PROTO_TLS="false" ;;
        6) PROTO="websocket"; PROTO_LABEL="wssmux"; PROTO_MUX="true";  PROTO_TLS="true"  ;;
        *) PROTO="" ;;
    esac
}

# Sets globals: TLS_CERT TLS_KEY TLS_CA TLS_SERVERNAME (empty if unused)
# $1 = role (iran|kharej) — affects which fields are asked
ask_tls_certs() {
    local role="$1"
    TLS_CERT=""; TLS_KEY=""; TLS_CA=""; TLS_SERVERNAME=""
    [[ "$PROTO_TLS" != "true" ]] && return 0

    echo ""
    print_color "CYAN" "Use a custom TLS certificate? (yes/no)"
    print_color "OLIVE" "  (no = FRP built-in TLS, fine when a CDN terminates TLS)"
    read -r _use
    [[ "$_use" != "yes" ]] && return 0

    echo ""
    print_color "PINK" "Certificate file path (.crt):"
    read -r TLS_CERT
    [[ -n "$TLS_CERT" && ! -f "$TLS_CERT" ]] && msg_warn "File not found: $TLS_CERT (will still be written)"

    echo ""
    print_color "PINK" "Private key file path (.key):"
    read -r TLS_KEY
    [[ -n "$TLS_KEY" && ! -f "$TLS_KEY" ]] && msg_warn "File not found: $TLS_KEY (will still be written)"

    echo ""
    print_color "PINK" "CA file path (.crt) — optional, leave empty to skip:"
    read -r TLS_CA

    if [[ "$role" == "kharej" ]]; then
        echo ""
        print_color "PINK" "TLS Server Name (SNI) — optional, e.g. your CDN domain:"
        read -r TLS_SERVERNAME
    fi
}

# ─────────────────────────── Install ───────────────────────────
fetch_latest_version() {
    local v
    v=$(curl -fsSL --max-time 10 https://api.github.com/repos/fatedier/frp/releases/latest 2>/dev/null \
        | grep -oP '"tag_name":\s*"v\K[0-9.]+' | head -1)
    [[ -n "$v" ]] && echo "$v" || echo "$DEFAULT_VERSION"
}

# Verify a downloaded archive is a real, complete frp tarball.
# Rejects HTML error pages, truncated files, and archives missing the binaries.
verify_archive() {
    local f="$1"
    [[ -s "$f" ]] || return 1
    local size
    size=$(stat -c%s "$f" 2>/dev/null || echo 0)
    (( size >= MIN_ARCHIVE_SIZE )) || return 1
    gzip -t "$f" 2>/dev/null || return 1
    tar -tzf "$f" 2>/dev/null | grep -q '/frps$' || return 1
    tar -tzf "$f" 2>/dev/null | grep -q '/frpc$' || return 1
    return 0
}

download_frp() {
    local version="$1" arch="$2" out="$3"
    local file="frp_${version}_linux_${arch}.tar.gz"
    local path="fatedier/frp/releases/download/v${version}/${file}"
    local m url
    for m in "${GH_MIRRORS[@]}"; do
        if [[ -z "$m" ]]; then
            url="https://github.com/${path}"
        else
            url="${m}https://github.com/${path}"
        fi
        print_color "PINK" "→ Trying: ${url}"
        rm -f "$out"
        # curl follows redirects (-L) and fails on HTTP errors (-f); fall back to wget
        if curl -fL --connect-timeout 15 --max-time 120 -o "$out" "$url" 2>/dev/null \
           || wget -q --timeout=120 --tries=2 "$url" -O "$out" 2>/dev/null; then
            if verify_archive "$out"; then
                print_color "GREEN" "→ Downloaded & verified ($(stat -c%s "$out") bytes)"
                return 0
            fi
            print_color "YELLOW" "  ⚠ Invalid/incomplete file from this source, trying next..."
        fi
        rm -f "$out"
    done
    return 1
}

install_frp() {
    clear_screen; print_logo
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    print_color "CYAN"   "  Install / Update FRP"
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    echo ""

    if [[ -f "$FRPS_BIN" ]]; then
        msg_warn "FRP is already installed"
        print_color "BLUE" "Reinstall / update? (yes/no)"
        read -r c
        [[ "$c" != "yes" ]] && return
    fi

    local arch
    arch=$(detect_arch)
    if [[ -z "$arch" ]]; then
        msg_err "Unsupported CPU architecture: $(uname -m)"
        press_enter; return
    fi
    print_color "TEAL" "→ Detected architecture: ${arch}"

    print_color "PINK" "→ Resolving latest version..."
    local version
    version=$(fetch_latest_version)
    print_color "GREEN" "→ Target version: v${version}"
    echo ""

    local archive="/tmp/frp_${version}.tar.gz"
    rm -f "$archive"
    if ! download_frp "$version" "$arch" "$archive"; then
        clear_screen; print_logo
        msg_err "Download failed from all sources for v${version}"
        echo ""
        print_color "YELLOW" "You can enter a version manually (e.g. 0.69.1), or leave empty to abort:"
        read -r manual
        if [[ -n "$manual" ]]; then
            version="${manual#v}"
            archive="/tmp/frp_${version}.tar.gz"
            if ! download_frp "$version" "$arch" "$archive"; then
                clear_screen; print_logo
                msg_err "Download failed again. GitHub may be filtered."
                print_color "YELLOW" "  Options: change DNS, use a working mirror, or copy frps/frpc to /usr/local/bin manually."
                press_enter; return
            fi
        else
            press_enter; return
        fi
    fi

    print_color "CYAN" "→ Extracting..."
    local tmpd="/tmp/frp_extract_$$"
    rm -rf "$tmpd"; mkdir -p "$tmpd"
    if ! tar -xzf "$archive" -C "$tmpd"; then
        msg_err "Extraction failed"
        rm -rf "$tmpd" "$archive"; press_enter; return
    fi

    local frps_src frpc_src
    frps_src=$(find "$tmpd" -type f -name frps 2>/dev/null | head -1)
    frpc_src=$(find "$tmpd" -type f -name frpc 2>/dev/null | head -1)
    if [[ -z "$frps_src" || -z "$frpc_src" ]]; then
        msg_err "Binaries not found inside archive"
        print_color "YELLOW" "  Extracted contents:"
        find "$tmpd" -maxdepth 2 2>/dev/null | head -20
        rm -rf "$tmpd" "$archive"; press_enter; return
    fi
    install -m 0755 "$frps_src" "$FRPS_BIN"
    install -m 0755 "$frpc_src" "$FRPC_BIN"

    mkdir -p "$CONFIG_DIR" "$LOG_DIR"
    echo "$version" > "$VERSION_FILE"

    rm -rf "$tmpd" "$archive"

    clear_screen; print_logo
    if [[ -x "$FRPS_BIN" && -x "$FRPC_BIN" ]] && "$FRPS_BIN" --version >/dev/null 2>&1; then
        msg_ok "FRP v$("$FRPS_BIN" --version 2>/dev/null) installed successfully"
    else
        msg_err "Installation incomplete (binary did not run)"
    fi
    press_enter
}

# ─────────────────────────── Add Iran (Server) ───────────────────────────
add_tunnel_iran() {
    clear_screen; print_logo
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    print_color "CYAN"   "  Add Iran Tunnel  (frps / Server)"
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    print_color "OLIVE"  "  Run this on the IRAN server. Users connect here."
    echo ""

    print_color "PINK" "Tunnel name:"
    read -r tunnel_name
    [[ -z "$tunnel_name" ]] && { msg_err "Tunnel name is required"; sleep 2; return; }

    ask_protocol
    [[ -z "$PROTO" ]] && { msg_err "Invalid protocol"; sleep 2; return; }
    local protocol="$PROTO" proto_label="$PROTO_LABEL" mux="$PROTO_MUX" proto_tls="$PROTO_TLS"
    ask_tls_certs "iran"
    local tls_cert="$TLS_CERT" tls_key="$TLS_KEY" tls_ca="$TLS_CA"

    local tunnel_port
    while true; do
        echo ""
        print_color "YELLOW" "Tunnel Port (the port Kharej will connect to):"
        read -r tunnel_port
        validate_port "$tunnel_port" || { msg_err "Invalid port"; sleep 1; continue; }
        if [[ -f "/etc/systemd/system/frp-iran-${tunnel_port}.service" || -f "/etc/systemd/system/frp-kharej-${tunnel_port}.service" ]]; then
            msg_err "A tunnel on port $tunnel_port already exists"; sleep 1; continue
        fi
        check_port_in_use "$tunnel_port" && { msg_err "Port $tunnel_port is already in use"; sleep 1; continue; }
        break
    done

    echo ""
    print_color "ORANGE" "Token (leave empty to auto-generate):"
    read -r token
    if [[ -z "$token" ]]; then
        token=$(generate_token)
        msg_ok "Generated token: $token"
        sleep 1
    fi

    local dash_port dash_pass
    dash_port=$(get_next_port 7500)
    dash_pass=$(generate_pass)

    local config_name="frp-iran-${tunnel_port}"
    local config_file="${CONFIG_DIR}/${config_name}.toml"
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"

    {
        echo "bindPort = ${tunnel_port}"
        [[ "$protocol" == "kcp"  ]] && echo "kcpBindPort = ${tunnel_port}"
        [[ "$protocol" == "quic" ]] && echo "quicBindPort = ${tunnel_port}"
        echo ""
        echo "auth.method = \"token\""
        echo "auth.token = \"${token}\""
        echo ""
        echo "transport.maxPoolCount = 100"
        echo "transport.heartbeatTimeout = 90"
        echo "transport.tcpKeepalive = 7200"
        echo "transport.tcpMux = ${mux}"
        if [[ "$proto_tls" != "true" ]]; then
            echo "transport.tls.force = false"
        fi
        if [[ "$proto_tls" == "true" && -n "$tls_cert" ]]; then
            echo "transport.tls.certFile = \"${tls_cert}\""
            echo "transport.tls.keyFile = \"${tls_key}\""
            if [[ -n "$tls_ca" ]]; then
                echo "transport.tls.trustedCaFile = \"${tls_ca}\""
                echo "transport.tls.force = true"
            fi
        fi
        echo ""
        echo "webServer.addr = \"0.0.0.0\""
        echo "webServer.port = ${dash_port}"
        echo "webServer.user = \"admin\""
        echo "webServer.password = \"${dash_pass}\""
        echo ""
        echo "log.to = \"${LOG_DIR}/${config_name}.log\""
        echo "log.level = \"info\""
        echo "log.maxDays = 3"
    } > "$config_file"

    create_service "$config_name" "$FRPS_BIN" "$config_file" "$tunnel_name"
    apply_sysctl
    systemctl daemon-reload
    systemctl enable "${config_name}.service" >/dev/null 2>&1
    systemctl start  "${config_name}.service"

    save_tunnel_info "$config_name" "$tunnel_name" "iran" "$tunnel_port" "0.0.0.0" "$proto_label"

    clear_screen; print_logo
    if systemctl is-active --quiet "${config_name}.service"; then
        msg_ok "Iran server created and started"
        echo ""
        print_color "CYAN"   "  Name        : ${tunnel_name}"
        print_color "BLUE"   "  Protocol    : ${proto_label}"
        print_color "YELLOW" "  Tunnel Port : ${tunnel_port}"
        print_color "PINK"   "  Token       : ${token}"
        print_color "TEAL"   "  Dashboard   : http://<IRAN-IP>:${dash_port}  (admin / ${dash_pass})"
        echo ""
        print_color "OLIVE"  "  → Use this Token + Tunnel Port on the Kharej side."
    else
        msg_err "Failed to start server"
        print_color "YELLOW" "  Check: journalctl -u ${config_name}"
    fi
    press_enter
}

# ─────────────────────────── Add Kharej (Client) ───────────────────────────
add_tunnel_kharej() {
    clear_screen; print_logo
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    print_color "CYAN"   "  Add Kharej Tunnel  (frpc / Client)"
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    print_color "OLIVE"  "  Run this on the KHAREJ server where your services live."
    echo ""

    print_color "PINK" "Tunnel name:"
    read -r tunnel_name
    [[ -z "$tunnel_name" ]] && { msg_err "Tunnel name is required"; sleep 2; return; }

    ask_protocol
    [[ -z "$PROTO" ]] && { msg_err "Invalid protocol"; sleep 2; return; }
    local protocol="$PROTO" proto_label="$PROTO_LABEL" mux="$PROTO_MUX" proto_tls="$PROTO_TLS"
    ask_tls_certs "kharej"
    local tls_cert="$TLS_CERT" tls_key="$TLS_KEY" tls_ca="$TLS_CA" tls_sni="$TLS_SERVERNAME"

    echo ""
    print_color "YELLOW" "Iran IP or Domain (CDN domain is allowed):"
    read -r iran_ip
    validate_host "$iran_ip" || { msg_err "Invalid IP or domain"; sleep 2; return; }

    echo ""
    print_color "ORANGE" "Tunnel Port (same as Iran server):"
    read -r tunnel_port
    validate_port "$tunnel_port" || { msg_err "Invalid port"; sleep 2; return; }

    echo ""
    print_color "BLUE" "Token (from Iran server):"
    read -r token
    [[ -z "$token" ]] && { msg_err "Token is required"; sleep 2; return; }

    echo ""
    print_color "PURPLE" "VPN Config Port(s) to expose, comma separated (e.g. 443,8443):"
    read -r vpn_ports_input

    echo ""
    print_color "CYAN" "Port type:"
    print_color "PINK"   "  [1] TCP"
    print_color "YELLOW" "  [2] UDP"
    print_color "ORANGE" "  [3] Both"
    print_color "BLUE" "Select (1-3):"
    read -r pt
    local types=()
    case "$pt" in
        1) types=("tcp") ;;
        2) types=("udp") ;;
        3) types=("tcp" "udp") ;;
        *) types=("tcp") ;;
    esac

    # Build proxies block
    local proxies="" valid=0
    IFS=',' read -ra parr <<< "$vpn_ports_input"
    for raw in "${parr[@]}"; do
        local p
        p=$(echo "$raw" | xargs)
        validate_port "$p" || continue
        valid=1
        for ty in "${types[@]}"; do
            proxies+=$'\n'"[[proxies]]"$'\n'
            proxies+="name = \"${tunnel_name}-${ty}-${p}\""$'\n'
            proxies+="type = \"${ty}\""$'\n'
            proxies+="localIP = \"127.0.0.1\""$'\n'
            proxies+="localPort = ${p}"$'\n'
            proxies+="remotePort = ${p}"$'\n'
        done
    done

    [[ "$valid" -eq 0 ]] && { msg_err "No valid VPN ports provided"; sleep 2; return; }

    local remote_addr="$iran_ip"
    local config_name="frp-kharej-${tunnel_port}"
    local config_file="${CONFIG_DIR}/${config_name}.toml"
    [[ -f "$config_file" ]] && { msg_err "A Kharej tunnel on port $tunnel_port already exists"; sleep 2; return; }
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"

    {
        echo "serverAddr = \"${remote_addr}\""
        echo "serverPort = ${tunnel_port}"
        echo ""
        echo "auth.method = \"token\""
        echo "auth.token = \"${token}\""
        echo ""
        echo "transport.protocol = \"${protocol}\""
        echo "transport.poolCount = 10"
        echo "transport.tcpMux = ${mux}"
        echo "transport.dialServerTimeout = 10"
        echo "transport.dialServerKeepalive = 7200"
        echo "transport.heartbeatInterval = 30"
        echo "transport.heartbeatTimeout = 90"
        if [[ "$proto_tls" == "true" ]]; then
            echo "transport.tls.enable = true"
            if [[ -n "$tls_cert" ]]; then
                echo "transport.tls.certFile = \"${tls_cert}\""
                echo "transport.tls.keyFile = \"${tls_key}\""
            fi
            [[ -n "$tls_ca" ]]  && echo "transport.tls.trustedCaFile = \"${tls_ca}\""
            [[ -n "$tls_sni" ]] && echo "transport.tls.serverName = \"${tls_sni}\""
        else
            echo "transport.tls.enable = false"
        fi
        echo ""
        echo "log.to = \"${LOG_DIR}/${config_name}.log\""
        echo "log.level = \"info\""
        echo "log.maxDays = 3"
        echo "$proxies"
    } > "$config_file"

    create_service "$config_name" "$FRPC_BIN" "$config_file" "$tunnel_name"
    apply_sysctl
    systemctl daemon-reload
    systemctl enable "${config_name}.service" >/dev/null 2>&1
    systemctl start  "${config_name}.service"

    save_tunnel_info "$config_name" "$tunnel_name" "kharej" "$tunnel_port" "$iran_ip" "$proto_label"

    clear_screen; print_logo
    if systemctl is-active --quiet "${config_name}.service"; then
        msg_ok "Kharej client created and started"
        echo ""
        print_color "CYAN"   "  Name        : ${tunnel_name}"
        print_color "BLUE"   "  Protocol    : ${proto_label}"
        print_color "YELLOW" "  Iran        : ${iran_ip}:${tunnel_port}"
        print_color "PINK"   "  VPN Ports   : ${vpn_ports_input}  (${types[*]})"
        echo ""
        print_color "OLIVE"  "  → These ports are now open on the Iran side."
    else
        msg_err "Failed to start client"
        print_color "YELLOW" "  Check: journalctl -u ${config_name}"
    fi
    press_enter
}

create_service() {
    local name="$1" bin="$2" cfg="$3" desc="$4"
    cat > "/etc/systemd/system/${name}.service" << EOF
[Unit]
Description=GOLDFRP Tunnel - ${desc}
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${bin} -c ${cfg}
Restart=always
RestartSec=5
LimitNOFILE=1048576
LimitNPROC=512
LimitCORE=infinity
TasksMax=infinity
Nice=-10

[Install]
WantedBy=multi-user.target
EOF
}

add_tunnel_menu() {
    while true; do
        clear_screen; print_logo
        print_color "ORANGE" "═══════════════════════════════════════════════════"
        print_color "CYAN"   "  Add Tunnel"
        print_color "ORANGE" "═══════════════════════════════════════════════════"
        echo ""
        print_color "PINK"  "  [1] Iran    (Server / frps)"
        print_color "CYAN"  "  [2] Kharej  (Client / frpc)"
        print_color "OLIVE" "  [0] Back"
        echo ""
        print_color "YELLOW" "Select option:"
        read -r choice
        case "$choice" in
            1) add_tunnel_iran ;;
            2) add_tunnel_kharej ;;
            0) return ;;
            *) msg_err "Invalid option"; sleep 1 ;;
        esac
    done
}

# ─────────────────────────── Manage ───────────────────────────
manage_tunnel_menu() {
    while true; do
        clear_screen; print_logo
        print_color "ORANGE" "═══════════════════════════════════════════════════"
        print_color "CYAN"   "  Manage Tunnels"
        print_color "ORANGE" "═══════════════════════════════════════════════════"
        echo ""

        local tunnels=()
        read -ra tunnels <<< "$(list_tunnels)"
        if [[ ${#tunnels[@]} -eq 0 ]]; then
            msg_warn "No tunnels found"; press_enter; return
        fi

        local i=1
        for t in "${tunnels[@]}"; do
            local info name port dest
            info=$(get_tunnel_info "$t")
            name=$(echo "$info" | jq -r '.name // "Unknown"' 2>/dev/null)
            port=$(echo "$info" | jq -r '.port // "N/A"' 2>/dev/null)
            dest=$(echo "$info" | jq -r '.destination // "N/A"' 2>/dev/null)
            [[ -z "$name" || "$name" == "null" ]] && name="Unknown"
            if systemctl is-active --quiet "$t"; then
                print_color "GREEN" "  [$i] ${name} | Port: ${port} | Dest: ${dest}  ● Active"
            else
                print_color "RED"   "  [$i] ${name} | Port: ${port} | Dest: ${dest}  ○ Inactive"
            fi
            ((i++))
        done
        print_color "OLIVE" "  [0] Back"
        echo ""
        print_color "YELLOW" "Select tunnel:"
        read -r choice

        [[ "$choice" == "0" ]] && return
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#tunnels[@]} )); then
            manage_tunnel_actions "${tunnels[$((choice-1))]}"
        else
            msg_err "Invalid selection"; sleep 1
        fi
    done
}

manage_tunnel_actions() {
    local tunnel="$1"
    while true; do
        clear_screen; print_logo
        print_color "ORANGE" "═══════════════════════════════════════════════════"
        print_color "CYAN"   "  Manage: ${tunnel}"
        print_color "ORANGE" "═══════════════════════════════════════════════════"
        echo ""
        if systemctl is-active --quiet "$tunnel"; then
            print_color "GREEN" "  Status: ● Active"
        else
            print_color "RED"   "  Status: ○ Inactive"
        fi
        echo ""
        print_color "PINK"   "  [1] Start"
        print_color "CYAN"   "  [2] Stop"
        print_color "YELLOW" "  [3] Restart"
        print_color "ORANGE" "  [4] Edit"
        print_color "PURPLE" "  [5] View Config"
        print_color "TEAL"   "  [6] Live Logs"
        print_color "BLUE"   "  [7] Delete"
        print_color "OLIVE"  "  [0] Back"
        echo ""
        print_color "PINK" "Select action:"
        read -r action
        case "$action" in
            1) systemctl start "$tunnel"
               clear_screen; print_logo
               systemctl is-active --quiet "$tunnel" && msg_ok "Tunnel started" || msg_err "Failed to start"
               sleep 2 ;;
            2) systemctl stop "$tunnel"
               clear_screen; print_logo; msg_warn "Tunnel stopped"; sleep 2 ;;
            3) systemctl restart "$tunnel"
               clear_screen; print_logo
               systemctl is-active --quiet "$tunnel" && msg_ok "Tunnel restarted" || msg_err "Failed to restart"
               sleep 2 ;;
            4) edit_tunnel "$tunnel" ;;
            5) view_config "$tunnel" ;;
            6) live_logs "$tunnel" ;;
            7) delete_tunnel "$tunnel"; return ;;
            0) return ;;
            *) msg_err "Invalid action"; sleep 1 ;;
        esac
    done
}

view_config() {
    local cfg="${CONFIG_DIR}/${1}.toml"
    clear_screen; print_logo
    print_color "CYAN" "═══════════════════════════════════════════════════"
    print_color "YELLOW" "  Config: ${1}"
    print_color "CYAN" "═══════════════════════════════════════════════════"
    echo ""
    if [[ -f "$cfg" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^\[\[proxies\]\] ]]; then
                print_color "ORANGE" "$line"
            elif [[ "$line" =~ token ]]; then
                print_color "PINK" "$line"
            elif [[ "$line" =~ ^[a-zA-Z] ]]; then
                print_color "TEAL" "$line"
            else
                print_color "OLIVE" "$line"
            fi
        done < "$cfg"
    else
        msg_err "Config file not found"
    fi
    press_enter
}

edit_tunnel() {
    local tunnel="$1"
    local config_file="${CONFIG_DIR}/${tunnel}.toml"
    [[ -f "$config_file" ]] || { msg_err "Config file not found"; press_enter; return; }

    clear_screen; print_logo
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    print_color "CYAN"   "  Edit: ${tunnel}"
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    echo ""

    if [[ "$tunnel" == *"iran"* ]]; then
        print_color "PINK"   "  [1] Token"
        print_color "CYAN"   "  [2] Dashboard Port"
        print_color "OLIVE"  "  [0] Cancel"
        echo ""
        print_color "ORANGE" "What to edit:"
        read -r ec
        case "$ec" in
            1) echo ""; print_color "PINK" "New Token:"; read -r nt
               [[ -n "$nt" ]] && { sed -i "s|^auth.token = .*|auth.token = \"${nt}\"|" "$config_file"; systemctl restart "$tunnel"; msg_ok "Token updated"; sleep 2; } ;;
            2) echo ""; print_color "CYAN" "New Dashboard Port:"; read -r np
               validate_port "$np" && { sed -i "s|^webServer.port = .*|webServer.port = ${np}|" "$config_file"; systemctl restart "$tunnel"; msg_ok "Dashboard port updated"; sleep 2; } || { msg_err "Invalid port"; sleep 2; } ;;
        esac
    else
        print_color "PINK"   "  [1] Iran IP + Tunnel Port"
        print_color "CYAN"   "  [2] Token"
        print_color "YELLOW" "  [3] VPN Config Ports"
        print_color "OLIVE"  "  [0] Cancel"
        echo ""
        print_color "ORANGE" "What to edit:"
        read -r ec
        case "$ec" in
            1) echo ""; print_color "PINK" "New Iran IP or Domain:"; read -r ni
               echo ""; print_color "CYAN" "New Tunnel Port:"; read -r np
               if validate_host "$ni" && validate_port "$np"; then
                   sed -i "s|^serverAddr = .*|serverAddr = \"${ni}\"|" "$config_file"
                   sed -i "s|^serverPort = .*|serverPort = ${np}|" "$config_file"
                   systemctl restart "$tunnel"
                   local info name proto
                   info=$(get_tunnel_info "$tunnel")
                   name=$(echo "$info" | jq -r '.name // "Unknown"')
                   proto=$(echo "$info" | jq -r '.protocol // "tcp"')
                   save_tunnel_info "$tunnel" "$name" "kharej" "$np" "$ni" "$proto"
                   msg_ok "Remote address updated"; sleep 2
               else msg_err "Invalid IP or port"; sleep 2; fi ;;
            2) echo ""; print_color "CYAN" "New Token:"; read -r nt
               [[ -n "$nt" ]] && { sed -i "s|^auth.token = .*|auth.token = \"${nt}\"|" "$config_file"; systemctl restart "$tunnel"; msg_ok "Token updated"; sleep 2; } ;;
            3) edit_kharej_ports "$tunnel" "$config_file" ;;
        esac
    fi
    press_enter
}

edit_kharej_ports() {
    local tunnel="$1" config_file="$2"
    echo ""
    print_color "YELLOW" "New VPN Config Ports (comma separated):"
    read -r new_ports
    echo ""
    print_color "CYAN" "Port type:  [1] TCP   [2] UDP   [3] Both"
    read -r pt
    local types=()
    case "$pt" in
        1) types=("tcp") ;;
        2) types=("udp") ;;
        3) types=("tcp" "udp") ;;
        *) types=("tcp") ;;
    esac

    local info name
    info=$(get_tunnel_info "$tunnel")
    name=$(echo "$info" | jq -r '.name // "tunnel"')

    # Strip old proxies (everything from first [[proxies]] onward)
    sed -i '/^\[\[proxies\]\]/,$d' "$config_file"

    local valid=0
    {
        IFS=',' read -ra parr <<< "$new_ports"
        for raw in "${parr[@]}"; do
            local p; p=$(echo "$raw" | xargs)
            validate_port "$p" || continue
            valid=1
            for ty in "${types[@]}"; do
                echo ""
                echo "[[proxies]]"
                echo "name = \"${name}-${ty}-${p}\""
                echo "type = \"${ty}\""
                echo "localIP = \"127.0.0.1\""
                echo "localPort = ${p}"
                echo "remotePort = ${p}"
            done
        done
    } >> "$config_file"

    if [[ "$valid" -eq 1 ]]; then
        systemctl restart "$tunnel"
        msg_ok "VPN ports updated"; sleep 2
    else
        msg_err "No valid ports provided"; sleep 2
    fi
}

delete_tunnel() {
    local tunnel="$1"
    clear_screen; print_logo
    msg_warn "Delete tunnel '${tunnel}' ? (yes/no)"
    read -r confirm
    if [[ "$confirm" == "yes" ]]; then
        systemctl stop "$tunnel" 2>/dev/null
        systemctl disable "$tunnel" 2>/dev/null
        rm -f "/etc/systemd/system/${tunnel}.service"
        rm -f "${CONFIG_DIR}/${tunnel}.toml"
        rm -f "${LOG_DIR}/${tunnel}.log"
        delete_tunnel_info "$tunnel"
        systemctl daemon-reload
        clear_screen; print_logo
        msg_ok "Tunnel deleted"
    else
        clear_screen; print_logo
        msg_warn "Deletion cancelled"
    fi
    press_enter
}

# ─────────────────────────── Logs ───────────────────────────
colorize_log() {
    while IFS= read -r line; do
        local low="${line,,}"
        if [[ "$low" == *error* || "$low" == *"fail"* || "$low" == *"refused"* || "$low" == *"cannot"* ]]; then
            print_color "RED" "$line"
        elif [[ "$low" == *warn* || "$low" == *timeout* || "$low" == *retry* || "$low" == *reconnect* ]]; then
            print_color "YELLOW" "$line"
        elif [[ "$low" == *"success"* || "$low" == *"start"* || "$low" == *"login"* || "$low" == *"connected"* || "$low" == *"running"* ]]; then
            print_color "GREEN" "$line"
        else
            print_color "CYAN" "$line"
        fi
    done
}

live_logs() {
    local tunnel="$1"
    clear_screen
    print_color "CYAN" "═══════════════════════════════════════════════════"
    print_color "YELLOW" "  Live Logs: ${tunnel}   (Ctrl+C to stop)"
    print_color "CYAN" "═══════════════════════════════════════════════════"
    echo ""
    trap 'echo' INT
    journalctl -u "$tunnel" -n 30 -f --no-pager 2>/dev/null | colorize_log
    trap - INT
    echo ""
    press_enter
}

show_logs() {
    clear_screen; print_logo
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    print_color "CYAN"   "  Tunnel Logs"
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    echo ""

    local tunnels=()
    read -ra tunnels <<< "$(list_tunnels)"
    if [[ ${#tunnels[@]} -eq 0 ]]; then
        msg_warn "No tunnels found"; press_enter; return
    fi

    local i=1
    for t in "${tunnels[@]}"; do
        local info name
        info=$(get_tunnel_info "$t")
        name=$(echo "$info" | jq -r '.name // "Unknown"' 2>/dev/null)
        [[ -z "$name" || "$name" == "null" ]] && name="Unknown"
        print_color "PINK" "  [$i] ${name} (${t})"
        ((i++))
    done
    print_color "OLIVE" "  [0] Back"
    echo ""
    print_color "YELLOW" "Select tunnel:"
    read -r choice
    [[ "$choice" == "0" ]] && return

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#tunnels[@]} )); then
        local t="${tunnels[$((choice-1))]}"
        clear_screen
        print_color "CYAN" "═══════════════════════════════════════════════════"
        print_color "YELLOW" "  Logs: ${t} (Last 80 lines)"
        print_color "CYAN" "═══════════════════════════════════════════════════"
        echo ""
        local out
        out=$(journalctl -u "$t" -n 80 --no-pager 2>/dev/null)
        if [[ -z "$out" ]]; then
            msg_warn "No logs available"
        else
            echo "$out" | colorize_log
        fi
        press_enter
    else
        msg_err "Invalid selection"; sleep 1
    fi
}

# ─────────────────────────── Status ───────────────────────────
show_status() {
    clear_screen; print_logo
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    print_color "CYAN"   "  Tunnel Status"
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    echo ""

    local tunnels=()
    read -ra tunnels <<< "$(list_tunnels)"
    if [[ ${#tunnels[@]} -eq 0 ]]; then
        msg_warn "No tunnels found"; press_enter; return
    fi

    local active=0 total=0
    for t in "${tunnels[@]}"; do
        ((total++))
        local info name role port dest proto
        info=$(get_tunnel_info "$t")
        name=$(echo "$info" | jq -r '.name // "Unknown"' 2>/dev/null)
        role=$(echo "$info" | jq -r '.role // "?"' 2>/dev/null)
        port=$(echo "$info" | jq -r '.port // "N/A"' 2>/dev/null)
        dest=$(echo "$info" | jq -r '.destination // "N/A"' 2>/dev/null)
        proto=$(echo "$info" | jq -r '.protocol // "?"' 2>/dev/null)
        [[ -z "$name" || "$name" == "null" ]] && name="Unknown"

        if systemctl is-active --quiet "$t"; then
            ((active++))
            print_color "GREEN" "  ● ${name} [${role}/${proto}] | Port: ${port} | Dest: ${dest}"
        else
            print_color "RED"   "  ○ ${name} [${role}/${proto}] | Port: ${port} | Dest: ${dest}"
        fi
    done
    echo ""
    if [[ "$active" -eq "$total" ]]; then
        msg_ok "All tunnels active (${active}/${total})"
    elif [[ "$active" -eq 0 ]]; then
        msg_err "No active tunnels (0/${total})"
    else
        msg_warn "Some tunnels down (${active}/${total} active)"
    fi
    press_enter
}

# ─────────────────────────── Uninstall ───────────────────────────
uninstall_frp() {
    clear_screen; print_logo
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    print_color "CYAN"   "  Uninstall FRP"
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    echo ""
    msg_warn "This removes ALL tunnels and the FRP installation"
    print_color "YELLOW" "Are you sure? (yes/no)"
    read -r confirm
    [[ "$confirm" != "yes" ]] && { clear_screen; print_logo; msg_warn "Uninstall cancelled"; press_enter; return; }

    local tunnels=()
    read -ra tunnels <<< "$(list_tunnels)"
    for t in "${tunnels[@]}"; do
        systemctl stop "$t" 2>/dev/null
        systemctl disable "$t" 2>/dev/null
        rm -f "/etc/systemd/system/${t}.service"
    done

    rm -f "$FRPS_BIN" "$FRPC_BIN"
    rm -rf "$CONFIG_DIR" "$LOG_DIR"
    rm -f "$TUNNEL_DB"
    systemctl daemon-reload

    clear_screen; print_logo
    msg_ok "FRP uninstalled successfully"
    press_enter
}

# ─────────────────────────── CDN / Nginx ───────────────────────────
generate_nginx() {
    clear_screen; print_logo
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    print_color "CYAN"   "  CDN Setup  (Nginx reverse proxy for frps)"
    print_color "ORANGE" "═══════════════════════════════════════════════════"
    print_color "OLIVE"  "  Run on the IRAN server. Puts frps behind a domain on 443"
    print_color "OLIVE"  "  so Cloudflare (proxied / orange cloud) can forward WebSocket."
    echo ""

    if ! command -v nginx &>/dev/null; then
        print_color "PINK" "→ Installing nginx..."
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y nginx >/dev/null 2>&1
        if ! command -v nginx &>/dev/null; then
            msg_err "Failed to install nginx"; press_enter; return
        fi
    fi

    print_color "PINK" "Domain (must point to this server, e.g. tunnel.example.com):"
    read -r domain
    validate_host "$domain" || { msg_err "Invalid domain"; sleep 2; return; }

    # pick local frps port
    local iran_tunnels=()
    for s in /etc/systemd/system/frp-iran-*.service; do
        [[ -f "$s" ]] && iran_tunnels+=("$(basename "$s" .service)")
    done

    local frps_port=""
    if [[ ${#iran_tunnels[@]} -gt 0 ]]; then
        echo ""
        print_color "CYAN" "Existing Iran (frps) tunnels:"
        local i=1
        for t in "${iran_tunnels[@]}"; do
            print_color "TEAL" "  [$i] ${t#frp-iran-}  (${t})"
            ((i++))
        done
        print_color "OLIVE" "  [m] Enter port manually"
        echo ""
        print_color "YELLOW" "Select frps to expose:"
        read -r sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#iran_tunnels[@]} )); then
            frps_port="${iran_tunnels[$((sel-1))]#frp-iran-}"
        fi
    fi
    if [[ -z "$frps_port" ]]; then
        echo ""
        print_color "YELLOW" "Local frps bind port:"
        read -r frps_port
    fi
    validate_port "$frps_port" || { msg_err "Invalid port"; sleep 2; return; }

    echo ""
    print_color "BLUE" "TLS certificate path (.crt/.pem) — leave empty for Let's Encrypt hint:"
    read -r cert
    local key=""
    if [[ -n "$cert" ]]; then
        print_color "BLUE" "TLS private key path (.key):"
        read -r key
    fi

    local listen_block ssl_block
    if [[ -n "$cert" && -n "$key" ]]; then
        listen_block="listen 443 ssl;"
        ssl_block="ssl_certificate ${cert};
    ssl_certificate_key ${key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;"
    else
        # No cert provided: serve plain on 80 (Cloudflare can still do Flexible TLS),
        # and print certbot guidance.
        listen_block="listen 80;"
        ssl_block="# No local TLS. For full encryption obtain a cert:
    #   apt install certbot python3-certbot-nginx
    #   certbot --nginx -d ${domain}"
    fi

    local conf="/etc/nginx/conf.d/frp-${domain}.conf"
    cat > "$conf" << EOF
# GOLDFRP - Nginx reverse proxy for frps (WebSocket transport)
server {
    ${listen_block}
    server_name ${domain};

    ${ssl_block}

    # WebSocket upgrade for frpc websocket transport
    location / {
        proxy_pass http://127.0.0.1:${frps_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }
}
EOF

    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx
        clear_screen; print_logo
        msg_ok "Nginx config created and reloaded"
        echo ""
        print_color "CYAN"   "  Config      : ${conf}"
        print_color "YELLOW" "  Domain      : ${domain}"
        print_color "TEAL"   "  Proxies to  : 127.0.0.1:${frps_port}  (frps)"
        echo ""
        print_color "OLIVE"  "  On Kharej (frpc) use:"
        print_color "PINK"   "    Protocol = WSMUX   (Nginx/CDN handle TLS)"
        print_color "PINK"   "    Iran     = ${domain}"
        print_color "PINK"   "    Port     = 443   (Cloudflare-proxied)"
        echo ""
        print_color "OLIVE"  "  Cloudflare: set DNS A record (orange cloud ON),"
        print_color "OLIVE"  "  SSL mode Full, and WebSockets enabled (default)."
    else
        msg_err "nginx -t failed — config not applied"
        print_color "YELLOW" "  Run 'nginx -t' to see the error. Config left at: ${conf}"
        rm -f "$conf"
    fi
    press_enter
}

# ─────────────────────────── Main ───────────────────────────
main_menu() {
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y jq curl wget tar openssl >/dev/null 2>&1
    fi
    init_tunnel_db

    while true; do
        clear_screen; print_logo
        print_color "ORANGE" "═══════════════════════════════════════════════════"
        print_color "CYAN"   "  Main Menu"
        print_color "ORANGE" "═══════════════════════════════════════════════════"
        echo ""
        print_color "PINK"   "  [1] Install / Update FRP"
        print_color "CYAN"   "  [2] Add Tunnel"
        print_color "YELLOW" "  [3] Manage Tunnels"
        print_color "ORANGE" "  [4] Logs"
        print_color "BLUE"   "  [5] Tunnel Status"
        print_color "TEAL"   "  [6] CDN Setup (Nginx for frps)"
        print_color "PURPLE" "  [7] Uninstall"
        print_color "RED"    "  [8] Exit"
        echo ""
        print_color "CYAN" "Select option:"
        read -r choice

        case "$choice" in
            1) install_frp ;;
            2) if [[ ! -f "$FRPS_BIN" ]]; then clear_screen; print_logo; msg_err "Please install FRP first"; sleep 2; else add_tunnel_menu; fi ;;
            3) if [[ ! -f "$FRPS_BIN" ]]; then clear_screen; print_logo; msg_err "Please install FRP first"; sleep 2; else manage_tunnel_menu; fi ;;
            4) if [[ ! -f "$FRPS_BIN" ]]; then clear_screen; print_logo; msg_err "Please install FRP first"; sleep 2; else show_logs; fi ;;
            5) if [[ ! -f "$FRPS_BIN" ]]; then clear_screen; print_logo; msg_err "Please install FRP first"; sleep 2; else show_status; fi ;;
            6) generate_nginx ;;
            7) uninstall_frp ;;
            8) clear_screen; print_color "CYAN" "Thank you for using GOLDFRP!"; print_color "YELLOW" "Goodbye!"; echo ""; exit 0 ;;
            *) msg_err "Invalid option"; sleep 1 ;;
        esac
    done
}

check_root
main_menu
