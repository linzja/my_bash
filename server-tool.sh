#!/usr/bin/env bash
#
# VPS 小工具：/swapfile 管理 + 基于 nftables 的端口流量监控
# 支持 Debian / Ubuntu / Alpine，需 root 权限。

set -Eeuo pipefail
umask 077

VERSION="1.4.0"
APP_NAME="port-traffic-monitor"
STATE_DIR="/etc/${APP_NAME}"
CONFIG_FILE="${STATE_DIR}/ports.conf"
SNAPSHOT_FILE="${STATE_DIR}/traffic.snapshot"
LOCK_FILE="/run/${APP_NAME}.lock"
NFT_FAMILY="inet"
NFT_TABLE="ptm_traffic"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
TIMER_FILE="/etc/systemd/system/${APP_NAME}-snapshot.timer"
SNAPSHOT_SERVICE_FILE="/etc/systemd/system/${APP_NAME}-snapshot.service"
INSTALL_PATH="/usr/local/sbin/server-tool"
SYSCTL_FILE="/etc/sysctl.d/99-server-tool-bbr.conf"
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/server-tool.local"
FAIL2BAN_WHITELIST="${STATE_DIR}/fail2ban-whitelist.conf"
SB_INSTALL_PATH="/usr/local/bin/sb"
SB_SCRIPT_URL="https://raw.githubusercontent.com/0xdabiaoge/singbox-lite/main/singbox.sh"
DOCKER_INSTALL_URL="https://get.docker.com"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

info() { printf '%s[信息]%s %s\n' "$CYAN" "$NC" "$*"; }
ok() { printf '%s[成功]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die() { printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

require_root() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || die "请使用 root 权限运行：sudo bash $0"
}

require_linux() {
    [ "$(uname -s)" = "Linux" ] || die "此脚本仅支持 Linux。"
}

ensure_state() {
    install -d -m 700 "$STATE_DIR"
    touch "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

lock_operation() {
    if command -v flock >/dev/null 2>&1; then
        exec {OPERATION_LOCK_FD}>"$LOCK_FILE"
        flock -x "$OPERATION_LOCK_FD"
        OPERATION_LOCK_DIR=""
    else
        OPERATION_LOCK_FD=""
        OPERATION_LOCK_DIR="${LOCK_FILE}.d"
        while ! mkdir "$OPERATION_LOCK_DIR" 2>/dev/null; do
            local owner=""
            owner=$(cat "${OPERATION_LOCK_DIR}/pid" 2>/dev/null || true)
            if ! [[ "$owner" =~ ^[0-9]+$ ]] || ! kill -0 "$owner" 2>/dev/null; then
                rm -f "${OPERATION_LOCK_DIR}/pid"
                rmdir "$OPERATION_LOCK_DIR" 2>/dev/null || true
                continue
            fi
            sleep 1
        done
        printf '%s\n' "$$" > "${OPERATION_LOCK_DIR}/pid"
    fi
}

unlock_operation() {
    if [ -n "${OPERATION_LOCK_FD:-}" ]; then
        flock -u "$OPERATION_LOCK_FD" 2>/dev/null || true
        eval "exec ${OPERATION_LOCK_FD}>&-"
        OPERATION_LOCK_FD=""
    fi
    if [ -n "${OPERATION_LOCK_DIR:-}" ]; then
        rm -f "${OPERATION_LOCK_DIR}/pid"
        rmdir "$OPERATION_LOCK_DIR" 2>/dev/null || true
        OPERATION_LOCK_DIR=""
    fi
}

sync_installed_script() {
    local self
    self=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || printf '%s' "$0")
    [ "$self" = "$INSTALL_PATH" ] && return 0
    if [ -f "$self" ]; then
        install -d -m 755 "$(dirname "$INSTALL_PATH")"
        install -m 700 "$self" "${INSTALL_PATH}.new"
        mv "${INSTALL_PATH}.new" "$INSTALL_PATH"
    fi
}

install_nftables() {
    command -v nft >/dev/null 2>&1 && return 0
    info "正在安装 nftables..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y nftables
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-progress nftables
    else
        die "未找到 apt-get 或 apk，请先手动安装 nftables。"
    fi
    command -v nft >/dev/null 2>&1 || die "nftables 安装失败。"
}

install_packages() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-progress "$@"
    else
        die "未找到 apt-get 或 apk，无法自动安装软件包。"
    fi
}

sb_install() {
    local tmp="${SB_INSTALL_PATH}.new.$$"
    local downloaded=0
    install -d -m 755 "$(dirname "$SB_INSTALL_PATH")"
    info "正在下载 singbox-lite 管理脚本..."
    if command -v curl >/dev/null 2>&1; then
        curl -LfsS "$SB_SCRIPT_URL" -o "$tmp" && downloaded=1
    fi
    if [ "$downloaded" -eq 0 ] && command -v wget >/dev/null 2>&1; then
        wget -q "$SB_SCRIPT_URL" -O "$tmp" && downloaded=1
    fi
    if [ "$downloaded" -eq 0 ]; then
        rm -f "$tmp"
        command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 ||
            die "未找到 curl 或 wget，请先安装其中一个下载工具。"
        die "使用 curl/wget 下载 sb 失败。"
    fi
    [ -s "$tmp" ] || {
        rm -f "$tmp"
        die "下载的 sb 脚本为空。"
    }
    head -n 1 "$tmp" | grep -qE '^#!.*(ba)?sh' || {
        rm -f "$tmp"
        die "下载内容不像 Shell 脚本，拒绝安装。"
    }
    chmod 755 "$tmp"
    mv "$tmp" "$SB_INSTALL_PATH"
    ok "sb 已安装到 ${SB_INSTALL_PATH}，正在启动..."
    "$SB_INSTALL_PATH"
}

sb_run() {
    [ -x "$SB_INSTALL_PATH" ] || die "尚未安装 sb，请先执行：$0 sb install"
    "$SB_INSTALL_PATH"
}

docker_start_enable() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl enable --now docker
    elif command -v rc-update >/dev/null 2>&1; then
        rc-update add docker default >/dev/null 2>&1 || true
        rc-service docker restart
    else
        die "Docker 已安装，但未找到 systemd 或 OpenRC，无法管理 Docker 服务。"
    fi
}

docker_status() {
    command -v docker >/dev/null 2>&1 || die "Docker 尚未安装。"
    docker --version
    docker compose version 2>/dev/null || warn "未检测到 Docker Compose 插件。"
    if docker info >/dev/null 2>&1; then
        ok "Docker daemon 正在运行。"
    else
        warn "Docker 命令已安装，但 daemon 未运行或当前用户无权访问。"
        return 1
    fi
}

docker_install() {
    local installer downloaded=0
    if [ -f /etc/alpine-release ]; then
        info "正在通过 apk 安装 Docker..."
        apk add --no-progress docker
        if ! apk add --no-progress docker-cli-compose; then
            warn "Docker 已安装，但 docker-cli-compose 安装失败。"
        fi
    else
        installer=$(mktemp "/tmp/get-docker.XXXXXX")
        info "正在下载 Docker 官方安装脚本..."
        if command -v curl >/dev/null 2>&1; then
            curl -LfsS "$DOCKER_INSTALL_URL" -o "$installer" && downloaded=1
        fi
        if [ "$downloaded" -eq 0 ] && command -v wget >/dev/null 2>&1; then
            wget -q "$DOCKER_INSTALL_URL" -O "$installer" && downloaded=1
        fi
        if [ "$downloaded" -eq 0 ]; then
            rm -f "$installer"
            die "无法使用 curl/wget 下载 Docker 官方安装脚本。"
        fi
        [ -s "$installer" ] && head -n 1 "$installer" | grep -q '^#!' || {
            rm -f "$installer"
            die "Docker 安装脚本为空或格式异常。"
        }
        if ! sh "$installer"; then
            rm -f "$installer"
            die "Docker 官方安装脚本执行失败。"
        fi
        rm -f "$installer"
    fi
    command -v docker >/dev/null 2>&1 || die "Docker 安装完成后仍找不到 docker 命令。"
    docker_start_enable
    ok "Docker 已安装并设置为开机启动。"
    warn "Docker 发布的容器端口可能绕过 UFW 入站规则，请单独检查 Docker 防火墙策略。"
    docker_status
}

bbr_module_version() {
    modinfo tcp_bbr 2>/dev/null | awk '$1 == "version:" {print $2; exit}'
}

bbr_is_v3() {
    [ "$(bbr_module_version)" = "3" ] || uname -r | grep -qiE 'bbr3|bbrv3'
}

bbr_status() {
    local available current qdisc version
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "未知")
    current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    version=$(bbr_module_version)
    echo "内核：$(uname -r)"
    echo "可用拥塞控制：$available"
    echo "当前拥塞控制：$current"
    echo "默认队列：$qdisc"
    if bbr_is_v3; then
        ok "检测到 BBR v3${version:+（模块版本 ${version}）}。"
    elif echo "$available" | grep -qw bbr || modprobe tcp_bbr >/dev/null 2>&1; then
        warn "当前内核仅能确认支持普通 BBR，不能确认是 BBR v3。"
    else
        warn "当前内核没有可用的 BBR。"
    fi
}

bbr_enable() {
    modprobe tcp_bbr >/dev/null 2>&1 || true
    bbr_is_v3 || die "当前运行内核不是 BBR v3；请先执行：$0 bbr install，并重启服务器。"
    cat > "$SYSCTL_FILE" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null
    [ "$(sysctl -n net.ipv4.tcp_congestion_control)" = "bbr" ] ||
        die "BBR 配置已写入，但未能立即启用。"
    ok "BBR v3 + fq 已启用。"
}

bbr_install() {
    local arch
    arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    if ! command -v apt-get >/dev/null 2>&1; then
        die "BBR v3 自动安装目前仅支持 Debian/Ubuntu amd64；Alpine 需要自行安装带 Google BBR v3 补丁的内核。"
    fi
    [ "$arch" = "amd64" ] || [ "$arch" = "x86_64" ] ||
        die "BBR v3 自动安装目前仅支持 amd64。"

    if bbr_is_v3; then
        bbr_enable
        return
    fi

    info "添加 XanMod 官方软件源并安装带 BBR v3 的 x64v2 内核..."
    install_packages ca-certificates curl gnupg
    install -d -m 755 /usr/share/keyrings
    curl -fsSL https://dl.xanmod.org/archive.key |
        gpg --dearmor --yes -o /usr/share/keyrings/xanmod-archive-keyring.gpg
    cat > /etc/apt/sources.list.d/xanmod-release.list <<'EOF'
deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] https://deb.xanmod.org releases main
EOF
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y linux-xanmod-x64v2
    ok "BBR v3 内核已安装。请重启服务器，再执行：$0 bbr enable"
}

detect_ssh_port() {
    local port=""
    if command -v sshd >/dev/null 2>&1; then
        port=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')
    fi
    printf '%s\n' "${port:-22}"
}

ufw_install() {
    local ssh_port
    ssh_port=$(detect_ssh_port)
    install_packages ufw
    ufw allow "${ssh_port}/tcp" comment 'SSH current port' >/dev/null
    [ "$ssh_port" = "22" ] || ufw allow 22/tcp comment 'SSH port 22' >/dev/null
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw --force enable >/dev/null
    if command -v rc-update >/dev/null 2>&1; then
        rc-update add ufw default >/dev/null 2>&1 || true
        rc-service ufw restart >/dev/null 2>&1 || true
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now ufw >/dev/null 2>&1 || true
    fi
    ok "UFW 已安装并启用；已放行 SSH TCP 端口 ${ssh_port} 和 22。"
    ufw status verbose
}

ufw_rule() {
    local action="$1" rule="${2:-}"
    [ -n "$rule" ] || die "请提供规则，例如：22/tcp、443/tcp、8000:8100/tcp。"
    command -v ufw >/dev/null 2>&1 || die "UFW 尚未安装。"
    case "$action" in
        allow|deny|delete) ufw "$action" "$rule" ;;
        *) die "不支持的 UFW 操作：$action" ;;
    esac
}

render_fail2ban_config() {
    local backend="auto" whitelist="127.0.0.1/8 ::1" ip
    command -v journalctl >/dev/null 2>&1 && backend="systemd"
    if [ -f "$FAIL2BAN_WHITELIST" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] && whitelist+=" ${ip}"
        done < "$FAIL2BAN_WHITELIST"
    fi
    install -d -m 755 /etc/fail2ban/jail.d
    cat > "$FAIL2BAN_JAIL" <<EOF
[DEFAULT]
ignoreip = ${whitelist}

[sshd]
enabled = true
port = 22
backend = ${backend}
banaction = ufw
findtime = 10m
maxretry = 5
bantime = 1h
EOF
}

restart_fail2ban() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl enable --now fail2ban
        systemctl restart fail2ban
    elif command -v rc-update >/dev/null 2>&1; then
        rc-update add fail2ban default >/dev/null 2>&1 || true
        rc-service fail2ban restart
    else
        die "Fail2ban 已安装，但未找到 systemd 或 OpenRC。"
    fi
}

fail2ban_install() {
    install_packages fail2ban
    ensure_state
    touch "$FAIL2BAN_WHITELIST"
    chmod 600 "$FAIL2BAN_WHITELIST"
    render_fail2ban_config
    restart_fail2ban
    ok "Fail2ban 已启用：保护 SSH 22，10 分钟失败 5 次封禁 1 小时。"
    fail2ban-client status sshd
}

validate_ip_or_cidr() {
    local value="${1:-}" address prefix
    [[ "$value" != *[[:space:]]* && "$value" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || return 1
    address="${value%%/*}"
    if [[ "$address" == *:* ]]; then
        [[ "$address" =~ [0-9A-Fa-f] && "$address" != *:::* ]] || return 1
        prefix="${value#*/}"
        [ "$prefix" = "$value" ] || [ "$prefix" -le 128 ]
    else
        [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
        local IFS=. octet
        for octet in $address; do
            ((10#$octet <= 255)) || return 1
        done
        prefix="${value#*/}"
        [ "$prefix" = "$value" ] || [ "$prefix" -le 32 ]
    fi
}

fail2ban_whitelist_list() {
    echo "内置白名单：127.0.0.1/8 ::1"
    echo "手动白名单："
    if [ -s "$FAIL2BAN_WHITELIST" ]; then
        nl -ba "$FAIL2BAN_WHITELIST"
    else
        echo "  （空）"
    fi
}

fail2ban_whitelist_add() {
    local ip="${1:-}"
    validate_ip_or_cidr "$ip" || die "IP/CIDR 格式错误：${ip:-空}"
    ensure_state
    touch "$FAIL2BAN_WHITELIST"
    chmod 600 "$FAIL2BAN_WHITELIST"
    if grep -qxF "$ip" "$FAIL2BAN_WHITELIST"; then
        info "${ip} 已在白名单中。"
        return
    fi
    printf '%s\n' "$ip" >> "$FAIL2BAN_WHITELIST"
    if command -v fail2ban-client >/dev/null 2>&1; then
        render_fail2ban_config
        restart_fail2ban
    fi
    ok "已将 ${ip} 加入 Fail2ban 白名单。"
}

fail2ban_whitelist_delete() {
    local ip="${1:-}" tmp
    validate_ip_or_cidr "$ip" || die "IP/CIDR 格式错误：${ip:-空}"
    [ -f "$FAIL2BAN_WHITELIST" ] || die "手动白名单为空。"
    grep -qxF "$ip" "$FAIL2BAN_WHITELIST" || die "${ip} 不在手动白名单中。"
    tmp=$(mktemp "${STATE_DIR}/whitelist.XXXXXX")
    grep -vxF "$ip" "$FAIL2BAN_WHITELIST" > "$tmp" || true
    chmod 600 "$tmp"
    mv "$tmp" "$FAIL2BAN_WHITELIST"
    if command -v fail2ban-client >/dev/null 2>&1; then
        render_fail2ban_config
        restart_fail2ban
    fi
    ok "已从 Fail2ban 白名单删除 ${ip}。"
}

ssh_failed_sources() {
    local limit="${1:-20}" source_file=""
    [[ "$limit" =~ ^[0-9]+$ ]] || die "显示数量必须是整数。"
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --since "24 hours ago" -u ssh.service -u sshd.service --no-pager 2>/dev/null
    else
        for source_file in /var/log/auth.log /var/log/secure /var/log/messages; do
            [ -r "$source_file" ] && break
        done
        [ -r "$source_file" ] || die "找不到可读取的 SSH 认证日志。"
        cat "$source_file"
    fi |
        awk '
            /Failed password|Invalid user|authentication failure/ {
                for (i=1; i<=NF; i++) {
                    value=""
                    if ($i == "from" && i < NF) value=$(i+1)
                    if ($i ~ /^rhost=/) {
                        value=$i
                        sub(/^rhost=/, "", value)
                    }
                    gsub(/^\[/, "", value)
                    gsub(/[\],:;]$/, "", value)
                    if (value ~ /^[0-9][0-9.]*$/ || value ~ /:/) {
                        count[value]++
                        break
                    }
                }
            }
            END {for (ip in count) print count[ip], ip}
        ' |
        sort -rn |
        head -n "$limit" |
        awk 'BEGIN {printf "%-8s %s\n", "次数", "IP 来源"} {printf "%-8s %s\n", $1, $2}'
}

fail2ban_status() {
    command -v fail2ban-client >/dev/null 2>&1 || die "Fail2ban 尚未安装。"
    fail2ban-client status sshd
    echo
    echo "最近 SSH 失败来源（journal 取 24 小时；传统日志取当前文件）："
    ssh_failed_sources 20
}

validate_size_mb() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] || die "Swap 大小必须是正整数（单位 MB）。"
    [ "$1" -ge 128 ] || die "Swap 最小为 128MB。"
}

swap_status() {
    printf '物理内存：'
    free -h | awk '/^Mem:/ {print $3 " / " $2}'
    printf 'Swap：'
    free -h | awk '/^Swap:/ {print $3 " / " $2}'
    if [ -r /proc/swaps ]; then
        echo
        awk 'NR == 1 || NR > 1 {print}' /proc/swaps
    fi
}

swap_recommend_mb() {
    local mem
    mem=$(free -m | awk '/^Mem:/ {print $2}')
    [[ "$mem" =~ ^[0-9]+$ ]] || die "无法读取物理内存大小。"
    if [ "$mem" -lt 512 ]; then
        echo 1024
    elif [ "$mem" -lt 1024 ]; then
        echo $((mem * 2))
    elif [ "$mem" -lt 2048 ]; then
        echo $((mem * 3 / 2))
    elif [ "$mem" -lt 4096 ]; then
        echo "$mem"
    else
        echo 4096
    fi
}

swap_set() {
    local size_mb="$1"
    local tmp="/swapfile.${APP_NAME}.new"
    local available_kb required_kb
    validate_size_mb "$size_mb"

    [ ! -e /swapfile ] || [ -f /swapfile ] || die "/swapfile 已存在但不是普通文件，拒绝覆盖。"
    available_kb=$(df -Pk / | awk 'NR == 2 {print $4}')
    required_kb=$((size_mb * 1024))
    [ "$available_kb" -gt "$required_kb" ] ||
        die "根分区空间不足，需要至少 ${size_mb}MB 可用空间。"

    rm -f "$tmp"
    info "创建 ${size_mb}MB Swap 文件..."
    if ! fallocate -l "${size_mb}M" "$tmp" 2>/dev/null; then
        dd if=/dev/zero of="$tmp" bs=1M count="$size_mb" status=progress
    fi
    chmod 600 "$tmp"
    mkswap "$tmp" >/dev/null

    if awk 'NR > 1 && $1 == "/swapfile" {found=1} END {exit !found}' /proc/swaps; then
        swapoff /swapfile
    fi
    rm -f /swapfile
    mv "$tmp" /swapfile
    swapon /swapfile || die "新 Swap 激活失败。"

    if grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab; then
        sed -i.bak -E 's|^[[:space:]]*/swapfile[[:space:]].*$|/swapfile none swap sw 0 0|' /etc/fstab
    else
        printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
    fi

    if [ -f /etc/alpine-release ]; then
        install -d -m 755 /etc/local.d
        printf '#!/bin/sh\nswapon /swapfile 2>/dev/null || true\n' > /etc/local.d/swap.start
        chmod 755 /etc/local.d/swap.start
        command -v rc-update >/dev/null 2>&1 && rc-update add local default >/dev/null 2>&1 || true
    fi
    ok "Swap 已设置为 ${size_mb}MB。"
    swap_status
}

swap_remove() {
    [ -f /swapfile ] || die "未找到由本脚本管理的 /swapfile。"
    if awk 'NR > 1 && $1 == "/swapfile" {found=1} END {exit !found}' /proc/swaps; then
        swapoff /swapfile
    fi
    rm -f /swapfile
    sed -i.bak '\|^[[:space:]]*/swapfile[[:space:]]|d' /etc/fstab
    rm -f /etc/local.d/swap.start
    ok "已删除 /swapfile；其他 Swap 分区未改动。"
}

normalize_port_spec() {
    local raw="${1//[[:space:]]/}"
    local token start end
    local -a tokens=()
    [ -n "$raw" ] || return 1
    IFS=',' read -r -a tokens <<< "$raw"
    for token in "${tokens[@]}"; do
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            ((start >= 1 && start <= 65535 && end >= 1 && end <= 65535 && start <= end)) || return 1
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            ((token >= 1 && token <= 65535)) || return 1
        else
            return 1
        fi
    done
    (IFS=,; printf '%s\n' "${tokens[*]}")
}

nft_port_set() {
    printf '{ %s }' "${1//,/, }"
}

specs_overlap() {
    local left="$1" right="$2"
    local a b a_start a_end b_start b_end
    local -a left_tokens right_tokens
    IFS=',' read -r -a left_tokens <<< "$left"
    IFS=',' read -r -a right_tokens <<< "$right"
    for a in "${left_tokens[@]}"; do
        if [[ "$a" == *-* ]]; then
            a_start="${a%-*}"; a_end="${a#*-}"
        else
            a_start="$a"; a_end="$a"
        fi
        for b in "${right_tokens[@]}"; do
            if [[ "$b" == *-* ]]; then
                b_start="${b%-*}"; b_end="${b#*-}"
            else
                b_start="$b"; b_end="$b"
            fi
            if ((a_start <= b_end && b_start <= a_end)); then
                return 0
            fi
        done
    done
    return 1
}

find_overlapping_rule() {
    local candidate="$1" ignored_id="${2:-}" id existing
    while IFS='|' read -r id existing _; do
        [ -n "$id" ] || continue
        [ "$id" = "$ignored_id" ] && continue
        if specs_overlap "$candidate" "$existing"; then
            printf '%s|%s\n' "$id" "$existing"
            return 0
        fi
    done < "$CONFIG_FILE"
    return 1
}

next_port_id() {
    local max=0 id number
    while IFS='|' read -r id _; do
        [[ "$id" =~ ^p([0-9]{4})$ ]] || continue
        number=$((10#${BASH_REMATCH[1]}))
        ((number > max)) && max=$number
    done < "$CONFIG_FILE"
    printf 'p%04d\n' "$((max + 1))"
}

counter_number() {
    local id="$1" direction="$2" kind="$3"
    nft list counter "$NFT_FAMILY" "$NFT_TABLE" "${id}_${direction}" 2>/dev/null |
        awk -v wanted="$kind" '{for (i=1; i<=NF; i++) if ($i == wanted) {gsub(/[^0-9]/, "", $(i+1)); print $(i+1); exit}}'
}

snapshot_lookup() {
    local file="$1" id="$2" direction="$3" field="$4"
    awk -F'|' -v key="${id}_${direction}" -v column="$field" \
        '$1 == key {print $(column == "packets" ? 2 : 3); found++}
         END {if (found != 1) exit 1}' "$file"
}

validate_snapshot_for_config() {
    local file="$1" config="${2:-$CONFIG_FILE}" id direction packets bytes
    [ -f "$file" ] || return 1
    while IFS='|' read -r id _; do
        [ -n "$id" ] || continue
        for direction in in out; do
            packets=$(snapshot_lookup "$file" "$id" "$direction" packets) || return 1
            bytes=$(snapshot_lookup "$file" "$id" "$direction" bytes) || return 1
            [[ "$packets" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ ]] || return 1
        done
    done < "$config"
}

capture_live_snapshot() {
    local target="$1" config="${2:-$CONFIG_FILE}" id direction packets bytes
    local tmp="${target}.capture.$$"
    : > "$tmp"
    if [ -s "$config" ]; then
        nft list table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
    fi
    while IFS='|' read -r id _; do
        [ -n "$id" ] || continue
        for direction in in out; do
            packets=$(counter_number "$id" "$direction" packets)
            bytes=$(counter_number "$id" "$direction" bytes)
            if ! [[ "$packets" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ ]]; then
                rm -f "$tmp"
                return 1
            fi
            printf '%s_%s|%s|%s\n' "$id" "$direction" "$packets" "$bytes" >> "$tmp"
        done
    done < "$config"
    chmod 600 "$tmp"
    mv "$tmp" "$target"
}

generate_nft_batch() {
    local config="$1" counts="$2" output="$3"
    local id spec port_set direction packets bytes
    {
        echo "flush table $NFT_FAMILY $NFT_TABLE"
        echo "add chain $NFT_FAMILY $NFT_TABLE prerouting { type filter hook prerouting priority raw; policy accept; }"
        echo "add chain $NFT_FAMILY $NFT_TABLE postrouting { type filter hook postrouting priority 101; policy accept; }"
        while IFS='|' read -r id spec _; do
            [ -n "$id" ] || continue
            port_set=$(nft_port_set "$spec")
            for direction in in out; do
                packets=0
                bytes=0
                if [ -n "$counts" ] && [ -f "$counts" ]; then
                    packets=$(snapshot_lookup "$counts" "$id" "$direction" packets 2>/dev/null || echo 0)
                    bytes=$(snapshot_lookup "$counts" "$id" "$direction" bytes 2>/dev/null || echo 0)
                fi
                echo "add counter $NFT_FAMILY $NFT_TABLE ${id}_${direction} { packets $packets bytes $bytes; }"
            done
            echo "add rule $NFT_FAMILY $NFT_TABLE prerouting tcp dport $port_set counter name ${id}_in comment \"${APP_NAME}:${id}\""
            echo "add rule $NFT_FAMILY $NFT_TABLE prerouting udp dport $port_set counter name ${id}_in comment \"${APP_NAME}:${id}\""
            echo "add rule $NFT_FAMILY $NFT_TABLE postrouting tcp sport $port_set counter name ${id}_out comment \"${APP_NAME}:${id}\""
            echo "add rule $NFT_FAMILY $NFT_TABLE postrouting udp sport $port_set counter name ${id}_out comment \"${APP_NAME}:${id}\""
        done < "$config"
    } > "$output"
}

apply_nft_config() {
    local config="$1" counts="$2" batch
    batch=$(mktemp "${STATE_DIR}/rules.XXXXXX")
    if ! nft list table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1; then
        nft add table "$NFT_FAMILY" "$NFT_TABLE"
    fi
    generate_nft_batch "$config" "$counts" "$batch"
    if ! nft -c -f "$batch"; then
        rm -f "$batch"
        return 1
    fi
    if ! nft -f "$batch"; then
        rm -f "$batch"
        return 1
    fi
    rm -f "$batch"
}

best_available_counts() {
    local output="$1"
    if capture_live_snapshot "$output" "$CONFIG_FILE"; then
        return 0
    fi
    if validate_snapshot_for_config "$SNAPSHOT_FILE" "$CONFIG_FILE"; then
        cp "$SNAPSHOT_FILE" "$output"
        return 0
    fi
    [ ! -s "$CONFIG_FILE" ] && { : > "$output"; return 0; }
    return 1
}

human_bytes() {
    local bytes="${1:-0}"
    awk -v b="$bytes" 'BEGIN {
        split("B KiB MiB GiB TiB PiB", unit, " "); i=1
        while (b >= 1024 && i < 6) {b /= 1024; i++}
        if (i == 1) printf "%d %s", b, unit[i]; else printf "%.2f %s", b, unit[i]
    }'
}

traffic_add() {
    local input_spec="${1:-}" remark="${2:-}" spec id overlap
    local candidate counts backup
    [ -n "$input_spec" ] || die "用法：$0 traffic add <端口|范围|列表> [备注]"
    spec=$(normalize_port_spec "$input_spec") || die "端口格式错误。示例：443、8000-8100、80,443,8443"
    [[ "$remark" != *"|"* && "$remark" != *$'\n'* ]] || die "备注不能包含 | 或换行。"

    lock_operation
    overlap=$(find_overlapping_rule "$spec" || true)
    if [ -n "$overlap" ]; then
        unlock_operation
        die "端口与现有规则 ${overlap%%|*}（${overlap#*|}）重叠，请先调整或删除原规则。"
    fi
    id=$(next_port_id)
    candidate=$(mktemp "${STATE_DIR}/ports.candidate.XXXXXX")
    counts=$(mktemp "${STATE_DIR}/counts.XXXXXX")
    backup=$(mktemp "${STATE_DIR}/ports.backup.XXXXXX")
    cp "$CONFIG_FILE" "$candidate"
    cp "$CONFIG_FILE" "$backup"
    printf '%s|%s|%s\n' "$id" "$spec" "$remark" >> "$candidate"
    if ! best_available_counts "$counts"; then
        rm -f "$candidate" "$counts" "$backup"
        unlock_operation
        die "无法读取当前计数且没有有效快照，已保留原配置和规则。"
    fi
    chmod 600 "$candidate"
    mv "$candidate" "$CONFIG_FILE"
    if ! apply_nft_config "$CONFIG_FILE" "$counts"; then
        mv "$backup" "$CONFIG_FILE"
        rm -f "$counts"
        unlock_operation
        die "nftables 规则校验或提交失败，已恢复原配置，内核规则未改变。"
    fi
    rm -f "$backup" "$counts"
    snapshot_save_unlocked || warn "规则已添加，但首次快照保存失败。"
    unlock_operation
    install_persistence
    ok "已添加 ${id}：${spec}${remark:+（${remark}）}"
}

traffic_delete() {
    local id="${1:-}" candidate counts backup
    [[ "$id" =~ ^p[0-9]{4}$ ]] || die "用法：$0 traffic del <ID>"
    lock_operation
    grep -q "^${id}|" "$CONFIG_FILE" || die "未找到 ${id}。"
    candidate=$(mktemp "${STATE_DIR}/ports.candidate.XXXXXX")
    counts=$(mktemp "${STATE_DIR}/counts.XXXXXX")
    backup=$(mktemp "${STATE_DIR}/ports.backup.XXXXXX")
    cp "$CONFIG_FILE" "$backup"
    if ! capture_live_snapshot "$counts" "$CONFIG_FILE"; then
        if validate_snapshot_for_config "$SNAPSHOT_FILE" "$CONFIG_FILE"; then
            cp "$SNAPSHOT_FILE" "$counts"
        else
            rm -f "$candidate" "$counts" "$backup"
            unlock_operation
            die "无法读取当前计数且没有有效快照，已取消删除。"
        fi
    fi
    awk -F'|' -v id="$id" '$1 != id' "$CONFIG_FILE" > "$candidate"
    chmod 600 "$candidate"
    mv "$candidate" "$CONFIG_FILE"
    if ! apply_nft_config "$CONFIG_FILE" "$counts"; then
        mv "$backup" "$CONFIG_FILE"
        rm -f "$counts"
        unlock_operation
        die "删除规则提交失败，已恢复原配置，内核规则未改变。"
    fi
    rm -f "$backup" "$counts"
    snapshot_save_unlocked || warn "规则已删除，但快照更新失败。"
    unlock_operation
    ok "已删除 ${id}。"
}

traffic_list() {
    local id spec remark in_bytes out_bytes total
    printf '%-7s %-24s %-16s %-16s %-16s %s\n' "ID" "端口" "入站" "出站" "合计" "备注"
    printf '%-7s %-24s %-16s %-16s %-16s %s\n' "-------" "------------------------" "----------------" "----------------" "----------------" "----"
    while IFS='|' read -r id spec remark; do
        [ -n "$id" ] || continue
        in_bytes=$(counter_number "$id" in bytes || true)
        out_bytes=$(counter_number "$id" out bytes || true)
        [[ "$in_bytes" =~ ^[0-9]+$ ]] || in_bytes=0
        [[ "$out_bytes" =~ ^[0-9]+$ ]] || out_bytes=0
        total=$((in_bytes + out_bytes))
        printf '%-7s %-24s %-16s %-16s %-16s %s\n' \
            "$id" "$spec" "$(human_bytes "$in_bytes")" "$(human_bytes "$out_bytes")" "$(human_bytes "$total")" "$remark"
    done < "$CONFIG_FILE"
}

traffic_reset() {
    local id="${1:-all}" counts reset_counts
    lock_operation
    if [ "$id" != "all" ]; then
        grep -q "^${id}|" "$CONFIG_FILE" || die "未找到 ${id}。"
    fi
    counts=$(mktemp "${STATE_DIR}/counts.XXXXXX")
    reset_counts=$(mktemp "${STATE_DIR}/reset-counts.XXXXXX")
    if ! capture_live_snapshot "$counts" "$CONFIG_FILE"; then
        rm -f "$counts" "$reset_counts"
        unlock_operation
        die "无法完整读取当前计数，已取消重置。"
    fi
    if [ "$id" = "all" ]; then
        awk -F'|' 'BEGIN {OFS="|"} {$2=0; $3=0; print}' "$counts" > "$reset_counts"
    else
        awk -F'|' -v prefix="${id}_" 'BEGIN {OFS="|"} index($1, prefix) == 1 {$2=0; $3=0} {print}' \
            "$counts" > "$reset_counts"
    fi
    if ! apply_nft_config "$CONFIG_FILE" "$reset_counts"; then
        rm -f "$counts" "$reset_counts"
        unlock_operation
        die "计数重置提交失败，原计数保持不变。"
    fi
    rm -f "$counts" "$reset_counts"
    snapshot_save_unlocked || warn "计数已重置，但快照更新失败。"
    unlock_operation
    ok "流量计数已重置：${id}"
}

snapshot_save_unlocked() {
    local tmp
    ensure_state
    tmp=$(mktemp "${STATE_DIR}/snapshot.XXXXXX")
    if ! capture_live_snapshot "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        warn "counter 读取不完整，保留原流量快照。"
        return 1
    fi
    validate_snapshot_for_config "$tmp" "$CONFIG_FILE" || {
        rm -f "$tmp"
        warn "新快照校验失败，保留原流量快照。"
        return 1
    }
    mv "$tmp" "$SNAPSHOT_FILE"
}

snapshot_save() {
    local rc
    lock_operation
    if snapshot_save_unlocked; then
        rc=0
    else
        rc=$?
    fi
    unlock_operation
    return "$rc"
}

traffic_restore() {
    local counts
    install_nftables
    lock_operation
    counts=$(mktemp "${STATE_DIR}/restore-counts.XXXXXX")
    if ! best_available_counts "$counts"; then
        rm -f "$counts"
        unlock_operation
        die "没有完整的实时计数或有效快照，拒绝以零覆盖现有流量。"
    fi
    if ! apply_nft_config "$CONFIG_FILE" "$counts"; then
        rm -f "$counts"
        unlock_operation
        die "规则恢复失败；原 nftables 规则保持不变。"
    fi
    rm -f "$counts"
    snapshot_save_unlocked || warn "规则已恢复，但快照更新失败。"
    unlock_operation
}

install_persistence() {
    sync_installed_script

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Port traffic nftables monitor
After=nftables.service
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${INSTALL_PATH} internal restore
ExecStop=${INSTALL_PATH} internal snapshot

[Install]
WantedBy=multi-user.target
EOF
        cat > "$SNAPSHOT_SERVICE_FILE" <<EOF
[Unit]
Description=Save port traffic counters

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} internal snapshot
EOF
        cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Save port traffic counters every five minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl enable "$APP_NAME.service" "${APP_NAME}-snapshot.timer" >/dev/null
        systemctl restart "$APP_NAME.service" >/dev/null
        systemctl start "${APP_NAME}-snapshot.timer" >/dev/null
    elif [ -f /etc/alpine-release ] && command -v rc-update >/dev/null 2>&1; then
        if [ -f "/etc/init.d/${APP_NAME}" ]; then
            rc-service "$APP_NAME" stop >/dev/null 2>&1 || true
        fi
        cat > "/etc/init.d/${APP_NAME}" <<EOF
#!/sbin/openrc-run
description="Port traffic nftables monitor"
depend() {
    need localmount
    after nftables
}
start() {
    ebegin "Restoring port traffic counters"
    ${INSTALL_PATH} internal restore
    eend \$?
}
stop() {
    ebegin "Saving port traffic counters"
    ${INSTALL_PATH} internal snapshot
    eend \$?
}
EOF
        chmod 755 "/etc/init.d/${APP_NAME}"
        rc-update add "$APP_NAME" default >/dev/null 2>&1 || true
        rc-service "$APP_NAME" start >/dev/null 2>&1 || true
        touch /etc/crontabs/root
        if ! grep -qF "$INSTALL_PATH internal snapshot" /etc/crontabs/root 2>/dev/null; then
            printf '*/5 * * * * %s internal snapshot\n' "$INSTALL_PATH" >> /etc/crontabs/root
        fi
        rc-service crond start >/dev/null 2>&1 || true
    else
        warn "未识别可用的 systemd/OpenRC，规则当前有效，但无法自动配置重启恢复。"
    fi
}

expected_rule_count() {
    awk 'NF {n += 4} END {print n+0}' "$CONFIG_FILE"
}

actual_rule_count() {
    { nft list table "$NFT_FAMILY" "$NFT_TABLE" 2>/dev/null || true; } |
        awk -v marker="comment \"${APP_NAME}:" 'index($0, marker) {n++} END {print n+0}'
}

ensure_monitor_ready() {
    if ! nft list table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1; then
        traffic_restore
    fi
}

counter_integrity_ok() {
    local id direction
    while IFS='|' read -r id _; do
        [ -n "$id" ] || continue
        for direction in in out; do
            counter_number "$id" "$direction" bytes | grep -qE '^[0-9]+$' || return 1
        done
    done < "$CONFIG_FILE"
}

chain_integrity_ok() {
    nft list chain "$NFT_FAMILY" "$NFT_TABLE" prerouting >/dev/null 2>&1 &&
        nft list chain "$NFT_FAMILY" "$NFT_TABLE" postrouting >/dev/null 2>&1
}

traffic_status() {
    local expected actual snapshot_time
    expected=$(expected_rule_count)
    actual=$(actual_rule_count)
    if nft list table "$NFT_FAMILY" "$NFT_TABLE" >/dev/null 2>&1; then
        ok "nftables 表 ${NFT_FAMILY} ${NFT_TABLE} 存在。"
    else
        warn "nftables 监控表尚未创建。"
    fi
    if [ "$expected" -eq "$actual" ] && counter_integrity_ok && chain_integrity_ok; then
        ok "配置、规则与 counter 一致（规则 ${actual}/${expected}）。"
    else
        warn "配置、规则或 counter 不一致（规则 ${actual}/${expected}），建议执行「恢复监控规则」。"
    fi
    echo "配置文件：$CONFIG_FILE"
    echo "快照文件：$SNAPSHOT_FILE"
    echo "监控规则数：$(awk 'NF {n++} END {print n+0}' "$CONFIG_FILE")"
    if [ -f "$SNAPSHOT_FILE" ]; then
        snapshot_time=$(stat -c '%y' "$SNAPSHOT_FILE" 2>/dev/null | cut -d. -f1 ||
            date -r "$SNAPSHOT_FILE" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "未知")
        if validate_snapshot_for_config "$SNAPSHOT_FILE" "$CONFIG_FILE"; then
            echo "最近有效快照：$snapshot_time"
        else
            warn "快照文件不完整或已损坏：$snapshot_time"
        fi
    else
        warn "尚未生成流量快照。"
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if systemctl is-enabled --quiet "$APP_NAME.service" 2>/dev/null; then
            echo "systemd 恢复服务：已启用"
        else
            warn "systemd 恢复服务：未启用"
        fi
        if systemctl is-active --quiet "${APP_NAME}-snapshot.timer" 2>/dev/null; then
            echo "systemd 快照定时器：运行中"
        else
            warn "systemd 快照定时器：未运行"
        fi
    elif [ -f /etc/alpine-release ]; then
        echo "OpenRC 恢复服务：$(rc-service "$APP_NAME" status 2>/dev/null || echo 未运行)"
    fi
}

pause_screen() {
    echo
    read -r -n 1 -s -p "按任意键返回菜单..."
    echo
}

read_choice() {
    local prompt="$1"
    local value
    read -r -p "$prompt" value
    printf '%s' "$value"
}

print_banner() {
    clear
    printf '%s' "$CYAN"
    cat <<'EOF'
╔══════════════════════════════════════════════════════╗
║              VPS Swap 与端口流量管理                ║
╚══════════════════════════════════════════════════════╝
EOF
    printf '%s' "$NC"
    printf '  版本：%-12s 系统：%s\n' "$VERSION" "$(uname -m)"
    echo
}

swap_menu() {
    local choice size recommended
    while true; do
        print_banner
        printf '%s【 Swap 管理 】%s\n\n' "$GREEN" "$NC"
        swap_status
        echo
        echo "  1. 设置 1GB Swap"
        echo "  2. 设置 2GB Swap"
        echo "  3. 设置 4GB Swap"
        echo "  4. 自定义 Swap 大小"
        echo "  5. 智能推荐并设置"
        echo "  6. 删除 /swapfile"
        echo
        echo "  0. 返回主菜单"
        echo
        choice=$(read_choice "请选择 [0-6]：")
        case "$choice" in
            1) swap_set 1024; pause_screen ;;
            2) swap_set 2048; pause_screen ;;
            3) swap_set 4096; pause_screen ;;
            4)
                read -r -p "请输入 Swap 大小（MB，最小 128）：" size
                if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -ge 128 ]; then
                    swap_set "$size"
                else
                    warn "请输入不小于 128 的整数。"
                fi
                pause_screen
                ;;
            5)
                recommended=$(swap_recommend_mb)
                echo
                info "根据当前物理内存，推荐设置 ${recommended}MB Swap。"
                read -r -p "确认应用？[Y/n]：" choice
                case "$choice" in
                    n|N) info "已取消。" ;;
                    *) swap_set "$recommended" ;;
                esac
                pause_screen
                ;;
            6)
                read -r -p "确认删除 /swapfile？[y/N]：" choice
                case "$choice" in
                    y|Y) swap_remove ;;
                    *) info "已取消。" ;;
                esac
                pause_screen
                ;;
            0) return ;;
            *) warn "无效选项：${choice:-空}"; sleep 1 ;;
        esac
    done
}

traffic_add_interactive() {
    local spec remark
    echo
    echo "支持格式："
    echo "  单端口：443"
    echo "  端口范围：8000-8100"
    echo "  端口组：80,443,8443"
    echo
    read -r -p "请输入需要监控的端口：" spec
    read -r -p "请输入备注（可留空）：" remark
    traffic_add "$spec" "$remark"
}

traffic_delete_interactive() {
    local id confirm
    echo
    traffic_list
    echo
    read -r -p "请输入需要删除的规则 ID：" id
    [ -n "$id" ] || { warn "ID 不能为空。"; return; }
    read -r -p "确认删除 ${id}？[y/N]：" confirm
    case "$confirm" in
        y|Y) traffic_delete "$id" ;;
        *) info "已取消。" ;;
    esac
}

traffic_reset_interactive() {
    local id confirm
    echo
    traffic_list
    echo
    read -r -p "输入规则 ID，或输入 all 重置全部：" id
    [ -n "$id" ] || { warn "ID 不能为空。"; return; }
    read -r -p "确认清零 ${id} 的累计流量？[y/N]：" confirm
    case "$confirm" in
        y|Y) traffic_reset "$id" ;;
        *) info "已取消。" ;;
    esac
}

traffic_menu() {
    local choice
    install_nftables
    ensure_monitor_ready
    while true; do
        print_banner
        printf '%s【 端口流量监控 】%s\n\n' "$GREEN" "$NC"
        traffic_list
        echo
        echo "  1. 添加端口监控"
        echo "  2. 删除端口监控"
        echo "  3. 刷新流量数据"
        echo "  4. 重置流量计数"
        echo "  5. 查看运行状态"
        echo "  6. 立即保存流量快照"
        echo "  7. 恢复监控规则"
        echo
        echo "  0. 返回主菜单"
        echo
        choice=$(read_choice "请选择 [0-7]：")
        case "$choice" in
            1) traffic_add_interactive; pause_screen ;;
            2) traffic_delete_interactive; pause_screen ;;
            3) continue ;;
            4) traffic_reset_interactive; pause_screen ;;
            5) traffic_status; pause_screen ;;
            6) snapshot_save; ok "流量快照已保存。"; pause_screen ;;
            7) traffic_restore; ok "监控规则及快照已恢复。"; pause_screen ;;
            0) return ;;
            *) warn "无效选项：${choice:-空}"; sleep 1 ;;
        esac
    done
}

security_menu() {
    local choice rule
    while true; do
        print_banner
        printf '%s【 网络优化与安全 】%s\n\n' "$GREEN" "$NC"
        echo "  1. 安装 BBR v3 内核"
        echo "  2. 启用 BBR v3 + fq"
        echo "  3. 查看 BBR 状态"
        echo "  4. 安装并启用 UFW"
        echo "  5. 查看 UFW 状态"
        echo "  6. UFW 放行端口"
        echo "  7. UFW 拒绝端口"
        echo "  8. 安装并配置 Fail2ban"
        echo "  9. 查看 Fail2ban 与最近爆破来源"
        echo " 10. 添加 Fail2ban 白名单"
        echo " 11. 删除 Fail2ban 白名单"
        echo " 12. 查看 Fail2ban 白名单"
        echo
        echo "  0. 返回主菜单"
        echo
        choice=$(read_choice "请选择 [0-12]：")
        case "$choice" in
            1) bbr_install; pause_screen ;;
            2) bbr_enable; pause_screen ;;
            3) bbr_status; pause_screen ;;
            4) ufw_install; pause_screen ;;
            5) command -v ufw >/dev/null 2>&1 && ufw status verbose || warn "UFW 尚未安装。"; pause_screen ;;
            6)
                read -r -p "请输入规则（如 443/tcp）：" rule
                ufw_rule allow "$rule"
                pause_screen
                ;;
            7)
                read -r -p "请输入规则（如 443/tcp）：" rule
                ufw_rule deny "$rule"
                pause_screen
                ;;
            8) ufw_install; fail2ban_install; pause_screen ;;
            9) fail2ban_status; pause_screen ;;
            10)
                read -r -p "请输入白名单 IP 或 CIDR：" rule
                fail2ban_whitelist_add "$rule"
                pause_screen
                ;;
            11)
                fail2ban_whitelist_list
                read -r -p "请输入要删除的 IP 或 CIDR：" rule
                fail2ban_whitelist_delete "$rule"
                pause_screen
                ;;
            12) fail2ban_whitelist_list; pause_screen ;;
            0) return ;;
            *) warn "无效选项：${choice:-空}"; sleep 1 ;;
        esac
    done
}

interactive_menu() {
    local choice
    while true; do
        print_banner
        printf '%s请选择需要使用的功能：%s\n\n' "$GREEN" "$NC"
        echo "  ┌────────────────────────────────────────────┐"
        echo "  │  1. Swap 管理                             │"
        echo "  │  2. 端口流量监控                          │"
        echo "  │  3. 查看当前状态                          │"
        echo "  │  4. BBR v3 / UFW / Fail2ban               │"
        echo "  │  5. 安装并运行 singbox-lite（sb）          │"
        echo "  │  6. 一键安装 Docker                        │"
        echo "  │                                            │"
        echo "  │  0. 退出脚本                              │"
        echo "  └────────────────────────────────────────────┘"
        echo
        choice=$(read_choice "请输入选项 [0-6]：")
        case "$choice" in
            1) swap_menu ;;
            2) traffic_menu ;;
            3)
                print_banner
                printf '%s【 Swap 状态 】%s\n' "$GREEN" "$NC"
                swap_status
                echo
                printf '%s【 流量监控状态 】%s\n' "$GREEN" "$NC"
                if command -v nft >/dev/null 2>&1; then
                    traffic_status
                    echo
                    traffic_list
                else
                    warn "尚未安装 nftables。"
                fi
                pause_screen
                ;;
            4) security_menu ;;
            5) sb_install; pause_screen ;;
            6) docker_install; pause_screen ;;
            0)
                clear
                ok "已退出。"
                return
                ;;
            *) warn "无效选项：${choice:-空}"; sleep 1 ;;
        esac
    done
}

usage() {
    cat <<EOF
server-tool ${VERSION}

用法：
  $0 swap status
  $0 swap recommend
  $0 swap set <MB>
  $0 swap remove

  $0 traffic add <端口|范围|列表> [备注]
  $0 traffic del <ID>
  $0 traffic list
  $0 traffic reset [ID|all]
  $0 traffic status
  $0 traffic snapshot
  $0 traffic restore

  $0 bbr install|enable|status
  $0 firewall install|status
  $0 firewall allow|deny|delete <规则>
  $0 fail2ban install|status
  $0 fail2ban attempts [显示数量]
  $0 fail2ban whitelist add|del <IP或CIDR>
  $0 fail2ban whitelist list
  $0 sb install|run
  $0 docker install|status

示例：
  sudo bash $0 swap set 2048
  sudo bash $0 traffic add 443 HTTPS
  sudo bash $0 traffic add 8000-8100 转发端口
  sudo bash $0 traffic add 80,443,8443 Web端口组
  sudo bash $0 bbr install
  sudo bash $0 firewall install
  sudo bash $0 firewall allow 443/tcp
  sudo bash $0 fail2ban install
  sudo bash $0 fail2ban attempts 20
  sudo bash $0 fail2ban whitelist add 203.0.113.10
  sudo bash $0 fail2ban whitelist add 2001:db8::/32
  sudo bash $0 sb install
  sudo bash $0 docker install

说明：
  入站 = 目标端口流量；出站 = 源端口流量。
  同时统计 TCP/UDP 和本机服务/转发流量，不负责封锁、计费或限速。
  Alpine 请使用 Bash 运行；建议先安装 bash、nftables、util-linux、coreutils。
  Alpine 的开机恢复依赖 OpenRC，定时快照依赖 crond。
EOF
}

main() {
    require_linux
    require_root
    ensure_state
    sync_installed_script
    case "${1:-}" in
        swap)
            case "${2:-}" in
                status) swap_status ;;
                recommend)
                    local recommended
                    recommended=$(swap_recommend_mb)
                    echo "推荐 Swap：${recommended}MB"
                    ;;
                set) swap_set "${3:-}" ;;
                remove) swap_remove ;;
                *) usage; exit 1 ;;
            esac
            ;;
        traffic)
            install_nftables
            case "${2:-}" in
                add) traffic_add "${3:-}" "${4:-}" ;;
                del|delete|remove) traffic_delete "${3:-}" ;;
                list) ensure_monitor_ready; traffic_list ;;
                reset) ensure_monitor_ready; traffic_reset "${3:-all}" ;;
                status) traffic_status ;;
                snapshot) snapshot_save; ok "流量快照已保存。" ;;
                restore) traffic_restore; ok "监控规则及快照已恢复。" ;;
                *) usage; exit 1 ;;
            esac
            ;;
        bbr)
            case "${2:-}" in
                install) bbr_install ;;
                enable) bbr_enable ;;
                status) bbr_status ;;
                *) usage; exit 1 ;;
            esac
            ;;
        firewall|ufw)
            case "${2:-}" in
                install) ufw_install ;;
                status)
                    command -v ufw >/dev/null 2>&1 || die "UFW 尚未安装。"
                    ufw status verbose
                    ;;
                allow|deny|delete) ufw_rule "$2" "${3:-}" ;;
                *) usage; exit 1 ;;
            esac
            ;;
        fail2ban|security)
            case "${2:-}" in
                install) ufw_install; fail2ban_install ;;
                status) fail2ban_status ;;
                attempts) ssh_failed_sources "${3:-20}" ;;
                whitelist)
                    case "${3:-}" in
                        add) fail2ban_whitelist_add "${4:-}" ;;
                        del|delete|remove) fail2ban_whitelist_delete "${4:-}" ;;
                        list) fail2ban_whitelist_list ;;
                        *) usage; exit 1 ;;
                    esac
                    ;;
                *) usage; exit 1 ;;
            esac
            ;;
        sb|singbox-lite)
            case "${2:-install}" in
                install) sb_install ;;
                run) sb_run ;;
                *) usage; exit 1 ;;
            esac
            ;;
        docker)
            case "${2:-install}" in
                install) docker_install ;;
                status) docker_status ;;
                *) usage; exit 1 ;;
            esac
            ;;
        internal)
            case "${2:-}" in
                snapshot) snapshot_save ;;
                restore) traffic_restore ;;
                *) exit 1 ;;
            esac
            ;;
        -h|--help|help) usage ;;
        "") interactive_menu ;;
        *) usage; exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
