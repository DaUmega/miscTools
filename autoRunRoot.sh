#!/usr/bin/env bash
# Sets up systemd process as root to auto-run
# wget https://raw.githubusercontent.com/DaUmega/miscTools/main/autoRunRoot.sh; chmod +x autoRunRoot.sh; ./autoRunRoot.sh /path/to/executable [minutes]

set -e

# --- Check for sudo/root ---
if [[ $EUID -ne 0 ]]; then
    echo "❌ This script must be run with sudo or as root."
    exit 1
fi

# --- Check arguments ---
if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: sudo $0 /path/to/executable [minutes]"
    exit 1
fi

TARGET_PATH="$1"
TIMER_MINUTES="${2:-0}"

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

# --- Derive service/timer names ---
BASENAME="$(basename "$TARGET_PATH")"
SERVICE_NAME="${BASENAME%.*}"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
TIMER_FILE="/etc/systemd/system/$SERVICE_NAME.timer"

# --- Confirm with user ---
if [[ "$TIMER_MINUTES" -gt 0 ]]; then
    echo "This will install a timer:"
    echo "  Executable: $TARGET_PATH"
    echo "  Timer:      $TIMER_FILE"
    echo "  Interval:   Every $TIMER_MINUTES minutes"
else
    echo "This will install a service:"
    echo "  Executable: $TARGET_PATH"
    echo "  Service:    $SERVICE_FILE"
fi
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

# --- Create systemd timer if requested ---
if [[ "$TIMER_MINUTES" -gt 0 ]]; then
    cat <<EOF > "$TIMER_FILE"
[Unit]
Description=Timer for $TARGET_PATH

[Timer]
OnBootSec=1min
OnUnitActiveSec=${TIMER_MINUTES}min
Persistent=true

[Install]
WantedBy=timers.target
EOF
fi

# --- Reload and enable the service ---
echo "🔄 Reloading systemd daemon..."
systemctl daemon-reexec
systemctl daemon-reload

if [[ "$TIMER_MINUTES" -gt 0 ]]; then
    echo "🔧 Enabling and starting timer '$SERVICE_NAME.timer'..."
    systemctl enable "$SERVICE_NAME.timer"
    systemctl restart "$SERVICE_NAME.timer"
    echo "✅ Timer '$SERVICE_NAME.timer' installed and started successfully."
    systemctl list-timers --all | grep "$SERVICE_NAME"
else
    echo "🔧 Enabling and starting service '$SERVICE_NAME'..."
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
    echo "✅ Service '$SERVICE_NAME' installed and started successfully."
    systemctl status "$SERVICE_NAME" --no-pager --lines=10
fi
