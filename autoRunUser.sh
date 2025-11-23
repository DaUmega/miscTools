#!/usr/bin/env bash
# curl -sSL https://raw.githubusercontent.com/DaUmega/miscTools/main/autoRunUser.sh | bash -s /path/to/executable

set -e

# --- Check argument count ---
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 /path/to/executable"
    exit 1
fi

TARGET_PATH="$1"

# --- Convert relative path to absolute ---
if ! command -v realpath &>/dev/null; then
    TARGET_PATH="$(cd "$(dirname "$TARGET_PATH")" && pwd)/$(basename "$TARGET_PATH")"
else
    TARGET_PATH="$(realpath "$TARGET_PATH")"
fi

# --- Validate target file ---
if [[ ! -f "$TARGET_PATH" ]]; then
    echo "❌ Error: File '$TARGET_PATH' not found."
    exit 1
fi

if [[ ! -x "$TARGET_PATH" ]]; then
    echo "⚠️  File is not executable. Making it executable..."
    chmod +x "$TARGET_PATH"
fi

# --- Determine autostart directory and file name ---
AUTOSTART_DIR="$HOME/.config/autostart"
mkdir -p "$AUTOSTART_DIR"

BASENAME="$(basename "$TARGET_PATH")"
SERVICE_NAME="${BASENAME%.*}"
DESKTOP_FILE="$AUTOSTART_DIR/$SERVICE_NAME.desktop"

# --- Confirm with user ---
echo "This will configure auto-start for:"
echo "  Executable: $TARGET_PATH"
echo "  Autostart file: $DESKTOP_FILE"
read -p "Continue? (y/n): " CONFIRM
if [[ "$CONFIRM" != [yY] ]]; then
    echo "Aborted."
    exit 0
fi

# --- Create .desktop file ---
cat <<EOF > "$DESKTOP_FILE"
[Desktop Entry]
Type=Application
Exec=$TARGET_PATH
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=$SERVICE_NAME
Comment=Automatically run $BASENAME after login
EOF

chmod 644 "$DESKTOP_FILE"

echo "✅ Auto-start entry created successfully."
echo "➡️  It will run '$TARGET_PATH' automatically after you log in."
echo "📄 Desktop file: $DESKTOP_FILE"
