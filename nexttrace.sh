#!/usr/bin/env bash

set -e

DEFAULT_IP="116.148.117.86"
IP="${1:-$DEFAULT_IP}"

echo "[INFO] Target IP: $IP"

# ---------------------------
# detect OS
# ---------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"

echo "[INFO] OS: $OS"
echo "[INFO] ARCH: $ARCH"

# ---------------------------
# normalize arch
# ---------------------------
case "$ARCH" in
  x86_64|amd64)
    ARCH="amd64"
    ;;
  aarch64|arm64)
    ARCH="arm64"
    ;;
  *)
    echo "[ERROR] Unsupported arch: $ARCH"
    exit 1
    ;;
esac

# ---------------------------
# binary name
# ---------------------------
BIN="/usr/local/bin/nexttrace"

# ---------------------------
# check existing
# ---------------------------
if command -v nexttrace >/dev/null 2>&1; then
  echo "[INFO] nexttrace already installed, skipping download"
else
  echo "[INFO] Installing nexttrace..."

  URL="https://github.com/nxtrace/NTrace-core/releases/latest/download/nexttrace_linux_${ARCH}"

  TMP="/tmp/nexttrace"

  if [ "$OS" = "Darwin" ]; then
    TMP="/tmp/nexttrace_mac"
    URL="https://github.com/nxtrace/NTrace-core/releases/latest/download/nexttrace_linux_${ARCH}"
  fi

  echo "[INFO] Download URL: $URL"

  if command -v wget >/dev/null 2>&1; then
    wget -O "$TMP" "$URL"
  else
    curl -L -o "$TMP" "$URL"
  fi

  chmod +x "$TMP"

  # mac 不写 /usr/local/bin 强制路径问题
  if [ "$OS" = "Darwin" ]; then
    sudo mv "$TMP" /usr/local/bin/nexttrace
  else
    mv "$TMP" "$BIN"
  fi

  echo "[INFO] nexttrace installed"
fi

# ---------------------------
# run trace
# ---------------------------
echo "[INFO] Running nexttrace..."
nexttrace "$IP"
