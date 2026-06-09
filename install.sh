#!/bin/bash
# ============================================================================
#  Installer for Solana Validator Alert Bot.
#  Installs dependencies, scaffolds secrets.env, and can install a systemd
#  service generated for this checkout's path and the current user.
# ============================================================================
set -euo pipefail

BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="solana-validator-alert-bot"
RUN_USER="$(id -un)"
SOLANA_BIN_DIR="$HOME/.local/share/solana/install/active_release/bin"

echo "==> Solana Validator Alert Bot installer"
echo "    directory: $BOT_DIR"
echo "    user:      $RUN_USER"

# 1. Dependencies -----------------------------------------------------------
need=()
for c in curl jq bc; do
    command -v "$c" >/dev/null 2>&1 || need+=("$c")
done
if (( ${#need[@]} )); then
    echo "==> Installing missing dependencies: ${need[*]}"
    if command -v apt >/dev/null 2>&1; then
        sudo apt update && sudo apt install -y "${need[@]}"
    else
        echo "    Please install manually: ${need[*]}" >&2
        exit 1
    fi
fi

# 2. solana CLI check -------------------------------------------------------
if ! command -v solana >/dev/null 2>&1 && [ ! -x "$SOLANA_BIN_DIR/solana" ]; then
    echo "WARN: solana CLI not found. Install it, then set SOLANA_PATH in config.sh." >&2
fi

# 3. Secrets scaffold -------------------------------------------------------
if [ ! -f "$BOT_DIR/secrets.env" ]; then
    cp "$BOT_DIR/secrets.env.example" "$BOT_DIR/secrets.env"
    echo "==> Created secrets.env — edit it with your BOT_TOKEN and chat ids."
fi

chmod +x "$BOT_DIR/bot.sh"

# 4. systemd service (optional) ---------------------------------------------
read -r -p "Install & enable the systemd service now? [y/N] " ans
if [[ "${ans:-}" =~ ^[Yy]$ ]]; then
    unit="/etc/systemd/system/${SERVICE_NAME}.service"
    sudo tee "$unit" >/dev/null <<UNIT
[Unit]
Description=Solana Validator Alert Bot (delinquency + dashboard monitor)
After=network.target

[Service]
Type=simple
ExecStart=$BOT_DIR/bot.sh
WorkingDirectory=$BOT_DIR
Restart=always
RestartSec=10
User=$RUN_USER
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME
Environment="PATH=$SOLANA_BIN_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"
    echo "==> Service installed. Start it with: sudo systemctl start $SERVICE_NAME"
else
    echo "==> Skipped service install. Run manually with: ./bot.sh"
fi

echo "==> Done. Remember to edit secrets.env and config.sh before starting."
