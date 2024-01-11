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
paru -S alacritty android-tools bat bemenu exa fd firefox firewalld gnome-themes-extra grim gvfs-mtp imv jq less libnotify mako mpc mpd mpv ncmpcpp nemo nemo-fileroller neofetch nano noto-fonts noto-fonts-emoji pacman-contrib pavucontrol polkit-gnome qt5-wayland reflector skim slurp starship sway swaybg swayidle telegram-desktop ttf-firacode-nerd ttf-font-awesome ttf-iosevka-nerd ttf-jetbrains-mono-nerd waybar xdg-user-dirs zathura zsh zsh-autosuggestions zsh-syntax-highlighting xdg-desktop-portal wl-clipboard kvantum qt5ct python-i3ipc

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

mv ~/jupiter_installer/jupiter/.zshrc ~/
mv ~/jupiter_installer/jupiter/.zprofile ~/
mv ~/jupiter_installer/jupiter/.config/* ~/.config/
mkdir ~/.config/mpd/playlists

# Step 15: Enable MPD
echo -e "${GREEN}Step 15: Enabling MPD${DEFAULT}"
systemctl --user enable mpd.service
