#!/bin/bash

# ANSI color codes
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
MAGENTA="\033[0;35m"
DEFAULT="\033[0m"

# Step 1: Create directory
echo -e "${GREEN}Step 1: Creating directory${DEFAULT}"
mkdir ~/jupiter_installer

# Step 1.5: Change directory to jupiter_installer
echo -e "${GREEN}Step 1.5: Changing directory to jupiter_installer${DEFAULT}"
cd ~/jupiter_installer

# Step 2: Install git
echo -e "${GREEN}Step 2: Installing git${DEFAULT}"
sudo pacman -S git

# Step 3: Clone paru-bin repository
echo -e "${GREEN}Step 3: Cloning paru-bin repository${DEFAULT}"
git clone https://aur.archlinux.org/paru-bin.git

# Step 4: Clone jupiter repository
echo -e "${GREEN}Step 4: Cloning jupiter repository${DEFAULT}"
git clone https://github.com/christop23/jupiter.git

# Step 5: Change directory to paru-bin
echo -e "${GREEN}Step 5: Changing directory to paru-bin${DEFAULT}"
cd paru-bin

# Step 6: Build and install paru
echo -e "${GREEN}Step 6: Building and installing paru${DEFAULT}"
makepkg -si

# Step 8: Clean package cache
echo -e "${GREEN}Step 8: Cleaning package cache${DEFAULT}"
paru -c

# Step 9: Change directory to the home directory
echo -e "${GREEN}Step 9: Changing directory to the home directory${DEFAULT}"
cd ~

# Step 10: Install packages
echo -e "${GREEN}Step 10: Installing packages${DEFAULT}"
paru -S lazygit npm ripgrep alacritty android-tools bat bemenu exa fd librewolf swaylock firewalld gnome-themes-extra grim gvfs-mtp imv jq less libnotify mako mpc mpd mpv ncmpcpp nemo nemo-fileroller neofetch neovim noto-fonts noto-fonts-emoji pacman-contrib pavucontrol polkit-gnome qt5-wayland reflector skim slurp starship sway swaybg swayidle telegram-desktop ttf-firacode-nerd ttf-font-awesome ttf-iosevka-nerd ttf-jetbrains-mono-nerd waybar xdg-user-dirs zathura zsh zsh-autosuggestions zsh-syntax-highlighting xdg-desktop-portal wl-clipboard kvantum qt5ct python-i3ipc

# Step 11: Install package nwg-look-bin
echo -e "${GREEN}Step 11: Installing package nwg-look-bin${DEFAULT}"
paru -S nwg-look-bin

# Step 12: Enable and start firewalld service
echo -e "${GREEN}Step 12: Enabling and starting firewalld service${DEFAULT}"
sudo systemctl enable --now firewalld.service

# Step 13: Execute script to install Oh My Zsh
echo -e "${GREEN}Step 13: Executing script to install Oh My Zsh${DEFAULT}"
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

# Step 13.5: Update xdg user directories
echo -e "${GREEN}Step 13.5: Updating xdg user directories${DEFAULT}"
xdg-user-dirs-update

# Step 14: Enable and start paccache timer
echo -e "${GREEN}Step 14: Enabling and starting paccache timer${DEFAULT}"
sudo systemctl enable --now paccache.timer

# Step 14.5: Modify configuration files
echo -e "${GREEN}Step 14.5: Modifying configuration files${DEFAULT}"

if [ -f ~/.zshrc ]; then
    rm ~/.zshrc
    echo -e "${YELLOW}Deleted zshrc${DEFAULT}"
fi

if [ -f ~/.zprofile ]; then
    rm ~/.zprofile
    echo -e "${YELLOW}Deleted zprofile${DEFAULT}"
fi

if [ -d ~/.config ]; then
    rm -rf ~/.config
    mkdir ~/.config
    echo -e "${YELLOW}Cleared config folder${DEFAULT}"
fi

echo -e "${YELLOW}Moving files...${DEFAULT}"
mv ~/jupiter_installer/jupiter/.zshrc ~/
mv ~/jupiter_installer/jupiter/.zprofile ~/
mv ~/jupiter_installer/jupiter/.config/* ~/.config/
mkdir ~/.config/mpd/playlists

# Enable Firefox Sync for Librewolf
if [ -d ~/.librewolf ]; then
    mv ~/jupiter_installer/jupiter/librewolf.overrides.cfg ~/.librewolf/
    echo -e "${YELLOW}Librewolf should now support Firefox Sync${DEFAULT}"
else
    mkdir ~/.librewolf
    mv ~/jupiter_installer/jupiter/librewolf.overrides.cfg ~/.librewolf/
    echo -e "${YELLOW}Librewolf should now support Firefox Sync${DEFAULT}"
fi

# Step 15: Enable MPD
echo -e "${GREEN}Step 15: Enabling MPD${DEFAULT}"
systemctl --user enable mpd.service

# Step 16: Some Pacman Tweaks
echo -e "${GREEN}Step 16: Some Tweaks for Pacman${DEFAULT}"
if [ -f /etc/pacman.conf ]; then
    sudo sed -i "/^#Color/c\Color\nILoveCandy
    /^#VerbosePkgLists/c\VerbosePkgLists
    /^#ParallelDownloads/c\ParallelDownloads = 5" /etc/pacman.conf
fi

# Step 17: Chaotic AUR
echo -e "${GREEN}Step 17: Chaotic AUR:${DEFAULT}"
echo -e "${GREEN}1. Enable it${DEFAULT}"
echo -e "${RED}2. Skip${DEFAULT}"

read -p "Enter your choice (1 or 2): " choice

if [[ $choice -eq 1 ]]; then
    sudo pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
    sudo pacman-key --lsign-key 3056513887B78AEB
    sudo pacman -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
    sudo pacman -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
    sudo sed -i '$ a\[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist' /etc/pacman.conf
    sudo pacman -Syu
    echo -e "${GREEN}Chaotic AUR was setup successfully${DEFAULT}"
    
elif [[ $choice -eq 2 ]]; then
    echo -e "${MAGENTA}Skipped. Go build packages on your own${DEFAULT}"
else
    echo "Invalid choice."
fi

echo -e "${MAGENTA}Jupiter has finished setting things up. You may reboot your system now${DEFAULT}"
