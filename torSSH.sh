#!/usr/bin/env bash
# tor-ssh: minimal Tor hidden-service SSH toolkit.
#
# Direct run, no TTY (everything comes in as args; needs passwordless sudo or root):
#   curl -fsSL https://raw.githubusercontent.com/DaUmega/miscTools/refs/heads/main/torSSH.sh | bash -s -- install
#
#   install                  server: install tor + openssh, harden sshd
#   serve                    server: create hidden service, print .onion
#   unserve                  server: remove hidden service
#   onion                    server: show .onion address
#   keygen [--force]         client: new ed25519 keypair, print pubkey
#   auth "ssh-ed25519 AAAA"  server: add pubkey to authorized_keys
#   connect user@onion       client: ssh to .onion over tor
#   tunnel user@onion [port] client: SOCKS5 proxy over tor (default 1080)
set -euo pipefail

TOR_HS_DIR=/var/lib/tor/ssh_hidden
TORRC=/etc/tor/torrc
SSHD=/etc/ssh/sshd_config
TOR_SOCKS=${TOR_SOCKS:-127.0.0.1:9050}   # e.g. 127.0.0.1:9150 for Tor Browser
BEGIN="# BEGIN tor-ssh"
END="# END tor-ssh"

die() { echo "error: $*" >&2; exit 1; }

install_pkgs() {
  if command -v apt-get >/dev/null; then
    sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  elif command -v dnf >/dev/null; then sudo dnf install -y -q "$@"
  elif command -v pacman >/dev/null; then sudo pacman -Sy --noconfirm "$@"
  else die "unsupported distro; install manually: $*"; fi
}

need_nc() { # client-side: ensure an nc that can do SOCKS5 exists
  command -v nc >/dev/null && return 0
  if command -v pacman >/dev/null; then install_pkgs openbsd-netcat
  elif command -v dnf >/dev/null; then install_pkgs nmap-ncat
  else install_pkgs netcat-openbsd; fi
}

proxy_cmd() { # ProxyCommand resolving .onion through tor's SOCKS
  if nc -h 2>&1 | grep -q '\-X'; then echo "nc -X 5 -x $TOR_SOCKS %h %p"
  else echo "ncat --proxy-type socks5 --proxy $TOR_SOCKS %h %p"; fi
}

sshd_set() { # sshd_set Key value — replace (commented or active) or append
  sudo sed -i -E "s/^#?${1}[[:space:]].*/${1} ${2}/" "$SSHD"
  sudo grep -qiE "^${1}[[:space:]]" "$SSHD" || echo "${1} ${2}" | sudo tee -a "$SSHD" >/dev/null
}

tor_user() {
  local u
  for u in debian-tor tor toranon _tor; do
    id "$u" >/dev/null 2>&1 && { echo "$u"; return 0; }
  done
  return 1
}

cmd_install() {
  [ -f "$SSHD" ] || die "no $SSHD"
  install_pkgs tor openssh-server
  sudo systemctl enable --now tor
  sudo systemctl enable --now ssh 2>/dev/null || sudo systemctl enable --now sshd
  # never kill password auth before a key exists — that's how lockouts happen
  local home; home=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
  [ -s "$home/.ssh/authorized_keys" ] || die "no authorized_keys for ${SUDO_USER:-$USER}; run keygen + auth first"
  sudo cp -n "$SSHD" "$SSHD.bak.$(date +%s)"
  sshd_set PasswordAuthentication no
  sshd_set KbdInteractiveAuthentication no
  sshd_set PermitRootLogin no
  sshd_set PubkeyAuthentication yes
  sudo sshd -t
  sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd
  echo "installed and hardened"
}

cmd_serve() {
  sudo mkdir -p "$TOR_HS_DIR"
  local u; u=$(tor_user || true)
  [ -n "$u" ] && sudo chown "$u:$u" "$TOR_HS_DIR"
  sudo chmod 700 "$TOR_HS_DIR"
  if ! sudo grep -qF "$BEGIN" "$TORRC"; then
    printf '\n%s\nHiddenServiceDir %s\nHiddenServicePort 22 127.0.0.1:22\n%s\n' \
      "$BEGIN" "$TOR_HS_DIR" "$END" | sudo tee -a "$TORRC" >/dev/null
  fi
  sudo systemctl restart tor
  local i; for i in {1..10}; do
    sudo test -f "$TOR_HS_DIR/hostname" && break
    sleep 1
  done
  sudo cat "$TOR_HS_DIR/hostname" 2>/dev/null || die "no hostname yet; see 'sudo journalctl -u tor'"
}

cmd_unserve() {
  sudo sed -i "/$BEGIN/,/$END/d" "$TORRC"
  sudo rm -rf "$TOR_HS_DIR"
  sudo systemctl restart tor
  echo "hidden service removed"
}

cmd_onion() { sudo cat "$TOR_HS_DIR/hostname"; }

cmd_keygen() { # keygen [--force]
  if [ -e ~/.ssh/id_ed25519 ] && [ "${1:-}" != "--force" ]; then
    die "key exists; pass --force to overwrite"
  fi
  [ "${1:-}" = "--force" ] && rm -f ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub
  install -m 700 -d ~/.ssh
  ssh-keygen -q -t ed25519 -f ~/.ssh/id_ed25519 -N ""
  cat ~/.ssh/id_ed25519.pub
}

cmd_auth() {
  local key=${1:?usage: tor-ssh auth '"ssh-ed25519 AAAA…"'}
  install -m 700 -d ~/.ssh
  touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
  grep -qxF "$key" ~/.ssh/authorized_keys || echo "$key" >> ~/.ssh/authorized_keys
  echo "key added"
}

cmd_connect() { # connect user@onion [extra ssh args…]
  need_nc
  ssh -o "ProxyCommand=$(proxy_cmd)" "$@"
}

cmd_tunnel() { # tunnel user@onion [port]
  local target=${1:?usage: tor-ssh tunnel user@onion [port]} port=${2:-1080}
  need_nc
  echo "SOCKS5 on 127.0.0.1:$port — Ctrl-C to stop"
  exec ssh -o "ProxyCommand=$(proxy_cmd)" -D "$port" -N "$target"
}

usage() {
  cat <<EOF
usage: tor-ssh <command>
  install                  server: install tor + openssh, harden sshd
  serve                    server: create hidden service, print .onion
  unserve                  server: remove hidden service
  onion                    server: show .onion address
  keygen [--force]         client: new ed25519 keypair, print pubkey
  auth "ssh-ed25519 AAAA"  server: add pubkey to authorized_keys
  connect user@onion       client: ssh to .onion over tor
  tunnel user@onion [port] client: SOCKS5 proxy over tor (default 1080)
env: TOR_SOCKS (default 127.0.0.1:9050)
EOF
  exit 1
}

case "${1:-}" in
  install|serve|unserve|onion|keygen|auth|connect|tunnel) "cmd_$1" "${@:2}" ;;
  *) usage ;;
esac
