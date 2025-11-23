#!/usr/bin/env bash
# Removes systemd process permanently
# curl -sSL https://raw.githubusercontent.com/DaUmega/miscTools/main/autoRunRoot.sh | sudo bash -s <service_name>

SERVICE_INPUT="$1"
SERVICE_NAME="$SERVICE_INPUT.service"

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m" # No color

echo -e "${GREEN}Systemd Process Removal Script${NC}"

# --- Argument check ---
if [ -z "$SERVICE_INPUT" ]; then
  echo -e "${RED}Usage: $0 <service_name>${NC}"
  exit 1
fi

# --- Sudo check ---
if ! sudo -n true 2>/dev/null; then
  echo -e "${RED}ERROR: This script requires sudo privileges.${NC}"
  exit 1
fi

# --- Check if system service exists ---
if systemctl list-unit-files | grep -q "^$SERVICE_NAME"; then
  echo -e "${YELLOW}[*] Stopping and disabling system service: $SERVICE_NAME${NC}"
  sudo systemctl stop "$SERVICE_NAME"
  sudo systemctl disable "$SERVICE_NAME"
  sudo systemctl reset-failed
else
  echo -e "${YELLOW}[*] System service $SERVICE_NAME not found in system unit files${NC}"
fi

# --- Optional: Check for user-level services ---
if systemctl --user list-unit-files 2>/dev/null | grep -q "^$SERVICE_NAME"; then
  echo -e "${YELLOW}[*] Found user service. Attempting to stop and disable (user mode)${NC}"
  systemctl --user stop "$SERVICE_NAME"
  systemctl --user disable "$SERVICE_NAME"
  systemctl --user reset-failed
fi

# --- Remove service file from common locations ---
FOUND_SERVICE_FILE=false
for dir in /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
  if [ -f "$dir/$SERVICE_NAME" ]; then
    echo -e "${YELLOW}[*] Removing service file from $dir${NC}"
    sudo rm -f "$dir/$SERVICE_NAME"
    FOUND_SERVICE_FILE=true
  fi
done

if [ "$FOUND_SERVICE_FILE" = false ]; then
  echo -e "${YELLOW}[*] No service file found to remove${NC}"
fi

# --- Reload systemd ---
echo -e "${YELLOW}[*] Reloading systemd daemon${NC}"
sudo systemctl daemon-reload

echo -e "${GREEN}[*] Service $SERVICE_NAME removed from autorun (if it existed)${NC}"
