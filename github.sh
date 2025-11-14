#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------
# Minimal Git & SSH setup script
# - Ensures SSH key exists (ed25519), creates one if missing
# - Configures Git username/email, adds SSH key to agent
# - Clones one or many GitHub repos (SSH URLs)
# Required: --username, --email
# Optional: --repos "repo1,repo2", --outdir DIR
# 
# Direct Usage: curl -sSL https://raw.githubusercontent.com/DaUmega/miscTools/main/github.sh | bash -s -- --username NAME --email EMAIL
# -------------------------------------------------------

USERNAME=""
EMAIL=""
REPOS=""
OUTDIR="${HOME}/Downloads"
SSH_DIR="${HOME}/.ssh"

msg() { echo -e "\033[1;32m[+] $*\033[0m"; }

usage() {
    cat <<EOF
Usage: $0 --username NAME --email EMAIL [--repos repo1,repo2] [--outdir DIR]

Required:
  --username    Git username (also used as repo owner)
  --email       Git email (does NOT need to match GitHub)

Optional:
  --repos       Comma-separated repo names to clone
  --outdir      Directory to clone repos into (default: ~/Downloads)
  --help        Show this help

Examples:
  $0 --username alice --email a@b.com
  $0 --username bob --email bob@site.com --repos Tools,ProjectX
  $0 --username you --email me@mail.com --repos R1,R2 --outdir ~/workspace
EOF
    exit 1
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --username) USERNAME="$2"; shift 2 ;;
        --email) EMAIL="$2"; shift 2 ;;
        --repos) REPOS="$2"; shift 2 ;;
        --outdir) OUTDIR="$2"; shift 2 ;;
        --help) usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

# --- Validate required args ---
[[ -z "$USERNAME" ]] && echo "Missing: --username" && usage
[[ -z "$EMAIL" ]] && echo "Missing: --email" && usage

# --- Prepare output directory ---
mkdir -p "$OUTDIR"

msg "Using username: $USERNAME"
msg "Using email: $EMAIL"
msg "Clone directory: $OUTDIR"

# -------------------------------------------------------
# 1. SSH Setup
# -------------------------------------------------------
msg "Ensuring SSH directory exists..."
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

if [ ! -f "${SSH_DIR}/id_ed25519" ]; then
    msg "No SSH key found. Generating a new ed25519 key..."
    ssh-keygen -t ed25519 -C "${EMAIL}" -f "${SSH_DIR}/id_ed25519" -N ""
    msg "SSH key generated."

    echo ""
    echo "👉 Add this public key to GitHub:"
    echo "   https://github.com/settings/keys"
    echo ""
    cat "${SSH_DIR}/id_ed25519.pub"
    echo ""

    command -v xdg-open >/dev/null && xdg-open "https://github.com/settings/keys" >/dev/null 2>&1 &
    read -p "Press Enter after adding your key to GitHub..." < /dev/tty
else
    msg "SSH key already exists."
fi

# -------------------------------------------------------
# 2. Start SSH Agent
# -------------------------------------------------------
if ! pgrep -u "$USER" ssh-agent >/dev/null; then
    msg "Starting SSH agent..."
    eval "$(ssh-agent -s)"
else
    msg "SSH agent already running."
fi

msg "Adding SSH key to agent..."
ssh-add -D || true
ssh-add "${SSH_DIR}/id_ed25519"

# -------------------------------------------------------
# 3. Configure Git
# -------------------------------------------------------
msg "Configuring Git..."
git config --global user.email "${EMAIL}"
git config --global user.name "${USERNAME}"
git config --global http.sslverify false

# -------------------------------------------------------
# 4. Clone repositories (if provided)
# -------------------------------------------------------
if [[ -n "$REPOS" ]]; then
    IFS=',' read -ra REPO_LIST <<< "$REPOS"

    msg "Cloning repositories: ${REPO_LIST[*]}"

    for repo in "${REPO_LIST[@]}"; do
        repo_dir="${OUTDIR}/${repo}"
        repo_url="git@github.com:${USERNAME}/${repo}.git"

        if [ -d "${repo_dir}/.git" ]; then
            msg "Repo '${repo}' already exists. Pulling latest..."
            (cd "${repo_dir}" && git pull --rebase)
        else
            msg "Cloning ${repo}..."
            rm -rf "${repo_dir}" 2>/dev/null || true
            git clone "${repo_url}" "${repo_dir}"
        fi

        msg "Ensuring '${repo}' uses SSH..."
        (cd "${repo_dir}" && git remote set-url origin "${repo_url}")
    done
else
    msg "No repos specified. Setup finished without cloning."
fi

msg "Setup complete!"
