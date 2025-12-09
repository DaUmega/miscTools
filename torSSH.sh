#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PROGNAME="$(basename "$0")"
TOR_HS_DIR="/var/lib/tor/ssh_hidden"
TORRC="/etc/tor/torrc"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSH_PORT=22
DEFAULT_SOCKS_PORT=1080

install_pkgs() {
  pkgs=("$@")
  if command -v apt >/dev/null 2>&1; then
    sudo apt update
    sudo apt install -y "${pkgs[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y "${pkgs[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --noconfirm "${pkgs[@]}"
  else
    echo "Unsupported distro. Install manually: ${pkgs[*]}"
    exit 1
  fi
}

pause() { read -rp $'\nPress Enter to continue...'; }

show_menu() {
cat <<EOF

Tor + SSH Multi-Tool
-------------------
1) Install Tor + OpenSSH (secure defaults)
2) Create Tor Hidden SSH service
3) Show Tor onion hostname
4) Remove Tor hidden SSH service
5) Generate SSH keypair (client)
6) Add public key on server (duplicate-safe)
7) Connect to .onion via Tor
8) Create full SOCKS tunnel for all traffic
9) Quit

EOF
}

install_tor_and_ssh() {
  install_pkgs tor openssh-server torsocks netcat-openbsd
  sudo systemctl enable --now tor
  if sudo systemctl list-unit-files | grep -qE 'sshd.service|ssh.service'; then
    sudo systemctl enable --now ssh || sudo systemctl enable --now sshd || true
  else
    sudo systemctl enable --now ssh || sudo systemctl enable --now sshd || true
  fi
  if [ -f "$SSHD_CONFIG" ]; then
    sudo cp -n "$SSHD_CONFIG" "$SSHD_CONFIG.bak.$(date +%s)" || true
    sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
    if ! sudo grep -q "^PasswordAuthentication" "$SSHD_CONFIG"; then
      echo "PasswordAuthentication no" | sudo tee -a "$SSHD_CONFIG" >/dev/null
    fi
    sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
    if ! sudo grep -q "^PermitRootLogin" "$SSHD_CONFIG"; then
      echo "PermitRootLogin no" | sudo tee -a "$SSHD_CONFIG" >/dev/null
    fi
    sudo sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG"
    if ! sudo grep -q "^ChallengeResponseAuthentication" "$SSHD_CONFIG"; then
      echo "ChallengeResponseAuthentication no" | sudo tee -a "$SSHD_CONFIG" >/dev/null
    fi
    sudo sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
    if ! sudo grep -q "^PubkeyAuthentication" "$SSHD_CONFIG"; then
      echo "PubkeyAuthentication yes" | sudo tee -a "$SSHD_CONFIG" >/dev/null
    fi
    CURUSER=$(logname 2>/dev/null || echo "$SUDO_USER" || whoami)
    if [ -n "$CURUSER" ]; then
      if sudo grep -q "^AllowUsers" "$SSHD_CONFIG"; then
        if ! sudo grep -q "^AllowUsers.*\b$CURUSER\b" "$SSHD_CONFIG"; then
          sudo sed -i "s/^AllowUsers.*/& $CURUSER/" "$SSHD_CONFIG" || echo "AllowUsers $CURUSER" | sudo tee -a "$SSHD_CONFIG" >/dev/null
        fi
      else
        echo "AllowUsers $CURUSER" | sudo tee -a "$SSHD_CONFIG" >/dev/null
      fi
    fi
    sudo systemctl restart ssh || sudo systemctl restart sshd || true
  fi
  echo "Tor and SSH installed and hardened."
}

create_hidden_ssh() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run this option on the server; you may be prompted for sudo."
  fi
  sudo mkdir -p "$TOR_HS_DIR"
  sudo chown -R debian-tor:debian-tor "$TOR_HS_DIR" 2>/dev/null || true
  if ! sudo grep -qF "HiddenServiceDir $TOR_HS_DIR" "$TORRC"; then
    echo -e "\nHiddenServiceDir $TOR_HS_DIR\nHiddenServicePort $SSH_PORT 127.0.0.1:$SSH_PORT\n" | sudo tee -a "$TORRC" >/dev/null
  fi
  sudo systemctl restart tor
  sleep 2
  sudo chmod 700 "$TOR_HS_DIR"
  if sudo test -f "$TOR_HS_DIR/hostname"; then
    echo "Hidden service address:"
    sudo cat "$TOR_HS_DIR/hostname"
  else
    echo "Hidden service creation failed; check 'sudo journalctl -u tor' for details."
  fi
}

show_onion() {
  sudo cat "$TOR_HS_DIR/hostname" 2>/dev/null || echo "No hidden service found."
}

remove_hidden_ssh() {
  read -rp "Remove hidden service and config? (y/N) " yn
  case "$yn" in
    [Yy]*)
      sudo sed -i '/HiddenServiceDir \/var\/lib\/tor\/ssh_hidden/,+1d' "$TORRC" || true
      sudo rm -rf "$TOR_HS_DIR" || true
      sudo systemctl restart tor || true
      echo "Removed."
      ;;
  esac
}

generate_ssh_keypair() {
  if [ -f "$HOME/.ssh/id_ed25519" ]; then
    read -rp "Key exists. Overwrite? (y/N) " yn
    case "$yn" in
      [Yy]*) ;;
      *) return ;;
    esac
  fi
  ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N ""
  cat "$HOME/.ssh/id_ed25519.pub"
}

add_public_key_server() {
  read -rp "Paste public key: " PUBKEY
  mkdir -p "$HOME/.ssh"
  touch "$HOME/.ssh/authorized_keys"
  chmod 700 "$HOME/.ssh"
  chmod 600 "$HOME/.ssh/authorized_keys"
  if grep -qxF "$PUBKEY" "$HOME/.ssh/authorized_keys"; then
    echo "Key already exists."
  else
    echo "$PUBKEY" >> "$HOME/.ssh/authorized_keys"
    echo "Key added."
  fi
}

connect_onion() {
  read -rp "Onion address: " onion
  read -rp "Username: " user
  if ! command -v torsocks >/dev/null 2>&1; then
    install_pkgs torsocks
  fi
  torsocks ssh "$user@$onion"
}

create_socks_tunnel() {
  read -rp "Target (.onion): " target
  read -rp "Username: " user
  read -rp "Local SOCKS port (default 1080): " lport
  lport=${lport:-$DEFAULT_SOCKS_PORT}
  if ! command -v torsocks >/dev/null 2>&1; then
    install_pkgs torsocks
  fi
  echo "SOCKS5 proxy on localhost:$lport"
  echo "Configure system or browser to use it."
  echo "Ctrl-C to stop."
  ssh -o ProxyCommand="torsocks nc %h %p" -D "$lport" -N "$user@$target"
}

main_loop() {
  while true; do
    show_menu
    read -rp "Choice: " choice
    case "$choice" in
      1) install_tor_and_ssh; pause ;;
      2) create_hidden_ssh; pause ;;
      3) show_onion; pause ;;
      4) remove_hidden_ssh; pause ;;
      5) generate_ssh_keypair; pause ;;
      6) add_public_key_server; pause ;;
      7) connect_onion; pause ;;
      8) create_socks_tunnel; pause ;;
      9) exit 0 ;;
      *) echo "Invalid choice." ;;
    esac
  done
}

main_loop
