#!/usr/bin/env sh
# Minimal wifi export/import using nmcli
# Usage: ./wifi-io.sh export file.txt
#        ./wifi-io.sh import file.txt

set -eu

# Safety check: nmcli must exist
if ! command -v nmcli >/dev/null 2>&1; then
  echo "Error: nmcli not found. Please install NetworkManager." >&2
  exit 1
fi

if [ $# -ne 2 ]; then
  echo "Usage: $0 export|import file" >&2
  exit 1
fi

mode="$1"
file="$2"

case "$mode" in
  export)
    nmcli -t -f NAME,TYPE connection show | \
      awk -F: '$2=="802-11-wireless" {print $1}' | \
      while IFS= read -r ssid; do
        pass=$(nmcli -s -g 802-11-wireless-security.psk connection show "$ssid" 2>/dev/null || true)
        printf '%s:%s\n' "$ssid" "$pass"
      done >"$file"
    echo "Exported to $file"
    ;;

  import)
    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] && continue
      ssid="${line%%:*}"
      pass="${line#*:}"
      nmcli -t -f NAME connection show | grep -Fxq "$ssid" && continue
      nmcli connection add type wifi con-name "$ssid" ifname '*' ssid "$ssid" >/dev/null 2>&1
      [ -n "$pass" ] && nmcli connection modify "$ssid" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$pass" >/dev/null 2>&1
    done <"$file"
    echo "Import finished"
    ;;

  *)
    echo "Unknown mode: $mode" >&2
    exit 1
    ;;
esac
