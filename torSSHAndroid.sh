#!/data/data/com.termux/files/usr/bin/bash
# Universal Termux Tor+SSH setup.
# Direct run: curl -fsSL https://raw.githubusercontent.com/DaUmega/miscTools/refs/heads/main/torSSHAndroid.sh | bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "[*] Updating Termux packages..."
pkg update -y
# --force-confdef/--force-confold: never prompt on conffiles (dpkg would read
# stdin, which is the finished curl pipe under `curl | bash`, and die on EOF).
apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

echo "[*] Installing required packages..."
pkg install -y openssh tor torsocks nano

# Hold a wake lock so Tor/SSH survive with the screen off (needs Termux:API app).
# Also set: Settings > Apps > Termux > Battery > Unrestricted.
command -v termux-wake-lock >/dev/null && termux-wake-lock 2>/dev/null || true

SSH_DIR="$HOME/.ssh"
KEY="$SSH_DIR/id_ed25519"
TOR_DIR="$HOME/.tor"
TORRC="$TOR_DIR/torrc"
PIDF="$TOR_DIR/tor.pid"
TORSOCKS_CONF="$PREFIX/etc/tor/torsocks.conf"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ ! -f "$KEY" ]]; then
  echo "[*] Generating SSH key (ed25519)..."
  ssh-keygen -t ed25519 -a 100 -f "$KEY" -N ""
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
  printf 'SocksPort 9050\nDNSPort 9053\nAvoidDiskWrites 1\n' > "$TORRC"
else
  echo "[*] Tor config already exists."
fi

echo "[*] Configuring torsocks..."
mkdir -p "$(dirname "$TORSOCKS_CONF")"
grep -q "^TorPort 9050" "$TORSOCKS_CONF" 2>/dev/null || echo "TorPort 9050" >> "$TORSOCKS_CONF"
grep -q "^TorAddress 127.0.0.1" "$TORSOCKS_CONF" 2>/dev/null || echo "TorAddress 127.0.0.1" >> "$TORSOCKS_CONF"

echo "[*] Starting Tor..."
if [[ -f "$PIDF" ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  echo "[*] Tor already running."
else
  nohup tor -f "$TORRC" >"$TOR_DIR/tor.log" 2>&1 &
  echo $! > "$PIDF"
fi

echo "[*] Waiting for a Tor circuit (up to ~90s)..."
ok=0
for _ in $(seq 1 18); do
  if torsocks curl -s --max-time 8 https://check.torproject.org/api/ip | grep -q '"IsTor":true'; then
    ok=1
    break
  fi
  sleep 5
done
if [[ "$ok" -eq 0 ]]; then
  echo "[!] Tor is not bootstrapped. See $TOR_DIR/tor.log"
  exit 1
fi

echo
echo "[✓] Tor is working."
echo "You can now connect with:"
echo "  torsocks ssh user@toraddress.onion"
