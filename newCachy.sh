#!/bin/bash

# CachyOS (Arch-based) post-install script. Port of newMint.sh.
# Official repos for everything, except an optional, clearly-warned AUR section at the end.
# chmod +x newCachy.sh; ./newCachy.sh

set -e

if [[ $EUID -eq 0 ]]; then
    echo "[!] Don't run this as root (user-level settings need your normal user)."
    exit 1
fi

confirm() {
    read -rp "[?] Do you want to $1? [y/N] " choice
    case "$choice" in
        y|Y ) return 0;;
        * ) echo "[-] Skipped."; return 1;;
    esac
}

# Helpers
pac() { sudo pacman -S --needed --noconfirm "$@"; }

# ---------------------------------------------------------------------------
# AUR safety helpers (unofficial packages: warn, show info, require typed confirm)
# ---------------------------------------------------------------------------
ensure_paru() {
    command -v paru &>/dev/null || pac paru
}

# Extract one field from the AUR RPC JSON: _jf <field> <json>
_jf() {
    grep -oP "\"$1\":\K(\"[^\"]*\"|[^,}]*)" <<<"$2" | head -1 | sed 's#\\##g' | tr -d '"'
}

# aur_install <package> "<expected upstream domains>" "<what it is / official site>"
aur_install() {
    local pkg="$1" expected="$2" what="$3"
    local rpc maintainer votes pop first last upurl now pb

    echo
    echo "=============================================================="
    echo "[!] WARNING: '$pkg' is from the AUR (Arch User Repository)."
    echo "    It is NOT an official Arch/CachyOS package. It is a build"
    echo "    script written by a volunteer that runs on YOUR machine,"
    echo "    and nobody reviews it for you. In June 2026, 1,500+ AUR"
    echo "    packages were hijacked with malware (mostly orphaned"
    echo "    packages taken over by attackers)."
    echo "    DOUBLE-CHECK everything below before continuing."
    echo "=============================================================="
    echo "[i] What it is: $what"

    rpc=$(curl -fsS -G "https://aur.archlinux.org/rpc/v5/info" --data-urlencode "arg[]=$pkg") || {
        echo "[!] Could not reach the AUR. Skipping."; return 1; }
    if ! grep -q '"resultcount":1' <<<"$rpc"; then
        echo "[!] '$pkg' was not found in the AUR (renamed or removed?). Skipping."
        return 1
    fi

    maintainer=$(_jf Maintainer "$rpc")
    votes=$(_jf NumVotes "$rpc")
    pop=$(_jf Popularity "$rpc")
    first=$(_jf FirstSubmitted "$rpc")
    last=$(_jf LastModified "$rpc")
    upurl=$(_jf URL "$rpc")
    now=$(date +%s)

    echo
    echo "--- AUR metadata -------------------------------------------"
    echo "  Package:        $pkg"
    echo "  Maintainer:     ${maintainer:-null}"
    echo "  Votes:          $votes   (popularity: $pop)"
    echo "  First submitted: $(date -d "@$first" +%F)  ($(( (now - first) / 86400 )) days ago)"
    echo "  Last modified:   $(date -d "@$last" +%F)  ($(( (now - last) / 86400 )) days ago)"
    echo "  Upstream URL:   $upurl"
    echo "  AUR page:       https://aur.archlinux.org/packages/$pkg"
    echo "  Change history: https://aur.archlinux.org/cgit/aur.git/log/?h=$pkg"
    echo "  (Open the history link and check the maintainer hasn't recently changed.)"

    echo
    echo "--- Red flags ----------------------------------------------"
    local flags=0
    if [[ -z "$maintainer" || "$maintainer" == "null" ]]; then
        echo "  [!!] ORPHANED: no maintainer. This is exactly how the 2026 attack worked."
        echo "       Strongly recommend NOT installing."
        flags=1
    fi
    if (( votes < 30 )); then
        echo "  [!] Low vote count ($votes). Few people have vetted this package."
        flags=1
    fi
    if (( (now - first) / 86400 < 180 )); then
        echo "  [!] Package is less than 6 months old."
        flags=1
    fi
    if (( (now - last) / 86400 < 14 )); then
        echo "  [!] Modified in the last 14 days. Check what changed in the history link."
        flags=1
    fi
    (( flags == 0 )) && echo "  None of the basic checks tripped (this does not prove it is safe)."

    pb=$(mktemp)
    if ! curl -fsS "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=$pkg" -o "$pb"; then
        echo "[!] Couldn't download the PKGBUILD for review. Skipping."
        rm -f "$pb"
        return 1
    fi

    echo
    echo "--- Domains the PKGBUILD references (expected: $expected) ---"
    local d e ok
    while read -r d; do
        [[ -z "$d" ]] && continue
        ok=0
        for e in $expected; do
            [[ "$d" == *"$e" ]] && ok=1
        done
        if (( ok )); then echo "  [ok]         $d"; else echo "  [UNEXPECTED] $d"; fi
    done < <(tr -d "\"'()" < "$pb" | grep -oE 'https?://[^/[:space:]]+' | sed -E 's#https?://##' | sort -u)

    echo
    echo "--- Suspicious commands in the PKGBUILD --------------------"
    echo "  (downloaders, npm/pip, base64, eval, shell -c, sudo, services)"
    if ! grep -n -E '(curl|wget|npm|npx|pip3? install|base64|eval |bash -c|sh -c|nc |chmod \+x|systemctl|sudo|git clone)' "$pb"; then
        echo "  none found"
    fi
    echo "  (Some hits can be legitimate; the question is whether they make sense for this app.)"

    echo
    read -rp "[?] Press Enter to read the full PKGBUILD (q to exit the viewer)... " _
    "${PAGER:-less}" "$pb"
    rm -f "$pb"

    echo
    echo "[i] paru will ALSO show you the PKGBUILD and any .install scripts for review"
    echo "    during the install. Read them, don't just skim past."
    read -rp "[?] To continue, type the package name exactly ('$pkg'), or press Enter to skip: " typed
    if [[ "$typed" != "$pkg" ]]; then
        echo "[-] Skipped $pkg."
        return 1
    fi

    ensure_paru
    paru -S --needed "$pkg"
}

DE="${XDG_CURRENT_DESKTOP,,}"
echo "[i] Detected desktop: ${XDG_CURRENT_DESKTOP:-unknown}"

echo "[*] Updating system..."
sudo pacman -Syu --noconfirm

if confirm "install common tools (curl, git, etc.)"; then
    pac curl wget git fuse2 net-tools unzip pacman-contrib
fi

if confirm "set dark mode"; then
    case "$DE" in
        *kde*)
            plasma-apply-colorscheme BreezeDark || true
            ;;
        *gnome*)
            gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
            gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark' || true
            ;;
        *) echo "[!] Unsupported desktop for this step, set it manually." ;;
    esac
fi

if confirm "enable Night Light"; then
    case "$DE" in
        *kde*)
            kwriteconfig6 --file kwinrc --group NightColor --key Active true
            qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null || true
            ;;
        *gnome*)
            gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true
            ;;
        *) echo "[!] Unsupported desktop for this step, set it manually." ;;
    esac
fi

if confirm "adjust power and idle settings"; then
    case "$DE" in
        *kde*)
            for profile in AC Battery; do
                kwriteconfig6 --file powerdevilrc --group "$profile" --group Display --key DimDisplayWhenIdle false
                kwriteconfig6 --file powerdevilrc --group "$profile" --group Display --key TurnOffDisplayWhenIdle false
                kwriteconfig6 --file powerdevilrc --group "$profile" --group SuspendAndShutdown --key AutoSuspendAction 0
                kwriteconfig6 --file powerdevilrc --group "$profile" --group SuspendAndShutdown --key LidAction 0
            done
            kwriteconfig6 --file kscreenlockerrc --group Daemon --key Autolock false
            systemctl --user restart plasma-powerdevil.service 2>/dev/null || true
            echo "[i] Mouse flat accel profile on KDE is per-device: System Settings > Mouse & Touchpad."
            ;;
        *gnome*)
            gsettings set org.gnome.settings-daemon.plugins.power idle-dim false
            gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
            gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
            gsettings set org.gnome.desktop.screensaver lock-enabled false
            gsettings set org.gnome.desktop.session idle-delay 0
            gsettings set org.gnome.desktop.peripherals.mouse accel-profile 'flat' || true
            ;;
        *) echo "[!] Unsupported desktop for this step, set it manually." ;;
    esac
fi

if confirm "install NVIDIA 32-bit support (needed for Steam/Wine games)"; then
    if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
        echo "[!] multilib repo is not enabled in /etc/pacman.conf. Enable it first."
    else
        pac lib32-nvidia-utils
    fi
fi

if confirm "install Steam"; then
    if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
        echo "[!] multilib repo is not enabled in /etc/pacman.conf. Enable it first."
    else
        pac steam
    fi
fi

if confirm "install the CachyOS gaming meta packages (Wine, gamemode, mangohud, etc.)"; then
    pac cachyos-gaming-meta cachyos-gaming-applications
fi

if confirm "install ffmpeg"; then
    pac ffmpeg
fi

if confirm "install Discord"; then
    pac discord
fi

if confirm "install Code - OSS (open-source VS Code build, official repo)"; then
    pac code
fi

if confirm "create and activate a new python virtual environment"; then
    pac python python-pip
    python3 -m venv "$HOME/.venv"
    # shellcheck disable=SC1091
    source "$HOME/.venv/bin/activate"
    pip install --upgrade pip
    echo "[i] Activate later with: source ~/.venv/bin/activate  (fish: source ~/.venv/bin/activate.fish)"
fi

if confirm "install VLC"; then
    pac vlc vlc-plugins-all
fi

if confirm "install Xournal++ (pdf editor)"; then
    pac xournalpp
fi

if confirm "install Signal"; then
    pac signal-desktop
fi

if confirm "install Bitwarden Desktop"; then
    pac bitwarden
fi

echo "[i] Bitwarden SSH agent setup requires a few manual steps first:"
echo "    1. Open Bitwarden Desktop"
echo "    2. Log in to your account"
echo "    3. Go to Settings and enable the SSH agent"
if confirm "confirm you've done the above and add SSH_AUTH_SOCK to your shell config"; then
    _bw_sock="${HOME}/.bitwarden-ssh-agent.sock"
    case "$SHELL" in
        */fish)
            _bw_rc="$HOME/.config/fish/config.fish"
            _bw_line="set -gx SSH_AUTH_SOCK $_bw_sock"
            mkdir -p "$(dirname "$_bw_rc")"
            ;;
        */zsh)
            _bw_rc="$HOME/.zshrc"
            _bw_line="export SSH_AUTH_SOCK=$_bw_sock"
            ;;
        *)
            _bw_rc="$HOME/.bashrc"
            _bw_line="export SSH_AUTH_SOCK=$_bw_sock"
            ;;
    esac
    grep -qxF "$_bw_line" "$_bw_rc" 2>/dev/null || echo "$_bw_line" >> "$_bw_rc"
    echo "[i] Added SSH_AUTH_SOCK export to $_bw_rc"
fi

if confirm "modify bootloader timeout to 3 seconds"; then
    if [[ -f /etc/default/grub ]] && command -v grub-mkconfig &>/dev/null; then
        echo "[*] Detected GRUB."
        sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub
        sudo sed -i 's/^#\?\s*GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
        sudo grub-mkconfig -o /boot/grub/grub.cfg
    elif command -v bootctl &>/dev/null && _esp=$(bootctl --print-esp-path 2>/dev/null) && [[ -f "$_esp/loader/loader.conf" ]]; then
        echo "[*] Detected systemd-boot."
        _lc="$_esp/loader/loader.conf"
        if sudo grep -q '^#\?timeout' "$_lc"; then
            sudo sed -i 's/^#\?timeout.*/timeout 3/' "$_lc"
        else
            echo "timeout 3" | sudo tee -a "$_lc" > /dev/null
        fi
    else
        echo "[!] Couldn't detect GRUB or systemd-boot (Limine/rEFInd?). Edit the timeout manually."
    fi
fi

if confirm "disable lid switch actions in systemd"; then
    sudo mkdir -p /etc/systemd/logind.conf.d
    sudo tee /etc/systemd/logind.conf.d/lid.conf > /dev/null <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
    echo "[i] Takes effect after a reboot (restarting logind would kill your session)."
fi

if confirm "install wine for .exe programs"; then
    if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
        echo "[!] multilib repo is not enabled in /etc/pacman.conf. Enable it first."
    else
        pac wine winetricks wine-mono wine-gecko
    fi
fi

if confirm "install qBittorrent"; then
    pac qbittorrent
fi

# ---------------------------------------------------------------------------
# AUR section: unofficial packages. Each one shows metadata, red flags, the
# PKGBUILD, and requires you to type the package name before installing.
# ---------------------------------------------------------------------------
echo
echo "[!] The next steps install UNOFFICIAL AUR packages (MEGAsync, Eddie, AppImageLauncher)."
echo "    Each one will show a warning plus info to verify before anything is installed."
if confirm "continue to the AUR section"; then

    if confirm "install MEGAsync (AUR, unofficial)"; then
        if command -v megasync &>/dev/null; then
            echo "[*] MEGAsync is already installed. Skipping."
        else
            aur_install megasync-bin "mega.nz" \
                "MEGA cloud sync client. Official site: https://mega.nz. Sources should only point at mega.nz." || true
        fi
    fi

    if confirm "install Eddie (AUR, unofficial)"; then
        aur_install eddie-ui "eddie.website airvpn.org" \
            "AirVPN's Eddie VPN client. Official site: https://eddie.website. Sources should point at eddie.website/airvpn.org." || true
    fi

    if confirm "install AppImageLauncher (AUR, unofficial)"; then
        aur_install appimagelauncher "github.com" \
            "AppImage integration tool. Official repo: https://github.com/TheAssassin/AppImageLauncher. Sources should be that GitHub repo only." || true
    fi
fi

if confirm "remove orphaned packages and clean the package cache"; then
    _orphans=$(pacman -Qdtq || true)
    if [[ -n "$_orphans" ]]; then
        # shellcheck disable=SC2086
        sudo pacman -Rns --noconfirm $_orphans
    else
        echo "[*] No orphans found."
    fi
    sudo paccache -rk2
fi

if confirm "autostart Steam, Discord and MEGAsync on login (skips anything not installed)"; then
    mkdir -p "$HOME/.config/autostart"
    for app in steam discord megasync; do
        if [[ -f "/usr/share/applications/$app.desktop" ]]; then
            cp "/usr/share/applications/$app.desktop" "$HOME/.config/autostart/"
            echo "[+] Autostart added: $app"
        else
            echo "[-] $app.desktop not found, skipping."
        fi
    done
fi

echo "[*] Checking CUDA versions..."

_driver=$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: \([0-9.]*\).*/\1/p' | head -1)
_nvcc=$(command -v nvcc || true)
[[ -z "$_nvcc" && -x /opt/cuda/bin/nvcc ]] && _nvcc=/opt/cuda/bin/nvcc
_toolkit=$([[ -n "$_nvcc" ]] && "$_nvcc" --version 2>/dev/null | sed -n 's/.*release \([0-9.]*\).*/\1/p' | tail -1)
_nvrtc=$(ldconfig -p 2>/dev/null | grep -m1 'libnvrtc.so' | sed 's/.*libnvrtc.so.\([0-9.]*\).*/\1/')

echo "[i] Driver CUDA:  ${_driver:-not found}"
echo "[i] Toolkit:      ${_toolkit:-not found}"
echo "[i] NVRTC:        ${_nvrtc:-not found}"

if [[ -n "$_driver" && -n "$_toolkit" ]] &&
   (( ${_toolkit%%.*} < ${_driver%%.*} )); then
    echo "[!] Potential CUDA/NVRTC mismatch."
    echo "[i] Suggested checks:"
    echo "    pacman -Qi cuda"
    echo "    pacman -Si cuda"
    echo "    ldconfig -p | grep nvrtc"
    echo "    sudo pacman -S cuda"
fi

case "$DE" in
    *kde*)
        echo "[i] To move the panel: right-click the panel -> 'Enter Edit Mode', then use the screen-edge button to pick the bottom."
        ;;
    *gnome*)
        echo "[i] GNOME's top bar can't be moved natively. Use the Dash to Panel extension for a bottom panel."
        ;;
esac
echo "[i] Firefox: install the uBlock Origin add-on and review Settings > Privacy & Security (telemetry/studies)."
echo "[i] Autostart entries can be managed in System Settings > Autostart (KDE) or ~/.config/autostart."
echo "[✔] Setup complete. You may need to reboot for all changes to take effect."
