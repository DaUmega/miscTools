#!/usr/bin/env bash
# Sets up systemd process as root to auto-run
# curl -sSL https://raw.githubusercontent.com/DaUmega/miscTools/main/autoRunRoot.sh | sudo bash -s /path/to/executable

set -e

# --- Check for sudo/root ---
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run with sudo or as root."
    exit 1
fi

# --- Check for one argument ---
if [[ $# -ne 1 ]]; then
    echo "Usage: sudo $0 /path/to/executable"
    exit 1
fi

TARGET_PATH="$1"

# --- Convert relative path to absolute ---
if ! command -v realpath &>/dev/null; then
    # Fallback if realpath is not installed
    TARGET_PATH="$(cd "$(dirname "$TARGET_PATH")" && pwd)/$(basename "$TARGET_PATH")"
else
    TARGET_PATH="$(realpath "$TARGET_PATH")"
fi

# --- Validate executable file ---
if [[ ! -f "$TARGET_PATH" ]]; then
    echo "❌ Error: File '$TARGET_PATH' not found."
    exit 1
fi

if [[ ! -x "$TARGET_PATH" ]]; then
    echo "⚠️  File is not executable. Making it executable..."
    chmod +x "$TARGET_PATH"
fi

# --- Derive service name ---
BASENAME="$(basename "$TARGET_PATH")"
SERVICE_NAME="${BASENAME%.*}"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"

# --- Confirm with user ---
echo "This will install:"
echo "  Executable: $TARGET_PATH"
echo "  Service:    $SERVICE_FILE"
read -p "Continue? (y/n): " CONFIRM
if [[ "$CONFIRM" != [yY] ]]; then
    echo "Aborted."
    exit 0
fi

# --- Create systemd service file ---
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Service for $TARGET_PATH
After=network.target

[Service]
ExecStart=$TARGET_PATH
Restart=always
RestartSec=5
User=root
WorkingDirectory=$(dirname "$TARGET_PATH")
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# --- Reload and enable the service ---
echo "🔄 Reloading systemd daemon..."
systemctl daemon-reexec
systemctl daemon-reload

echo "🔧 Enabling and starting service '$SERVICE_NAME'..."
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo "✅ Service '$SERVICE_NAME' installed and started successfully."
systemctl status "$SERVICE_NAME" --no-pager --lines=10
