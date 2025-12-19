#!/data/data/com.termux/files/usr/bin/bash
# Direct run: curl -fsSL https://raw.githubusercontent.com/daumega/miscTools/BRANCH/termux_tor_ssh_setup.sh | bash
set -euo pipefail

echo "[*] Updating Termux packages..."
pkg update -y && pkg upgrade -y

echo "[*] Installing required packages..."
pkg install -y openssh tor torsocks nano

SSH_DIR="$HOME/.ssh"
KEY="$SSH_DIR/id_ed25519"
TOR_DIR="$HOME/.tor"
TORRC="$TOR_DIR/torrc"
TORSOCKS_CONF="$PREFIX/etc/tor/torsocks.conf"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ ! -f "$KEY" ]]; then
  echo "[*] Generating SSH key (ed25519)..."
  ssh-keygen -t ed25519 -a 100 -f "$KEY"
else
  echo "[*] SSH key already exists, skipping generation."
fi

echo
echo "==== YOUR SSH PUBLIC KEY ===="
cat "$KEY.pub"
echo "============================="
echo "Add this to ~/.ssh/authorized_keys on the server."
echo

mkdir -p "$TOR_DIR"

if [[ ! -f "$TORRC" ]]; then
  echo "[*] Creating Tor config..."
  cat > "$TORRC" <<EOF
SocksPort 9050
DNSPort 9053
AvoidDiskWrites 1
EOF
else
  echo "[*] Tor config already exists."
fi

echo "[*] Configuring torsocks..."
mkdir -p "$(dirname "$TORSOCKS_CONF")"
grep -q "^TorPort 9050" "$TORSOCKS_CONF" 2>/dev/null || echo "TorPort 9050" >> "$TORSOCKS_CONF"
grep -q "^TorAddress 127.0.0.1" "$TORSOCKS_CONF" 2>/dev/null || echo "TorAddress 127.0.0.1" >> "$TORSOCKS_CONF"

echo "[*] Starting Tor..."
if pgrep -x tor >/dev/null; then
  echo "[*] Tor already running."
else
  tor -f "$TORRC" >/dev/null 2>&1 &
  sleep 8
fi

echo "[*] Testing Tor connectivity..."
torsocks curl -s https://check.torproject.org/api/ip | grep -q IsTor || {
  echo "[!] Tor test failed. Check Tor logs."
  exit 1
}

echo
echo "[✓] Tor is working."
echo "You can now connect with:"
echo "  torsocks ssh user@toraddress.onion"
