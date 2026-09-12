#!/bin/bash

# wget https://raw.githubusercontent.com/DaUmega/miscTools/main/newMint.sh; chmod +x newMint.sh; ./newMint.sh

set -e

confirm() {
    read -p "[?] Do you want to $1? [y/N] " choice
    case "$choice" in
        y|Y ) return 0;;
        * ) echo "[-] Skipped."; return 1;;
    esac
}

echo "[*] Updating system..."
sudo apt update && sudo apt upgrade -y

if confirm "install common tools (curl, git, etc.)"; then
    sudo apt install -y curl git libfuse2 software-properties-common net-tools
fi

if confirm "set dark mode"; then
    gsettings set org.cinnamon.desktop.interface gtk-theme 'Mint-Y-Dark'
    gsettings set org.cinnamon.theme name 'Mint-Y-Dark'
    gsettings set org.cinnamon.desktop.interface color-scheme 'prefer-dark' || true
fi

if confirm "enable Night Light"; then
    gsettings set org.cinnamon.settings-daemon.plugins.color night-light-enabled true
fi

if confirm "adjust power and idle settings"; then
    gsettings set org.cinnamon.settings-daemon.plugins.power idle-dim-ac false
    gsettings set org.cinnamon.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
    gsettings set org.cinnamon.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
    gsettings set org.cinnamon.desktop.screensaver lock-enabled false
    gsettings set org.cinnamon.desktop.session idle-delay 0
    gsettings set org.cinnamon.settings-daemon.plugins.power lid-close-ac-action 'nothing'
    gsettings set org.cinnamon.settings-daemon.plugins.power lid-close-battery-action 'nothing'
    gsettings set org.cinnamon.desktop.peripherals.mouse accel-profile 'flat' || true
fi

if confirm "install NVIDIA 32-bit support"; then
    sudo dpkg --add-architecture i386
    sudo apt update
    sudo apt install -y libnvidia-gl-550:i386
fi

if confirm "install Brave Browser"; then
    curl -fsS https://dl.brave.com/install.sh | sh
fi

if confirm "remove Firefox"; then
    sudo apt remove --purge -y firefox
    sudo snap remove firefox 2>/dev/null || true
fi

if confirm "install Steam"; then
    sudo dpkg --add-architecture i386
    curl -L -o /tmp/steam.deb https://cdn.fastly.steamstatic.com/client/installer/steam.deb
    sudo apt install -y /tmp/steam.deb
    rm -f /tmp/steam.deb
fi

if confirm "install ffmpeg"; then
    sudo apt install -y ffmpeg
fi

if confirm "install Discord"; then
    curl -L -o /tmp/discord.deb "https://discord.com/api/download?platform=linux&format=deb"
    sudo apt install -y /tmp/discord.deb
    rm -f /tmp/discord.deb
fi

if confirm "install MEGAsync"; then
    if command -v megasync &> /dev/null; then
        echo "[*] MEGAsync is already installed. Skipping."
    else
        wget -P /home/$USER/Downloads https://mega.nz/linux/repo/xUbuntu_24.04/amd64/megasync-xUbuntu_24.04_amd64.deb
        sudo apt install -y "/home/$USER/Downloads/megasync-xUbuntu_24.04_amd64.deb"
        rm /home/$USER/Downloads/megasync*
    fi
fi

if confirm "install VS Code"; then
    sudo apt install -y wget gpg
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /tmp/packages.microsoft.gpg
    sudo install -D -o root -g root -m 644 /tmp/packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
    echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
    rm -f /tmp/packages.microsoft.gpg
    sudo apt update
    sudo apt install -y code
fi

if confirm "create and activate a new python virtual environment"; then
    sudo apt install -y python3-venv
    python3 -m venv "$HOME/.venv"
    source "$HOME/.venv/bin/activate"
    pip install --upgrade pip
fi

if confirm "install VLC"; then
    sudo apt install vlc -y
fi

if confirm "install Xournal (pdf editor)"; then
    sudo apt install xournalpp -y
fi

if confirm "install Signal"; then
    curl https://updates.signal.org/desktop/apt/keys.asc | gpg --dearmor > signal-desktop-keyring.gpg
    cat signal-desktop-keyring.gpg | sudo tee /usr/share/keyrings/signal-desktop-keyring.gpg > /dev/null
    curl -o signal-desktop.sources https://updates.signal.org/static/desktop/apt/signal-desktop.sources
    cat signal-desktop.sources | sudo tee /etc/apt/sources.list.d/signal-desktop.sources > /dev/null
    sudo apt update && sudo apt install signal-desktop -y
fi

if confirm "install Bitwarden Desktop"; then
    curl -L -o /tmp/bitwarden.deb "https://bitwarden.com/download/?app=desktop&platform=linux&variant=deb"
    sudo apt install -y /tmp/bitwarden.deb
    rm -f /tmp/bitwarden.deb
fi

echo "[i] Bitwarden SSH agent setup requires a few manual steps first:"
echo "    1. Open Bitwarden Desktop"
echo "    2. Log in to your account"
echo "    3. Go to Settings and enable the SSH agent"
if confirm "confirm you've done the above and add SSH_AUTH_SOCK to your shell config"; then
    _bw_sock_line="export SSH_AUTH_SOCK=${HOME}/.bitwarden-ssh-agent.sock"
    case "$SHELL" in
        */zsh) _bw_rc="$HOME/.zshrc" ;;
        *) _bw_rc="$HOME/.bashrc" ;;
    esac
    grep -qxF "$_bw_sock_line" "$_bw_rc" 2>/dev/null || echo "$_bw_sock_line" >> "$_bw_rc"
    echo "[i] Added SSH_AUTH_SOCK export to $_bw_rc"
fi

if confirm "install AppImageLauncher"; then
    echo "[i] Your architecture: $(dpkg --print-architecture)"
    echo "[i] Download page: https://github.com/TheAssassin/AppImageLauncher/releases"
    read -p "[?] Paste the .deb download URL for your arch: " _ail_url
    _ail_filename=$(basename "$_ail_url")
    wget -O "/tmp/$_ail_filename" "$_ail_url"
    sudo apt install -y "/tmp/$_ail_filename"
    rm -f "/tmp/$_ail_filename"
    echo "[+] AppImageLauncher installed successfully."
fi

if confirm "modify GRUB timeout to 3 seconds"; then
    sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub
    sudo sed -i 's/^#\?\s*GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
    sudo update-grub
fi

if confirm "disable lid switch actions in systemd"; then
    sudo sed -i 's/^#HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
    sudo sed -i 's/^#HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf
    sudo sed -i 's/^#HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' /etc/systemd/logind.conf
fi

if confirm "install wine for .exe programs"; then
    sudo dpkg --add-architecture i386
    sudo mkdir -pm755 /etc/apt/keyrings
    wget -O - https://dl.winehq.org/wine-builds/winehq.key | sudo gpg --dearmor -o /etc/apt/keyrings/winehq-archive.key -
    sudo wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources
    sudo apt update
    sudo apt install -y --install-recommends winehq-stable
fi

if confirm "install Eddie"; then
    sudo curl -fsSL https://eddie.website/repository/keys/eddie_maintainer_gpg.key | sudo tee /usr/share/keyrings/eddie.website-keyring.asc > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/eddie.website-keyring.asc] http://eddie.website/repository/apt stable main" | sudo tee /etc/apt/sources.list.d/eddie.website.list > /dev/null
    sudo apt update
    sudo apt install -y eddie-ui
fi

if confirm "install qBitTorrent"; then
    sudo add-apt-repository -y ppa:qbittorrent-team/qbittorrent-stable
    sudo apt update
    sudo apt install -y qbittorrent
fi

if confirm "run autoremove and autoclean"; then
    sudo apt autoremove -y
    sudo apt autoclean -y
fi

echo "[*] Checking CUDA versions..."

_driver=$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: \([0-9.]*\).*/\1/p' | head -1)
_toolkit=$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9.]*\).*/\1/p' | tail -1)
_nvrtc=$(ldconfig -p 2>/dev/null | grep -m1 'libnvrtc.so' | sed 's/.*libnvrtc.so.\([0-9.]*\).*/\1/')

echo "[i] Driver CUDA:  ${_driver:-not found}"
echo "[i] Toolkit:      ${_toolkit:-not found}"
echo "[i] NVRTC:        ${_nvrtc:-not found}"

if [[ -n "$_driver" && -n "$_toolkit" ]] &&
   (( ${_toolkit%%.*} < ${_driver%%.*} )); then
    echo "[!] Potential CUDA/NVRTC mismatch."
    echo "[i] Suggested checks:"
    echo "    apt-cache policy cuda-toolkit"
    echo "    apt-cache search '^cuda-toolkit-[0-9]'"
    echo "    ldconfig -p | grep nvrtc"
    echo "    sudo apt install cuda-toolkit-13-2"
fi

echo "[i] To move the panel to the bottom: right-click the panel -> 'Panel Edit Mode', then drag it, or use System Settings > Panel."
echo "[i] Use Startup Applications app to add steam:steam, discord:discord, mega:megasync"
echo "[✔] Setup complete. You may need to reboot for all changes to take effect."
