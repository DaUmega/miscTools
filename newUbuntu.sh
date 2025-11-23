#!/bin/bash

# curl -sSL https://raw.githubusercontent.com/DaUmega/miscTools/main/newUbuntu.sh | bash

set -e

# Force interactive mode even when piped
[[ -t 0 ]] || exec </dev/tty

confirm() {
    if [ "${AUTO_ACCEPT:-0}" = "1" ]; then
        return 0
    fi

    prompt="[?] Do you want to $1? [y/N] "

    if [ -t 1 ]; then
        printf "%s" "$prompt"
        read -r choice
    elif [ -e /dev/tty ]; then
        printf "%s" "$prompt" > /dev/tty
        read -r choice < /dev/tty
    else
        echo "[-] Skipped (no tty available)."
        return 1
    fi

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

if confirm "detect and install/update drivers like NVIDIA"; then
    sudo ubuntu-drivers autoinstall
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
    sudo snap install steam
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

if confirm "install VLC"; then
    sudo snap install vlc
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

if confirm "install TeamViewer"; then
    curl -fsSL -o /tmp/teamviewer_amd64.deb https://download.teamviewer.com/download/linux/teamviewer_amd64.deb
    sudo dpkg -i /tmp/teamviewer_amd64.deb || true
    sudo apt -f install -y
    rm -f /tmp/teamviewer_amd64.deb
fi

echo "[*] Cleaning up..."
sudo apt autoremove -y
sudo apt autoclean -y

echo "[i] Use Startup Application app to add steam:steam, discord:discord, mega:megasync"
echo "[✔] Setup complete. You may need to reboot for all changes to take effect."
