#!/bin/bash
# CachyOS post-install script (port of newMint.sh). Official repos only, plus an optional, heavily-warned AUR section.
set -e
[[ $EUID -eq 0 ]] && { echo "[!] Don't run as root."; exit 1; }

confirm() { read -rp "[?] Do you want to $1? [y/N] " c; [[ $c == [yY] ]] || { echo "[-] Skipped."; return 1; }; }
pac() { sudo pacman -S --needed --noconfirm "$@"; }

case "$SHELL" in
    */fish) RC=~/.config/fish/config.fish; FISH=1; mkdir -p "${RC%/*}" ;;
    */zsh)  RC=~/.zshrc ;;
    *)      RC=~/.bashrc ;;
esac
rc_add() { # rc_add "<bash/zsh line>" "<fish line>"
    local l=$1; [[ -n $FISH ]] && l=$2
    grep -qxF "$l" "$RC" 2>/dev/null || echo "$l" >> "$RC"
}

jf() { grep -oP "\"$1\":\K(\"[^\"]*\"|[^,}]*)" <<<"$2" | head -1 | tr -d '"\\'; }

aur() { # aur <pkg> <expected-domain-regex> <note>
    local p=$1 dom=$2 j pb m v
    echo -e "\n[!] '$p' is from the AUR: NOT official, an unreviewed build script that runs as you."
    echo "    (June 2026: 1,500+ AUR packages were hijacked, mostly orphaned ones.) $3"
    j=$(curl -fsSG https://aur.archlinux.org/rpc/v5/info --data-urlencode "arg[]=$p") && grep -q '"resultcount":1' <<<"$j" \
        || { echo "[!] Not found or AUR unreachable, skipping."; return 1; }
    m=$(jf Maintainer "$j"); v=$(jf NumVotes "$j")
    echo "  Maintainer: $m | Votes: $v | Last modified: $(date -d "@$(jf LastModified "$j")" +%F)"
    echo "  Upstream:   $(jf URL "$j")"
    echo "  History:    https://aur.archlinux.org/cgit/aur.git/log/?h=$p (check for recent maintainer changes)"
    [[ $m == null ]] && echo "  [!!] ORPHANED: exactly how the 2026 attack worked. Don't install."
    (( v < 30 )) && echo "  [!] Few votes: little community vetting."
    pb=$(mktemp)
    curl -fsS "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=$p" -o "$pb" || { echo "[!] PKGBUILD fetch failed, skipping."; return 1; }
    echo "  Domains in PKGBUILD (expected: $dom):"
    tr -d "\"'()" <"$pb" | grep -oE 'https?://[^/[:space:]]+' | sed -E 's#https?://##' | sort -u \
        | sed -E "/($dom)\$/!s/^/[UNEXPECTED] /;s/^/    /"
    echo "  Suspicious commands in PKGBUILD:"
    grep -nE 'curl|wget|npm|npx|pip3? install|base64|eval |sh -c|nc |chmod \+x|sudo|git clone' "$pb" || echo "    none"
    read -rp "[?] Enter to read the full PKGBUILD... " _; "${PAGER:-less}" "$pb"; rm -f "$pb"
    read -rp "[?] Type '$p' to install (anything else skips; paru will show its own review too): " t
    [[ $t == "$p" ]] || { echo "[-] Skipped."; return 1; }
    command -v paru &>/dev/null || pac paru
    paru -S --needed "$p"
}

echo "[*] Updating system..."
sudo pacman -Syu --noconfirm

# Official-repo packages: "prompt|packages"
for item in \
    "install common tools|curl wget git fuse2 net-tools unzip pacman-contrib" \
    "install gaming support (CachyOS gaming meta + apps incl. Proton-CachyOS, plus Steam)|cachyos-gaming-meta cachyos-gaming-applications steam" \
    "install ffmpeg|ffmpeg" \
    "install Discord|discord" \
    "install Code - OSS (open-source VS Code)|code" \
    "install VLC|vlc vlc-plugins-all" \
    "install Xournal++|xournalpp" \
    "install Signal|signal-desktop" \
    "install Bitwarden|bitwarden" \
    "install qBittorrent|qbittorrent"; do
    if confirm "${item%%|*}"; then pac ${item#*|}; fi
done

if command -v nvidia-smi &>/dev/null && ! pacman -Qq lib32-nvidia-utils &>/dev/null; then
    echo "[!] NVIDIA GPU found but lib32-nvidia-utils is missing (needed for 32-bit games). Install the one matching your driver (see: chwd --list-installed)."
fi

if confirm "raise the NVIDIA shader cache limit to 12GB (CachyOS wiki tip, avoids recompiling shaders)"; then
    mkdir -p ~/.config/environment.d
    echo "__GL_SHADER_DISK_CACHE_SIZE=12000000000" > ~/.config/environment.d/gaming.conf
fi

if confirm "create a python virtual environment (~/.venv)"; then
    pac python python-pip
    python -m venv ~/.venv
    echo "[i] Activate: source ~/.venv/bin/activate (fish: activate.fish)"
fi

if command -v kwriteconfig6 &>/dev/null; then
    if confirm "set dark mode"; then plasma-apply-colorscheme BreezeDark || true; fi
    if confirm "enable Night Light"; then
        kwriteconfig6 --file kwinrc --group NightColor --key Active true
        qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null || true
    fi
    if confirm "disable idle dimming/sleep, lid actions and screen lock"; then
        for p in AC Battery; do
            kwriteconfig6 --file powerdevilrc --group $p --group Display --key DimDisplayWhenIdle false
            kwriteconfig6 --file powerdevilrc --group $p --group Display --key TurnOffDisplayWhenIdle false
            kwriteconfig6 --file powerdevilrc --group $p --group SuspendAndShutdown --key AutoSuspendAction 0
            kwriteconfig6 --file powerdevilrc --group $p --group SuspendAndShutdown --key LidAction 0
        done
        kwriteconfig6 --file kscreenlockerrc --group Daemon --key Autolock false
        systemctl --user restart plasma-powerdevil.service 2>/dev/null || true
    fi
else
    echo "[i] KDE tools not found, skipping desktop settings."
fi

if confirm "disable shell history (and delete existing history files)"; then
    rc_add 'unset HISTFILE; SAVEHIST=0' "set -g fish_history ''"
    rm -f ~/.bash_history ~/.zsh_history ~/.local/share/fish/fish_history
    echo "[i] Applies to new shells ($RC)."
fi

echo "[i] Bitwarden SSH agent: open Bitwarden, log in, and enable the SSH agent in Settings first."
if confirm "add SSH_AUTH_SOCK to $RC"; then
    rc_add "export SSH_AUTH_SOCK=$HOME/.bitwarden-ssh-agent.sock" "set -gx SSH_AUTH_SOCK $HOME/.bitwarden-ssh-agent.sock"
fi

if confirm "set bootloader timeout to 3 seconds"; then
    if [[ -f /etc/default/grub ]] && command -v grub-mkconfig &>/dev/null; then
        sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/;s/^#\?\s*GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
        sudo grub-mkconfig -o /boot/grub/grub.cfg
    elif lc="$(bootctl --print-esp-path 2>/dev/null)/loader/loader.conf" && [[ -f $lc ]]; then
        sudo sed -i '/^#\?timeout/d' "$lc"; echo "timeout 3" | sudo tee -a "$lc" >/dev/null
    else
        echo "[!] Unsupported bootloader, edit the timeout manually."
    fi
fi

if confirm "ignore lid switch in systemd (takes effect after reboot)"; then
    sudo mkdir -p /etc/systemd/logind.conf.d
    printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\n' \
        | sudo tee /etc/systemd/logind.conf.d/lid.conf >/dev/null
fi

echo -e "\n[!] Next: UNOFFICIAL AUR packages (MEGAsync, Eddie, AppImageLauncher). Each shows a warning and info to verify first."
if confirm "continue to the AUR section"; then
    if confirm "install MEGAsync (AUR)"; then
        aur megasync-bin "mega.nz" "Official site: mega.nz; sources should only point there." || true
    fi
    if confirm "install Eddie (AUR)"; then
        aur eddie-ui "eddie.website|airvpn.org" "Official site: eddie.website." || true
    fi
    if confirm "install AppImageLauncher (AUR)"; then
        aur appimagelauncher "github.com" "Official repo: github.com/TheAssassin/AppImageLauncher." || true
    fi
    if confirm "install Canon imageCLASS MF3010 printer driver (CUPS + AUR)"; then
        pac cups
        sudo systemctl enable --now cups
        if aur cnrdrvcups-lb-bin "c-wss.com|canon-europe.com" "Canon UFR II driver. Downloads from Canon's CDN (c-wss.com)."; then
            sudo systemctl restart cups
            echo "[i] Plug in the printer, then add it in System Settings > Printers and pick the Canon MF3010 driver."
        fi
    fi
fi

if confirm "remove orphaned packages and clean the package cache"; then
    o=$(pacman -Qdtq || true)
    [[ -n $o ]] && sudo pacman -Rns --noconfirm $o
    sudo paccache -rk2
fi

if confirm "autostart Steam, Discord and MEGAsync on login (if installed)"; then
    mkdir -p ~/.config/autostart
    for a in steam discord megasync; do
        [[ -f /usr/share/applications/$a.desktop ]] && cp /usr/share/applications/$a.desktop ~/.config/autostart/
    done
fi

d=$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: \([0-9.]*\).*/\1/p' | head -1)
t=$(PATH=$PATH:/opt/cuda/bin nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9.]*\).*/\1/p' | tail -1)
n=$(ldconfig -p | grep -m1 libnvrtc.so | sed 's/.*libnvrtc.so.\([0-9.]*\).*/\1/')
echo "[i] CUDA driver: ${d:-n/a} | toolkit: ${t:-n/a} | NVRTC: ${n:-n/a}"
[[ -n $d && -n $t ]] && (( ${t%%.*} < ${d%%.*} )) && echo "[!] Possible CUDA mismatch. Check: pacman -Qi cuda; sudo pacman -S cuda"

echo "[i] Firefox: add uBlock Origin and review Settings > Privacy & Security. Move the panel: right-click it > Enter Edit Mode."
echo "[✔] Setup complete. Reboot for all changes to take effect."
