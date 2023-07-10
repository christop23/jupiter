#!/bin/bash

# Step 1: Create directory
mkdir ~/jupiter_installer

# Step 1.5: Change directory to jupiter_installer
echo "Step 1.5: Changing directory to jupiter_installer"
cd ~/jupiter_installer

# Step 2: Install git
echo "Step 2: Installing git"
sudo pacman -S git

# Step 3: Clone paru-bin repository
echo "Step 3: Cloning paru-bin repository"
git clone https://aur.archlinux.org/paru-bin.git

# Step 4: Clone jupiter repository
echo "Step 4: Cloning jupiter repository"
git clone https://github.com/christop23/jupiter.git

# Step 5: Change directory to paru-bin
echo "Step 5: Changing directory to paru-bin"
cd paru-bin

# Step 6: Build and install paru
echo "Step 6: Building and installing paru"
makepkg -si

# Step 7: Remove packages dmenu, foot, and vim
echo "Step 7: Removing packages dmenu, foot, and vim"
paru -R dmenu foot vim

# Step 8: Clean package cache
echo "Step 8: Cleaning package cache"
paru -c

# Step 9: Change directory to the home directory
echo "Step 9: Changing directory to the home directory"
cd ~

# Step 10: Install packages
echo "Step 10: Installing packages"
paru -S alacritty android-tools bat bemenu exa fd firefox firewalld gnome-themes-extra gvfs-mtp imv libnotify mako mpc mpd mpv ncmpcpp nemo nemo-fileroller neofetch neovim noto-fonts noto-fonts-emoji pacman-contrib polkit-gnome qt5-wayland reflector skim starship swaybg telegram-desktop ttf-firacode-nerd ttf-font-awesome ttf-iosevka-nerd ttf-jetbrains-mono-nerd xdg-user-dirs zathura zsh zsh-autosuggestions zsh-syntax-highlighting xdg-desktop-portal kvantum qt5ct python-i3ipc

# Step 11: Install package nwg-look-bin
echo "Step 11: Installing package nwg-look-bin"
paru -S nwg-look-bin

# Step 12: Enable and start firewalld service
echo "Step 12: Enabling and starting firewalld service"
sudo systemctl enable --now firewalld.service

# Step 13: Execute script to install Oh My Zsh
echo "Step 13: Executing script to install Oh My Zsh"
set -x
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
set +x

# Step 13.5: Update xdg user directories
echo "Step 13.5: Updating xdg user directories"
xdg-user-dirs-update

# Step 14: Enable and start paccache timer
echo "Step 14: Enabling and starting paccache timer"
sudo systemctl enable --now paccache.timer

# Step 14.5: Modify configuration files
echo "Step 14.5: Modifying configuration files"
rm ~/.zshrc
rm ~/.zprofile
rm ~/.zshenv
mv ~/jupiter_installer/jupiter/.zshrc ~/
mv ~/jupiter_installer/jupiter/.zshenv ~/
mv ~/jupiter_installer/jupiter/.zprofile ~/
mv ~/jupiter_installer/jupiter/.config/* ~/.config/
mkdir ~/.config/mpd/playlists

# Step 15: Enable mpd.service
echo "Step 15: Enabling mpd.service"
systemctl --user enable mpd.service
