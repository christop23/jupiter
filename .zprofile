# Fundamental Configs

export QT_QPA_PLATFORM=wayland
export QT_QPA_PLATFORMTHEME=qt5ct
export MOZ_ENABLE_WAYLAND=1
export XDG_CURRENT_DESKTOP=sway
export PATH="/usr/share/sway/scripts:$PATH"
export PATH="~/.config/sway/scripts:$PATH"
export GTK_USE_PORTAL=0

# Default Apps

export EDITOR="nvim"
export READER="zathura"
export VISUAL="nvim"
export TERMINAL="alacritty"
export BROWSER="librewolf"
export VIDEO="mpv"
export IMAGE="imv"
export OPENER="xdg-open"
export PAGER="less"
export WM="sway"

# Start Sway

if [ -z "${DISPLAY}" ] && [ "${XDG_VTNR}" -eq 1 ]; then
  exec sway
fi
