#!/bin/sh

set -e

echo "================================="
echo " Komari Agent Uninstaller"
echo "================================="

# 检测系统
if [ -f /etc/alpine-release ]; then
    OS="alpine"
elif [ -f /etc/debian_version ]; then
    OS="debian"
else
    OS="unknown"
fi

echo "[INFO] Detected OS: $OS"

SERVICE="komari-agent"

# 停止服务
if [ "$OS" = "alpine" ]; then
    echo "[INFO] Using OpenRC"

    if rc-service "$SERVICE" status >/dev/null 2>&1; then
        echo "[INFO] Stopping $SERVICE..."
        rc-service "$SERVICE" stop || true
    fi

    echo "[INFO] Removing OpenRC service..."
    rc-update del "$SERVICE" default 2>/dev/null || true

    rm -f /etc/init.d/$SERVICE

elif [ "$OS" = "debian" ]; then
    echo "[INFO] Using systemd"

    if systemctl list-unit-files | grep -q "$SERVICE"; then
        echo "[INFO] Stopping $SERVICE..."
        systemctl stop "$SERVICE" || true

        echo "[INFO] Disabling $SERVICE..."
        systemctl disable "$SERVICE" || true
    fi

    rm -f /etc/systemd/system/$SERVICE.service

    systemctl daemon-reload

else
    echo "[WARN] Unknown OS, skip service removal"
fi


# 查找并杀掉残留进程
echo "[INFO] Killing remaining processes..."

pkill -f "/opt/komari/agent" 2>/dev/null || true
pkill -f "komari-agent" 2>/dev/null || true


# 删除文件
echo "[INFO] Removing Komari files..."

rm -rf /opt/komari

rm -rf /var/lib/komari
rm -rf /etc/komari
rm -rf /usr/local/bin/komari*


# 清理运行文件
rm -rf /run/komari*


echo
echo "================================="
echo " Komari Agent removed."
echo "================================="
