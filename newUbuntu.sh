#!/bin/bash

# wget https://raw.githubusercontent.com/DaUmega/miscTools/main/newUbuntu.sh; chmod +x newUbuntu.sh; ./newUbuntu.sh

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
    gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-dark'
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' || true
fi

if confirm "enable Night Light"; then
    gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true
fi

if confirm "move dock to bottom"; then
    gsettings set org.gnome.shell.extensions.dash-to-dock dock-position 'BOTTOM'
fi

if confirm "adjust power and idle settings"; then
    gsettings set org.gnome.settings-daemon.plugins.power idle-dim false
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
    gsettings set org.gnome.desktop.screensaver lock-enabled false
    gsettings set org.gnome.desktop.session idle-delay 0
    gsettings set org.gnome.settings-daemon.plugins.power lid-close-ac-action 'nothing'
    gsettings set org.gnome.settings-daemon.plugins.power lid-close-battery-action 'nothing'
    gsettings set org.gnome.desktop.peripherals.mouse accel-profile 'flat'
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
    sudo snap remove firefox || true
fi

if confirm "install Steam"; then
    sudo dpkg --add-architecture i386
    curl -L -o /tmp/steam.deb https://cdn.fastly.steamstatic.com/client/installer/steam.deb
    sudo apt install -y /tmp/steam.deb
    rm -f /tmp/steam.deb
fi

if confirm "install ffmpeg"; then
    sudo snap install ffmpeg
fi

if confirm "install Discord"; then
    sudo snap install discord
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
    sudo snap install code --classic
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
    sudo echo "deb [signed-by=/usr/share/keyrings/eddie.website-keyring.asc] http://eddie.website/repository/apt stable main" | sudo tee /etc/apt/sources.list.d/eddie.website.list
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

echo "[i] Use Startup Application app to add steam:steam, discord:discord, mega:megasync"
echo "[✔] Setup complete. You may need to reboot for all changes to take effect."
