#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# ==========================
# CONFIGURATION
# ==========================

readonly REPO_URL="https://github.com/christop23/jupiter.git"
readonly DOTDIR="${HOME}/.dotfiles-jupiter"
readonly CONFIG_DIR="${HOME}/.config"
# All transient installer artifacts (backup + log) live here.
# Removed automatically on successful installation; kept on failure.
readonly JUPITER_TEMP="${HOME}/jupiter_temp"
readonly BACKUP_DIR="${JUPITER_TEMP}/config_backup_$(date +%Y%m%d_%H%M%S)"
readonly LOG_FILE="${JUPITER_TEMP}/jupiter-install-$(date +%Y%m%d_%H%M%S).log"

# Temporary directory for builds (will be cleaned up)
TEMP_BUILD_DIR=""

# Where a replacement clone is staged before it is swapped in. Empty unless one
# is being staged, which is also how the cleanup knows to leave it alone.
DOTFILES_STAGING_DIR=""

# AUR helper choice (will be set interactively)
AUR_HELPER=""

# Progress tracking
CURRENT_STEP=0
readonly TOTAL_STEPS=21

# Installation summary tracking
declare -a INSTALL_SUMMARY=()

# Shell configuration - fish is the default and only shell
CONFIGURE_FISH=true

# Whether the user opted in to the NVIDIA driver packages
INSTALL_NVIDIA=false
NVIDIA_HEADERS=""
NVIDIA_DRIVER=""

# Whether the user opted in to the greetd + tuigreet greeter
INSTALL_GREETER=false

# Whether the login shell was confirmed as fish, not merely requested
SET_DEFAULT_SHELL_OK=false

# Process ID for sudo keep-alive
SUDO_PID=""

# Expected configuration folders in the repo
readonly CONFIG_FOLDERS=(
  niri waybar fish fastfetch mako alacritty starship
  nvim vicinae gtklock zathura matugen scripts
)

# Configurations that are a single file in the config directory rather than a
# folder, so CONFIG_FOLDERS cannot express them: that list symlinks
# ~/.config/<name> as a directory, and these are files.
#
# pavucontrol reads $XDG_CONFIG_HOME/pavucontrol.ini directly, not from a
# pavucontrol/ subdirectory, which is unusual and is why it needs its own entry
# rather than a folder. It also only applies a configured size when it is at
# least as large as its built-in default of 500x400, so the width and height
# below are a floor and not an exact size.
readonly CONFIG_FILES=("pavucontrol.ini")

# Optional dependencies that waybar modules depend on
readonly OPTIONAL_AUDIO_PACKAGES=("pulseaudio" "pipewire-pulse")
readonly OPTIONAL_BLUETOOTH_PACKAGES=("bluez" "bluez-utils")

# NVIDIA drivers. Since the 590 driver series Arch only ships the open kernel
# modules: `nvidia` became `nvidia-open`, `nvidia-dkms` became
# `nvidia-open-dkms` and `nvidia-lts` became `nvidia-open-lts`. The prebuilt
# packages carry modules for one specific kernel, the DKMS one builds against
# whichever kernel you are running.
readonly NVIDIA_DRIVER_PREBUILT="nvidia-open"
readonly NVIDIA_DRIVER_PREBUILT_LTS="nvidia-open-lts"
readonly NVIDIA_DRIVER_DKMS="nvidia-open-dkms"

# Kernel headers, only needed by the DKMS package
readonly NVIDIA_HEADERS_ZEN="linux-zen-headers"
readonly NVIDIA_HEADERS_LTS="linux-lts-headers"
readonly NVIDIA_HEADERS_LINUX="linux-headers"

# Installed alongside whichever driver is chosen
readonly NVIDIA_COMMON_PACKAGES=(
  nvidia-utils nvidia-settings
  libva-utils libvdpau vulkan-icd-loader
)

# Login greeter packages, only installed when the user opts in
readonly GREETER_PACKAGES=(
  greetd greetd-tuigreet
)

# Display managers that must not run at the same time as greetd
readonly CONFLICTING_DMS=("lightdm" "gdm" "sddm" "ly" "xdm" "lxdm")

# AUR packages to install. Their dependencies are the only part of the install
# the official database cannot describe, so any provider question hiding in one
# of those trees is asked in install_aur_packages, which reads this list to work
# out what to walk from. Adding a package here needs nothing else: its metadata
# is fetched, its dependencies are walked, and the questions it raises are asked.
readonly AUR_PACKAGES=(
  vicinae-bin
)

# Packages that exist only to satisfy a virtual dependency. Naming the provider
# is the only way to stop pacman opening its provider picker, and that picker is
# unusable on a first boot: the console is 80x24 with no display server, so a
# long list scrolls off the top and the numbers you need to type are the ones
# you cannot see. There is no pacman.conf setting for this, and --noconfirm
# would pick the first entry alphabetically, which for the portal is the
# xdg-desktop-portal-cosmic backend, which niri cannot screencast through.
#
# The list below is what this installer would pick on its own. Where the
# question can be put to the user in advance it is, marked as a recommendation
# and taken on a bare Enter, so these are defaults rather than decisions; the
# ones reached only from an AUR dependency cannot be pinned here at all, because
# the package asking for them is not in the transaction this list is built for.
# See install_aur_packages for that case.
#
#   portal   xdg-desktop-portal-impl   10 providers, wanted by niri.
#           niri does its monitor and window screencasting through the gnome
#           portal, so that is the correct backend here, not wlr.
#   jack     jack                        2 providers, wanted by waybar.
#           pipewire-jack because this stack is PipeWire based.
#   soname   libjack.so                  2 providers once the 32-bit mirrors
#           are filtered out, wanted by waybar and portaudio. Same choice, and
#           asked separately because pacman resolves the soname virtual from
#           the package's dependency rather than the jack virtual, so naming
#           pipewire-jack settles one and not the other. See multilib_only and
#           drop_multilib in analyze_virtual_providers.
#   session  pipewire-session-manager    3 providers, reached through
#           pipewire-jack, so pinning jack on its own only moves the question.
#           wireplumber over the other two: pipewire-media-session is marked
#           deprecated and conflicts with wireplumber in both directions, so
#           they cannot be weighed against each other, and waybar already
#           requires libwireplumber, so this adds nothing to the desktop. The
#           third provider, a package of the same name, is omitted from the
#           report because pacman never asks about a real package it already
#           matched by name.
#   font     ttf-font                  11 providers, wanted by librewolf,
#           which needs any TrueType font present and nothing more specific.
#           noto-fonts is the pick because its script coverage suits a browser,
#           not because the dependency calls for it: at 112MB installed it is
#           the second heaviest of the eleven, and ttf-dejavu at 10MB satisfies
#           the virtual just as well. Swap it if disk matters more than CJK,
#           emoji and RTL rendering. Nothing else in this list already provides
#           ttf-font, though ttf-nerd-fonts-symbols is close: it provides
#           ttf-font-nerd, which is a different virtual.
#   tessdata tessdata                 128 providers, wanted by tesseract, which
#           comes in via zathura-pdf-mupdf -> libmupdf. This is the worst
#           offender by far: 128 entries cannot be read on any terminal.
#   opengl   opengl-driver               3 providers. nvidia-utils covers it
#           when the NVIDIA driver is installed, otherwise mesa does, and
#           that choice is made per run in build_pacman_targets.
#   secrets  org.freedesktop.secrets     5 providers, wanted by an AUR package:
#           vicinae-bin reaches it through qtkeychain-qt6, which keeps its
#           credentials in the Secret Service, and nothing else in this stack
#           provides one. The one to learn from here is the shape rather than
#           the package: a virtual wanted by something reached from the AUR
#           cannot be pinned in this list at all, because the package that wants
#           it is not part of the transaction this list is built for, and it has
#           to be asked in install_aur_packages instead. Any AUR package added
#           to AUR_PACKAGES is covered the same way.
#           gnome-keyring is the recommendation over the other four because it
#           is the implementation the rest of the desktop stack is written
#           against, and it activates over D-Bus, so it works with no GNOME
#           session running. The other four each change what the machine is
#           rather than just backing a service: chipass and keepassxc are
#           password managers, which becomes the login password store and wants
#           its own unlock flow, and kwallet is a Plasma component that drags
#           KDE in with it. oo7 is a minimal provider with little use beyond
#           it. All of them are offered, since a machine already using one, or
#           a person who wants one, should not be second-guessed here.
readonly PACMAN_PROVIDER_PORTAL="xdg-desktop-portal-gnome"
readonly PACMAN_PROVIDER_JACK="pipewire-jack"
readonly PACMAN_PROVIDER_WIREPLUMBER="wireplumber"
readonly PACMAN_PROVIDER_FONT="noto-fonts"
readonly PACMAN_PROVIDER_TESSDATA="tesseract-data-eng"
readonly PACMAN_PROVIDER_MESA="mesa"
readonly PACMAN_PROVIDER_SECRETS="gnome-keyring"

# The one place a virtual is mapped to the provider this installer wants, as
# "<virtual>=<provider>" on separate lines.
#
# Three things read it, and they used to be three separate lists that had already
# drifted apart: the preview shown before the install, the recommendations the
# resolver offers, and the check that runs afterwards to see which provider
# actually got installed. Adding a virtual here reaches all three.
#
# It is a function rather than a constant because one entry depends on a decision
# made at run time. opengl-driver is the proprietary driver when the NVIDIA step
# went in and mesa otherwise, and nvidia-utils is not in PACMAN_PROVIDER_* since
# it comes from NVIDIA_COMMON_PACKAGES.
#
# greetd-greeter is deliberately absent and needs nothing here: the greeter is
# not among the targets the analyzer walks, so the question never arises, and
# configure_greeter names greetd-tuigreet in the same pacman call that installs
# greetd, which is what settles it.
provider_recommendations() {
  local line

  for line in \
    "xdg-desktop-portal-impl=${PACMAN_PROVIDER_PORTAL}" \
    "jack=${PACMAN_PROVIDER_JACK}" \
    "pipewire-session-manager=${PACMAN_PROVIDER_WIREPLUMBER}" \
    "ttf-font=${PACMAN_PROVIDER_FONT}" \
    "tessdata=${PACMAN_PROVIDER_TESSDATA}" \
    "org.freedesktop.secrets=${PACMAN_PROVIDER_SECRETS}"
  do
    printf '%s\n' "${line}"
  done

  if [[ "${INSTALL_NVIDIA}" == "true" ]]; then
    printf 'opengl-driver=nvidia-utils\n'
  else
    printf 'opengl-driver=%s\n' "${PACMAN_PROVIDER_MESA}"
  fi
}

# Official repository packages
readonly PACMAN_PACKAGES=(
  niri waybar fish fastfetch mako alacritty starship neovim eza
  zathura zathura-pdf-mupdf ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols
  qt5-wayland qt6-wayland polkit-gnome unzip jq unrar 7zip man-db bat
  gtklock curl libnotify pavucontrol thunar awww matugen librewolf bottom
  # Referenced by the configs, so installed rather than left dangling:
  #   qt5ct, qt6ct        the platform-theme plugin niri/config.kdl names with
  #                       QT_QPA_PLATFORMTHEME, without which Qt cannot read
  #                       the Colloid theme in ~/.themes
  #   networkmanager      nmtui, which fish/config.fish aliases as `wifi`
  qt5ct qt6ct networkmanager
  "${PACMAN_PROVIDER_PORTAL}" "${PACMAN_PROVIDER_JACK}"
  "${PACMAN_PROVIDER_WIREPLUMBER}" "${PACMAN_PROVIDER_FONT}"
  "${PACMAN_PROVIDER_TESSDATA}"
)

# The polkit agent that niri starts, by absolute path, because that is the only
# way it is started: niri/config.kdl runs it from /usr/lib/polkit-gnome, where
# it is not in PATH and so cannot be found the way the other binaries are. It is
# the one file the polkit-gnome package ships under that name, and the polkit
# daemon it talks to is a hard dependency of it, so checking this one path covers
# the whole authentication chain. Keep this path and the spawn line in niri's
# config in step.
readonly POLKIT_AGENT_PATH="/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1"

# ==========================
# COLOR OUTPUT
# ==========================

readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ==========================
# LOGGING & OUTPUT FUNCTIONS
# ==========================

log() {
  local timestamp
  timestamp="$(date +'%Y-%m-%d %H:%M:%S')"
  # stderr is redirected first on purpose. Bash applies redirections left to
  # right, so with ">> file 2> /dev/null" a failure to open the log is reported
  # to a stderr that has not been redirected yet and leaks to the terminal.
  # That happens on every call after cleanup removes the log directory.
  printf "[%s] %s\n" "${timestamp}" "$*" 2> /dev/null >> "${LOG_FILE}" || true
}

# The message is printed with %b, not %s, because several of them embed the
# colour constants. In the argument of %s those stay literal text, so a hint
# like info "Set it up later with: ${CYAN}...${NC}" reaches the terminal as
# "Set it up later with: \033[0;36m...\033[0m". %b interprets the escapes, and
# the log below keeps the raw message either way. Nothing passes a literal
# backslash to these, which is the only thing else %b would eat.
msg() {
  printf "${GREEN}==>${NC} %b\n" "$1"
  log "INFO: $1"
}

info() {
  printf "${BLUE}==>${NC} %b\n" "$1"
  log "INFO: $1"
}

warn() {
  printf "${YELLOW}[WARNING]${NC} %b\n" "$1"
  log "WARNING: $1"
}

error() {
  printf "${RED}[ERROR]${NC} %b\n" "$1" >&2
  log "ERROR: $1"
}

# tee -a onto the log, for a command whose exit status the caller checks.
#
# The log is a convenience, so failing to write it must not change the answer.
# It used to: `cmd 2>&1 | tee -a "${LOG_FILE}"` under pipefail takes tee's exit
# status when tee fails, so a full disk or an unwritable directory turned a
# pacman run that had just succeeded into "Failed to install official
# repository packages" and aborted the install. log() above already survives an
# unwritable log; this is the same concern for the commands that stream through
# it.
#
# tee's output still reaches the terminal either way, so the visible behaviour
# is unchanged when the log works. `|| true` is on the tee alone, and the
# command's own status is what the pipeline then reports.
log_and_show() {
  tee -a "${LOG_FILE}" || true
}

fatal() {
  error "$1"
  error "Installation failed. Check log file: ${LOG_FILE}"
  exit 1
}

step() {
  ((++CURRENT_STEP)) || true
  printf "\n"
  printf "${CYAN}${BOLD}[Step %d/%d]${NC} ${MAGENTA}%s${NC}\n" "${CURRENT_STEP}" "${TOTAL_STEPS}" "$1"
  printf "${CYAN}─────────────────────────────────────────────────────────${NC}\n"
  log "STEP ${CURRENT_STEP}/${TOTAL_STEPS}: $1"
}

separator() {
  printf "\n"
  printf "${BLUE}═════════════════════════════════════════════════════════${NC}\n"
  printf "\n"
}

add_summary() {
  INSTALL_SUMMARY+=("$1")
}

# ==========================
# USAGE & HELP
# ==========================

usage() {
  cat << EOF
Usage: ${0##*/} [OPTIONS]

Jupiter Installer - Automated setup for Niri window manager configuration

OPTIONS:
  -h, --help      Display this help message and exit
  -v, --version   Display version information

DESCRIPTION:
  This script automates the installation and configuration of a complete
  Niri-based desktop environment on Arch Linux systems.

REQUIREMENTS:
  - Arch Linux or Arch-based distribution
  - Active internet connection
  - Sudo privileges
  - At least 5GB free disk space

CONFIGURATION:
  The script will clone dotfiles from:
    ${REPO_URL}

  Installation directory:
    ${DOTDIR}

  Configuration will be symlinked to:
    ${CONFIG_DIR}

LOG FILE:
  Installation logs are saved to:
    ${LOG_FILE}

EXAMPLES:
  ${0##*/}              # Run interactive installation
  ${0##*/} --help       # Display this help message

REPORT BUGS:
  https://github.com/christop23/jupiter/issues

EOF
}

version() {
  printf "Jupiter Installer v1.3\n"
  printf "Defensive Bash Refactored Edition\n"
}

# ==========================
# CLEANUP FUNCTIONS
# ==========================

cleanup_temp_files() {
  if [[ -n "${TEMP_BUILD_DIR}" ]] && [[ -d "${TEMP_BUILD_DIR}" ]]; then
    info "Cleaning up temporary build directory..."
    rm -rf "${TEMP_BUILD_DIR}" 2> /dev/null || true
  fi

  # A staged clone that never got swapped in. Whatever it was replacing is still
  # in place, so removing this loses nothing.
  if [[ -n "${DOTFILES_STAGING_DIR}" ]] && [[ -d "${DOTFILES_STAGING_DIR}" ]]; then
    rm -rf "${DOTFILES_STAGING_DIR}" 2> /dev/null || true
  fi
}

cleanup_sudo_keepalive() {
  if [[ -n "${SUDO_PID}" ]] && kill -0 "${SUDO_PID}" 2> /dev/null; then
    kill "${SUDO_PID}" 2> /dev/null || true
    wait "${SUDO_PID}" 2> /dev/null || true
  fi
}

cleanup_on_exit() {
  local exit_code=$?
  cleanup_sudo_keepalive
  cleanup_temp_files

  if [[ ${exit_code} -ne 0 ]]; then
    error "Script exited with error code: ${exit_code}"
  fi
}

cleanup_on_error() {
  local line_no=$1
  error "Error occurred on line ${line_no}"
  offer_restore
  cleanup_on_exit
}

# ==========================
# UTILITY FUNCTIONS
# ==========================

retry_command() {
  local max_attempts="$1"
  shift
  local cmd=("$@")
  local attempt=1

  while [[ ${attempt} -le ${max_attempts} ]]; do
    if "${cmd[@]}"; then
      return 0
    fi

    if [[ ${attempt} -lt ${max_attempts} ]]; then
      local wait_time=$((attempt * 2))
      warn "Command failed (attempt ${attempt}/${max_attempts}). Retrying in ${wait_time} seconds..."
      sleep "${wait_time}"
    fi
    ((attempt++)) || true
  done

  return 1
}

check_internet() {
  info "Checking internet connectivity..."

  if ! command -v curl &> /dev/null; then
    warn "curl not found, will be installed with base tools"
    return 0
  fi

  local endpoints=(
    "https://archlinux.org"
    "https://google.com"
    "https://cloudflare.com"
  )
  local connected=false

  for endpoint in "${endpoints[@]}"; do
    if curl -s --connect-timeout 5 --max-time 10 "${endpoint}" > /dev/null 2>&1; then
      connected=true
      break
    fi
  done

  if [[ "${connected}" == "false" ]]; then
    fatal "No internet connection. Please connect to the internet and try again."
  fi

  msg "Internet connection verified."

  info "Testing connection quality..."
  if ! curl -s --connect-timeout 2 --max-time 5 https://archlinux.org > /dev/null 2>&1; then
    warn "Network connection appears slow. Installation may take longer than usual."
  fi
}

check_arch_based() {
  info "Verifying Arch-based system..."

  if ! command -v pacman &> /dev/null; then
    fatal "This script requires pacman package manager (Arch-based distribution)."
  fi

  local distro_name="Unknown"
  local is_arch_based=false

  if [[ -f /etc/os-release ]]; then
    distro_name="$(grep -E '^NAME=' /etc/os-release | cut -d'"' -f2)"

    if grep -qE '^ID=arch$' /etc/os-release ||
      grep -qE '^ID_LIKE=.*arch.*' /etc/os-release ||
      [[ -f /etc/arch-release ]]; then
      is_arch_based=true
    fi

    if [[ "${is_arch_based}" == "false" ]]; then
      fatal "This script is designed for Arch-based distributions only. Detected: ${distro_name}"
    fi
  fi

  msg "Arch-based system detected: ${distro_name}"
}

check_disk_space() {
  info "Checking available disk space..."
  local available_mb
  available_mb="$(df -P -BM "${HOME}" | tail -n 1 | awk '{print $4}' | sed 's/M//')"

  if [[ ${available_mb} -lt 5000 ]]; then
    warn "Low disk space detected: ${available_mb}MB available"
    warn "Installation requires at least 5GB free space for packages and builds"
    warn "You may encounter issues during installation"
    printf "\n"

    local reply=""
    # `|| true` so a closed stdin falls through to the safe default below
    # instead of tripping set -e and aborting the whole install.
    read -r -p "Continue anyway? (y/N): " reply < /dev/tty || true
    printf "\n"

    if [[ ! "${reply}" =~ ^[Yy]$ ]]; then
      fatal "Installation cancelled by user"
    fi
  else
    msg "Sufficient disk space available: ${available_mb}MB"
  fi
}

check_not_root() {
  if [[ ${EUID} -eq 0 ]]; then
    fatal "Do not run this script as root. Run as a regular user with sudo privileges."
  fi
}

check_sudo() {
  info "Verifying sudo privileges..."
  if ! sudo -v; then
    fatal "Sudo privileges required. Please ensure you have sudo access."
  fi

  (
    # -n so this can never prompt: a background job that inherits the script's
    # stdin would read a line of the script itself when the timestamp expires,
    # which is the failure the usermod-instead-of-chsh change exists to avoid.
    # It also exits rather than looping once sudo is no longer available.
    #
    # trap - ERR because set -E makes the ERR trap inherit into this subshell,
    # and without sudo a failing `sudo -n -v` would otherwise fire the trap
    # here, printing an error about line 497 and running offer_restore on a
    # read < /dev/tty inside a background process.
    trap - ERR
    while true; do
      sudo -n -v || exit 0
      sleep 50
    done
  ) &
  SUDO_PID=$!

  msg "Sudo privileges verified."
}

check_optional_dependencies() {
  info "Checking optional dependencies for waybar modules..."

  local missing_audio=true
  local missing_bluetooth=true
  local warnings=()

  # Check for audio backend
  for pkg in "${OPTIONAL_AUDIO_PACKAGES[@]}"; do
    if pacman -Qi "${pkg}" &> /dev/null; then
      missing_audio=false
      break
    fi
  done

  # Check for Bluetooth backend
  for pkg in "${OPTIONAL_BLUETOOTH_PACKAGES[@]}"; do
    if pacman -Qi "${pkg}" &> /dev/null; then
      missing_bluetooth=false
      break
    fi
  done

  # Display warnings if dependencies are missing
  if [[ "${missing_audio}" == "true" ]] || [[ "${missing_bluetooth}" == "true" ]]; then
    printf "\n"
    warn "Missing optional dependencies detected:"
    printf "\n"

    if [[ "${missing_audio}" == "true" ]]; then
      warnings+=("Audio backend (PulseAudio/PipeWire)")
      printf "${YELLOW}⚠${NC}  ${BOLD}Audio Backend:${NC} Not detected\n"
      printf "   Waybar's audio module will not display.\n"
      printf "   Install one of: ${CYAN}pulseaudio${NC} or ${CYAN}pipewire-pulse${NC}\n"
      printf "   Example: ${CYAN}sudo pacman -S pipewire-pulse${NC}\n"
      printf "\n"
    fi

    if [[ "${missing_bluetooth}" == "true" ]]; then
      warnings+=("Bluetooth backend (bluez)")
      printf "${YELLOW}⚠${NC}  ${BOLD}Bluetooth Backend:${NC} Not detected\n"
      printf "   Waybar's Bluetooth module will not display.\n"
      printf "   Install: ${CYAN}bluez bluez-utils${NC}\n"
      printf "   Example: ${CYAN}sudo pacman -S bluez bluez-utils${NC}\n"
      printf "\n"
    fi

    printf "${BLUE}${BOLD}Note:${NC} These are workflow-dependent choices:\n"
    printf "  • Some users prefer PipeWire, others prefer PulseAudio\n"
    printf "  • Not everyone needs Bluetooth functionality\n"
    printf "  • You can install these manually later if needed\n"
    printf "  • Waybar modules may show errors on first launch until backends are installed\n"
    printf "\n"

    local reply=""
    read -r -p "Continue installation without these optional dependencies? (Y/n): " reply < /dev/tty || true
    printf "\n"

    if [[ "${reply}" =~ ^[Nn]$ ]]; then
      fatal "Installation cancelled by user. Please install required dependencies and re-run."
    fi

    warn "Waybar modules may show errors on first launch - install backends to fix"
    msg "Continuing with installation (missing: ${warnings[*]})"
  else
    msg "All optional dependencies for waybar modules are installed."
  fi
}

has_nvidia_gpu() {
  # Only display-class devices count, so an NVIDIA network card is not a
  # false positive.
  if command -v lspci &> /dev/null; then
    # One pass, and no -q on the last grep: `grep -q` exits at the first match
    # without draining the pipe, so the upstream grep took EPIPE and exited 141,
    # and pipefail reported that as the pipeline's status. On a hybrid laptop
    # where the dGPU is enumerated before the iGPU that is a false negative on
    # the one machine most likely to want the proprietary driver.
    lspci 2> /dev/null |
      grep -iE '(VGA compatible controller|3D controller|Display controller)' |
      grep -i 'nvidia' > /dev/null
    return $?
  fi

  # lspci ships in pciutils, which is often not installed this early on a
  # fresh system. Fall back to sysfs, which needs no extra packages.
  local device vendor class
  for device in /sys/bus/pci/devices/*/; do
    [[ -r "${device}vendor" && -r "${device}class" ]] || continue

    vendor=""
    class=""
    read -r vendor < "${device}vendor" || true
    read -r class < "${device}class" || true
    vendor="${vendor#0x}"
    class="${class#0x}"

    if [[ "${vendor}" != "10de" ]]; then
      continue
    fi

    # 0300 = VGA, 0302 = 3D controller, 0308 = other display controller
    if [[ "${class}" == 0300* || "${class}" == 0302* || "${class}" == 0308* ]]; then
      return 0
    fi
  done

  return 1
}

detect_kernel_flavour() {
  # uname looks like 7.2.6-arch2-1, 6.9.7-zen1-1 or 6.6.30-lts1-1.
  case "$(uname -r)" in
    *-zen*) printf 'zen' ;;
    *-lts*) printf 'lts' ;;
    *-arch*) printf 'linux' ;;
    *) printf 'unknown' ;;
  esac
}

select_nvidia_variant() {
  local flavour choice
  flavour="$(detect_kernel_flavour)"

  printf "\n"
  printf "  ${BOLD}Running kernel:${NC} %s (%s)\n" "$(uname -r)" "${flavour}"
  printf "\n"
  printf "${BLUE}${BOLD}Which driver package do you want?${NC}\n"
  printf "  ${BOLD}All of these use the open GPU modules and need Turing or newer,${NC}\n"
  printf "  ${BOLD}that is GTX 16-series / RTX 20-series (2018) and up.${NC}\n"
  printf "\n"

  case "${flavour}" in
    linux)
      printf "  ${BOLD}1${NC}) ${CYAN}${NVIDIA_DRIVER_PREBUILT}${NC}  prebuilt modules for the standard\n"
      printf "        kernel. No headers and no DKMS build needed.  ${BOLD}[recommended]${NC}\n"
      printf "  ${BOLD}2${NC}) ${CYAN}${NVIDIA_DRIVER_DKMS}${NC}  build against your kernel instead.\n"
      printf "        Unnecessary on the standard kernel, but survives a kernel switch.\n"
      ;;
    lts)
      printf "  ${BOLD}1${NC}) ${CYAN}${NVIDIA_DRIVER_PREBUILT_LTS}${NC}  prebuilt modules for linux-lts.\n"
      printf "        No headers and no DKMS build needed.  ${BOLD}[recommended]${NC}\n"
      printf "  ${BOLD}2${NC}) ${CYAN}${NVIDIA_DRIVER_DKMS}${NC}  build against your kernel instead.\n"
      printf "        Unnecessary on linux-lts, but survives a kernel switch.\n"
      ;;
    zen)
      printf "  ${BOLD}1${NC}) ${CYAN}${NVIDIA_DRIVER_DKMS}${NC}  build against your kernel.\n"
      printf "        The prebuilt packages only cover the standard kernel, so this is\n"
      printf "        the only option here. Needs ${CYAN}linux-zen-headers${NC}.\n"
      ;;
    *)
      printf "  ${BOLD}1${NC}) ${CYAN}${NVIDIA_DRIVER_DKMS}${NC}  build against your kernel.\n"
      printf "        The prebuilt packages only cover the standard kernel, so this is\n"
      printf "        the only option here. Needs matching kernel headers.\n"
      ;;
  esac
  printf "  ${BOLD}0${NC}) skip the driver entirely\n"
  printf "\n"

  while true; do
    if ! read -r -p "Driver package? [1/2, default 1, 0 to skip]: " choice < /dev/tty; then
      printf "\n"
      warn "No input available. Skipping NVIDIA driver installation."
      return 1
    fi
    printf "\n"

    case "${choice}" in
      "" | 1)
        case "${flavour}" in
          linux) NVIDIA_DRIVER="${NVIDIA_DRIVER_PREBUILT}" ;;
          lts) NVIDIA_DRIVER="${NVIDIA_DRIVER_PREBUILT_LTS}" ;;
          *) NVIDIA_DRIVER="${NVIDIA_DRIVER_DKMS}" ;;
        esac
        ;;
      2)
        NVIDIA_DRIVER="${NVIDIA_DRIVER_DKMS}"
        ;;
      0 | n | none | skip)
        warn "Skipping NVIDIA driver installation."
        return 1
        ;;
      *)
        warn "Invalid choice: '${choice}'. Enter 1, 2 or 0."
        continue
        ;;
    esac

    break
  done

  msg "Selected driver: ${NVIDIA_DRIVER}"

  # Only the DKMS package compiles against the kernel, so it is the only one
  # that needs headers.
  if [[ "${NVIDIA_DRIVER}" == "${NVIDIA_DRIVER_DKMS}" ]]; then
    select_kernel_headers
  fi

  return 0
}

select_kernel_headers() {
  local flavour installed_kernels choice headers
  flavour="$(detect_kernel_flavour)"

  printf "${BLUE}${BOLD}${NVIDIA_DRIVER} builds a module, so it needs the headers matching${NC}\n"
  printf "${BOLD}the kernel you are running.${NC}\n"

  installed_kernels="$(pacman -Qq 2> /dev/null | grep -E '^linux(-(lts|zen|hardened|rt|aws))*$' | tr '\n' ' ' || true)"
  if [[ -n "${installed_kernels}" ]]; then
    printf "  Installed kernels: ${CYAN}%s${NC}\n" "${installed_kernels}"
  fi
  printf "\n"

  # Only ask when the running kernel does not identify itself.
  case "${flavour}" in
    zen)
      headers="${NVIDIA_HEADERS_ZEN}"
      msg "Detected a zen kernel, so using ${headers}."
      ;;
    lts)
      headers="${NVIDIA_HEADERS_LTS}"
      msg "Detected a linux-lts kernel, so using ${headers}."
      ;;
    linux)
      headers="${NVIDIA_HEADERS_LINUX}"
      msg "Detected the standard kernel, so using ${headers}."
      ;;
    *)
      printf "  ${BOLD}1${NC}) zen    ${CYAN}linux-zen-headers${NC}   (Arch Linux mainline kernel)\n"
      printf "  ${BOLD}2${NC}) lts    ${CYAN}linux-lts-headers${NC}   (long term support kernel)\n"
      printf "  ${BOLD}3${NC}) linux  ${CYAN}linux-headers${NC}       (stock Arch kernel)\n"
      printf "\n"
      printf "  ${YELLOW}Could not tell which kernel flavour you are running${NC}\n"
      printf "  ${YELLOW}from '$(uname -r)', so please choose.${NC}\n"
      printf "\n"

      while true; do
        if ! read -r -p "Which kernel are you running? [1/2/3, default 3]: " choice < /dev/tty; then
          printf "\n"
          warn "No input available. Defaulting to ${NVIDIA_HEADERS_LINUX}."
          headers="${NVIDIA_HEADERS_LINUX}"
          break
        fi
        printf "\n"

        case "${choice}" in
          1 | zen) headers="${NVIDIA_HEADERS_ZEN}" ;;
          2 | lts) headers="${NVIDIA_HEADERS_LTS}" ;;
          "" | 3 | linux) headers="${NVIDIA_HEADERS_LINUX}" ;;
          *)
            warn "Invalid choice: '${choice}'. Enter 1, 2 or 3."
            continue
            ;;
        esac

        break
      done
      ;;
  esac

  NVIDIA_HEADERS="${headers}"
  msg "Selected kernel headers: ${headers}"
}

configure_nvidia() {
  info "Checking for NVIDIA graphics hardware..."

  if has_nvidia_gpu; then
    msg "NVIDIA display device detected."
  else
    warn "No NVIDIA display device detected."
    info "This check is only a hint, so the choice below is still yours to make."
    info "It reads sysfs, or lspci if pciutils happens to be installed."
  fi

  # IFS is newline+tab in this script, so join explicitly for single-line hints.
  local package_list
  printf -v package_list '%s ' "${NVIDIA_COMMON_PACKAGES[@]}"
  package_list="${package_list% }"

  printf "\n"
  printf "${BOLD}Alongside the driver, these will be installed:${NC}\n"
  printf "  ${CYAN}nvidia-utils${NC}        nvidia-smi plus the GLX/EGL/Vulkan setup Wayland needs\n"
  printf "  ${CYAN}nvidia-settings${NC}     graphical control panel\n"
  printf "  ${CYAN}libva-utils${NC}         VA-API video acceleration\n"
  printf "  ${CYAN}libvdpau${NC}            VDPAU video acceleration\n"
  printf "  ${CYAN}vulkan-icd-loader${NC}   Vulkan driver loader\n"
  printf "\n"
  printf "${BLUE}${BOLD}Note:${NC}\n"
  printf "  • On hybrid laptops (Intel + NVIDIA) the module loads only when a GPU app runs\n"
  printf "  • Proprietary drivers occasionally cause a black screen on first boot\n"
  printf "  • Pascal (GTX 10-series) and Maxwell (GTX 900-series) are not supported by\n"
  printf "    any official package any more. Those need the legacy branch from the AUR:\n"
  printf "    ${CYAN}yay -S nvidia-580xx-dkms${NC}\n"
  printf "\n"

  local reply=""
  # `|| true` so a closed stdin counts as "no" rather than tripping set -e
  # and aborting the whole install through the ERR trap.
  read -r -p "Install an NVIDIA driver? (y/N): " reply < /dev/tty || true
  printf "\n"

  if [[ ! "${reply}" =~ ^[Yy]$ ]]; then
    warn "Skipping NVIDIA driver installation."
    info "Install it later with: ${CYAN}sudo pacman -S <driver> ${package_list}${NC}"
    return 0
  fi

  select_nvidia_variant || return 0

  local -a install_list=("${NVIDIA_DRIVER}")

  if [[ -n "${NVIDIA_HEADERS}" ]]; then
    install_list=("${NVIDIA_HEADERS}" "${install_list[@]}")
  fi

  install_list+=("${NVIDIA_COMMON_PACKAGES[@]}")

  info "Installing ${install_list[*]}"
  info "This may take several minutes while the module is compiled..."
  if sudo pacman -S --needed "${install_list[@]}" < /dev/tty 2>&1 | log_and_show "${LOG_FILE}"; then
    INSTALL_NVIDIA=true
    msg "NVIDIA packages installed successfully."
  else
    fatal "Failed to install NVIDIA packages."
  fi
}

verify_binary() {
  local binary="$1"
  if ! command -v "${binary}" &> /dev/null; then
    error "Binary '${binary}' not found in PATH."
    return 1
  fi
  return 0
}

# Quiet counterpart to verify_binary, for the branches that install the missing
# binary themselves. A binary that is about to be installed is not a fault, and
# reporting it as one puts an [ERROR] line on the console immediately before the
# step that fixes it, which reads as a failure that is still to come. Keep this
# for pre-install checks and verify_binary for the step that actually asserts a
# binary has to be there by then.
binary_installed() {
  command -v "$1" &> /dev/null
}

# ==========================
# BACKUP FUNCTIONS
# ==========================

create_backup() {
  msg "Creating backup of existing configurations..."
  mkdir -p "${BACKUP_DIR}"
  mkdir -p "${CONFIG_DIR}"

  local backed_up=0
  local symlinks_found=0

  # Populated by basename whenever a copy fails, and read back by
  # create_symlinks to refuse the removal that would otherwise destroy the only
  # remaining copy. cp -rL fails on a single dangling symlink, a symlink loop, a
  # socket or a full disk, and the target was being rm -rf'd three steps later
  # regardless, which left the user with neither the config nor a backup.
  BACKUP_FAILED=()

  for folder in "${CONFIG_FOLDERS[@]}"; do
    local target="${CONFIG_DIR}/${folder}"
    if [[ -e "${target}" ]] || [[ -L "${target}" ]]; then
      if [[ -L "${target}" ]]; then
        local link_target
        link_target="$(readlink "${target}")"
        warn "Symlink detected: ${folder} -> ${link_target}"
        ((++symlinks_found)) || true
        rm "${target}"
        info "Removed symlink: ${folder}"
      elif cp -rL "${target}" "${BACKUP_DIR}/" 2> /dev/null; then
        rm -rf "${target}"
        info "Backed up: ${folder}"
        ((++backed_up)) || true
      else
        warn "Failed to backup: ${folder}"
        warn "It will be left in place rather than deleted, so nothing is lost."
        BACKUP_FAILED+=("${folder}")
      fi
    fi
  done

  # A user's existing single file configuration is replaced by a symlink in
  # create_symlinks, so it is backed up under its own name here. restore_backup
  # already works on whatever is in the backup directory by basename, so it
  # picks these up without needing to know they were files.
  local file
  for file in "${CONFIG_FILES[@]}"; do
    target="${CONFIG_DIR}/${file}"
    if [[ -e "${target}" ]] || [[ -L "${target}" ]]; then
      if [[ -L "${target}" ]]; then
        warn "Symlink detected: ${file} -> $(readlink "${target}")"
        ((++symlinks_found)) || true
        rm "${target}"
        info "Removed symlink: ${file}"
      elif cp -L "${target}" "${BACKUP_DIR}/" 2> /dev/null; then
        rm -f "${target}"
        info "Backed up: ${file}"
        ((++backed_up)) || true
      else
        warn "Failed to backup: ${file}"
        warn "It will be left in place rather than deleted, so nothing is lost."
        BACKUP_FAILED+=("${file}")
      fi
    fi
  done

  if [[ ${symlinks_found} -gt 0 ]]; then
    warn "Found ${symlinks_found} symlink(s). These were removed without backup."
    warn "If they pointed to important data, you may want to restore them manually."
  fi

  if [[ ${backed_up} -gt 0 ]]; then
    msg "Backed up ${backed_up} configuration(s) to: ${BACKUP_DIR}"
  else
    info "No existing configurations found to backup."
  fi
}

offer_restore() {
  if [[ -d "${BACKUP_DIR}" ]] && [[ -n "$(ls -A "${BACKUP_DIR}" 2> /dev/null)" ]]; then
    printf "\n"
    warn "Installation encountered an error."
    printf "${YELLOW}Your previous configurations are backed up at:${NC}\n"
    printf "  %s\n" "${BACKUP_DIR}"
    printf "\n"

    local reply=""
    read -r -p "Would you like to restore your backup now? (y/N): " reply < /dev/tty || true
    printf "\n"

    if [[ "${reply}" =~ ^[Yy]$ ]]; then
      restore_backup
    fi
  fi
}

restore_backup() {
  info "Restoring backup..."

  for folder in "${BACKUP_DIR}"/*; do
    if [[ -e "${folder}" ]]; then
      local basename
      basename="$(basename "${folder}")"
      rm -rf "${CONFIG_DIR:?}/${basename}"
      mv "${folder}" "${CONFIG_DIR}/"
      info "Restored: ${basename}"
    fi
  done

  msg "Backup restored successfully."
}

# ==========================
# PACKAGE MANAGEMENT
# ==========================

update_system() {
  info "Updating system packages..."
  if sudo pacman -Syu < /dev/tty 2>&1 | log_and_show "${LOG_FILE}"; then
    msg "System updated successfully."
  else
    fatal "Failed to update system packages."
  fi
}

install_base_tools() {
  info "Installing base development tools..."
  if sudo pacman -S --needed git base-devel curl < /dev/tty 2>&1 | log_and_show "${LOG_FILE}"; then
    msg "Base tools installed."
  else
    fatal "Failed to install base development tools."
  fi
}

choose_aur_helper() {
  info "Checking for AUR helper..."

  if command -v yay &> /dev/null; then
    if yay --version &> /dev/null; then
      AUR_HELPER="yay"
      msg "yay AUR helper detected and working."
      return 0
    else
      warn "yay is installed but broken (likely due to pacman/libalpm upgrade). Reinstalling..."
      # Only the names pacman actually has. `yay` is a virtual provided by
      # yay-bin, so naming both made pacman abort the whole removal with
      # "target not found" and remove nothing, and the || true hid that, so
      # the reinstall below then wrote over a package pacman thought was fine.
      local -a stale_helpers=()
      mapfile -t stale_helpers < <(pacman -Qq 2> /dev/null | grep -E '^yay(-bin)?$' || true)
      if [[ ${#stale_helpers[@]} -gt 0 ]]; then
        sudo pacman -Rns "${stale_helpers[@]}" < /dev/tty 2>&1 | log_and_show "${LOG_FILE}" || true
      fi
    fi
  fi

  AUR_HELPER="yay"
  install_yay
}

install_yay() {
  info "Installing yay-bin AUR helper..."

  TEMP_BUILD_DIR="$(mktemp -d)"

  if [[ ! -d "${TEMP_BUILD_DIR}" ]]; then
    fatal "Failed to create temporary directory for yay build"
  fi

  info "Cloning yay-bin repository (this may take a moment)..."
  if ! retry_command 3 git clone --depth=1 https://aur.archlinux.org/yay-bin.git "${TEMP_BUILD_DIR}" 2>&1 | log_and_show "${LOG_FILE}"; then
    fatal "Failed to clone yay-bin repository after multiple attempts."
  fi

  info "Building yay-bin package (this may take a few minutes)..."
  if ! (cd "${TEMP_BUILD_DIR}" && makepkg -si < /dev/tty 2>&1 | log_and_show "${LOG_FILE}"); then
    fatal "Failed to build and install yay-bin."
  fi

  info "Cleaning up yay-bin build directory..."
  cleanup_temp_files
  TEMP_BUILD_DIR=""

  if verify_binary yay; then
    msg "yay-bin installed successfully from AUR."
  else
    fatal "yay-bin installation completed but binary not found."
  fi
}

check_yay_linkage() {
  if command -v yay &> /dev/null; then
    if ldd "$(command -v yay)" | grep -q "not found"; then
      warn "Detected broken shared library linkage in yay. Reinstalling."
      # Only the names pacman actually has. `yay` is a virtual provided by
      # yay-bin, so naming both made pacman abort the whole removal with
      # "target not found" and remove nothing, and the || true hid that, so
      # the reinstall below then wrote over a package pacman thought was fine.
      local -a stale_helpers=()
      mapfile -t stale_helpers < <(pacman -Qq 2> /dev/null | grep -E '^yay(-bin)?$' || true)
      if [[ ${#stale_helpers[@]} -gt 0 ]]; then
        sudo pacman -Rns "${stale_helpers[@]}" < /dev/tty 2>&1 | log_and_show "${LOG_FILE}" || true
      fi
      install_yay
    fi
  fi
}

install_pacman_packages() {
  build_pacman_targets

  analyze_virtual_providers
  preview_virtual_providers
  resolve_virtual_providers

  # drop_installed_targets removes anything pacman already has, so on a machine
  # that already runs most of this stack the list comes back empty. pacman exits
  # 1 with "no targets specified" in that case, which under pipefail reached the
  # fatal below and killed the install on the very re-run the rest of this file
  # goes to such lengths to support.
  if [[ ${#PACMAN_TARGETS[@]} -eq 0 ]]; then
    msg "Every requested package is already installed, nothing to do."
    return 0
  fi

  info "Installing official repository packages..."
  info "This may take several minutes..."

  if sudo pacman -S --needed "${PACMAN_TARGETS[@]}" < /dev/tty 2>&1 | log_and_show "${LOG_FILE}"; then
    msg "Official packages installed successfully."
  else
    fatal "Failed to install official repository packages."
  fi

  verify_virtual_providers
}

# The exact list handed to pacman. It is more than PACMAN_PACKAGES because one
# entry depends on an earlier decision. mesa is the opengl driver for the runs
# where the user declined the NVIDIA driver, and it must be left out when
# NVIDIA is installed: nvidia-utils already provides that virtual, so naming
# both would not remove the choice, it would only move it. The NVIDIA packages
# are folded in for the preview even though configure_nvidia installed them with
# its own pacman call, because a package named in any of those transactions is a
# decided target and that is exactly what the preview needs to know.
#
# The greeter packages are deliberately not folded in, and must not be: the
# greeter is only configured at the end of the run and is not installed until the
# person running this has said yes to it, so naming it here would put a login
# greeter on a machine nobody asked for one on.
declare -a PACMAN_TARGETS=()

build_pacman_targets() {
  PACMAN_TARGETS=("${PACMAN_PACKAGES[@]}")

  if [[ "${INSTALL_NVIDIA}" == "true" ]]; then
    PACMAN_TARGETS+=("${NVIDIA_DRIVER}" "${NVIDIA_COMMON_PACKAGES[@]}")
    if [[ -n "${NVIDIA_HEADERS}" ]]; then
      PACMAN_TARGETS+=("${NVIDIA_HEADERS}")
    fi
  else
    PACMAN_TARGETS+=("${PACMAN_PROVIDER_MESA}")
  fi

  drop_installed_targets
}

# Removes targets that are already installed. Every pacman call here passes
# --needed, so pacman would skip them anyway; dropping them first keeps the
# work out of the transaction entirely, which is what makes the provider
# analysis below cheap on a machine that already has most of this stack.
#
# It also stops the provider questions from firing over a package that is
# already there. A virtual stays satisfied by an installed provider, so the
# row is reported as decided rather than asked about.
drop_installed_targets() {
  local -a kept=()
  local -a installed=()
  local pkg

  # `|| true` because pacman -Qq fails on an empty database, and an empty
  # result just means nothing is filtered.
  mapfile -t installed < <(pacman -Qq 2> /dev/null || true)

  if [[ ${#installed[@]} -eq 0 ]]; then
    return 0
  fi

  # One lookup table beats a linear scan per target, and the lists here are
  # long enough for that to matter.
  declare -A is_installed=()
  for pkg in "${installed[@]}"; do
    is_installed["${pkg}"]=1
  done

  for pkg in "${PACMAN_TARGETS[@]}"; do
    if [[ -n "${is_installed[${pkg}]:-}" ]]; then
      continue
    fi
    kept+=("${pkg}")
  done

  local -i dropped=$((${#PACMAN_TARGETS[@]} - ${#kept[@]}))
  PACMAN_TARGETS=("${kept[@]}")

  if (( dropped > 0 )); then
    info "${dropped} target(s) already installed, left out of the transaction."
  fi
}

# Walks the sync databases and reports every dependency that has more than one
# provider, before pacman gets the chance to ask about one of them. On a first
# boot the console is 80x24 and a long list scrolls off the top, so answering
# the real prompt means guessing; this makes the whole decision visible up
# front, with the entry this installer wants marked.
# Fills PROVIDER_REPORT with the current analysis of PACMAN_TARGETS. Split out
# of the preview so the interactive resolver can re-run it after each answer
# without duplicating the analyzer.
#
# Reads the databases straight off disk rather than shipping a snapshot, so
# the answer reflects the mirrors as they are now. Nothing is extracted: the
# tar streams to stdout and one awk pass indexes all ~15k records in well
# under a second.
#
# Emits one tab separated line per multi-provider dependency:
#   AMB <virtual> <needed-by> <recommendation|-> <pinned|open> <provider>...
# and a trailing COUNT line. "pinned" means an explicit target already
# provides it, which is what stops pacman asking.
#
# Arguments are seed packages to walk from in addition to PACMAN_TARGETS. They
# are dependencies of an AUR package, reached through the AUR RPC rather than
# named in any transaction, and they are walked but not treated as targets: a
# seed is not a decision, it is the way in. Their own dependencies are followed
# all the same, which is how an AUR package ends up putting a question about an
# official virtual to the user.
#
# A virtual already put to the user is left out of the report. The AUR step
# walks a different set of seeds but reaches back into the official
# repositories, where the pacman step has already decided things like the
# opengl driver, and asking the same question twice reads as the first answer
# having been ignored.
analyze_virtual_providers() {
  local program='
  function flush(   a, i, n) {
    if (name == "") return
    if (deps != "") depsby[name] = deps
    n = split(provs, a, ",")
    for (i = 1; i <= n; i++) {
      if (a[i] == "") continue
      provby[a[i]] = (a[i] in provby) ? provby[a[i]] "," name : name
    }
    # A dependency is already decided when an explicit target provides it, or
    # when a package already on the system does. The second case is what keeps
    # a re-run on a configured machine from asking questions about providers it
    # already has, since those targets were dropped before the analysis.
    if (name in isexplicit || name in isinstalled) {
      satisfied[name] = 1
      for (i = 1; i <= n; i++) if (a[i] != "") satisfied[a[i]] = 1
    }
    name = ""; provs = ""; deps = ""; sect = ""
  }
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  # libalpm filters providers by the architecture of the requiring package, so a
  # 64-bit consumer is never offered a lib32- candidate. This drops them from
  # the list for that reason, which is two things at once.
  #
  # It is noise to show a 32-bit package as a candidate for a 64-bit dependency.
  # And picking one would append it to the target list, where it cannot satisfy
  # the dependency that asked, so the answer would be wrong rather than merely
  # ugly. The choice is pl[1] in the walk below and a line in the report, so
  # both go through here.
  #
  # Only ever removes a lib32- entry when something unprefixed survives, so a
  # virtual whose only providers are 32-bit still lists them.
  function drop_multilib(   i, n, m, nx64) {
    if (d !~ /^lib.*\.so$/) return provby[d]
    n = split(provby[d], pl, ",")
    nx64 = 0
    for (i = 1; i <= n; i++) if (pl[i] !~ /^lib32-/) nx64++
    if (nx64 == 0) return provby[d]
    kept = ""
    for (i = 1; i <= n; i++) {
      if (pl[i] ~ /^lib32-/) continue
      kept = (kept == "") ? pl[i] : kept "," pl[i]
    }
    return kept
  }
  # True when a libfoo.so is not a real choice for an x86_64 user: every
  # provider is the same package under both architectures, so after
  # drop_multilib() there is one candidate and nothing to ask.
  #
  # It used to be suppressed whenever a lib32- provider existed alongside any
  # non-lib32 one, which also swallowed the cases where x86_64 genuinely has two
  # different packages to choose between and lib32- merely mirrors both:
  #
  #   libjack.so   jack2, pipewire-jack   + lib32-jack2, lib32-pipewire-jack
  #   libz.so      zlib, zlib-ng-compat   + the lib32- pair
  #   libxml2.so   libxml2, libxml2-legacy
  #
  # Those are real questions a 64-bit user gets asked, and several are reachable
  # from the target list in this file: libjack.so through waybar and portaudio,
  # libz.so through curl, file, libarchive, harfbuzz and leptonica, libxml2.so
  # through libarchive, libcrypt.so through pam and shadow, libxtables.so through
  # iproute2. Suppressing them is the one way this feature could fail at the
  # pacman picker with no report, which is what it exists to prevent.
  #
  # Soname deps are visible here, which is worth stating because it is not
  # obvious. libalpm stores the computed soname dependencies of a package in the
  # xdata of the local database rather than in %DEPENDS%, but the sync databases
  # are written by the same writer and do carry them: 4195 soname entries across
  # the three repositories, indexed here like any other dependency. The earlier
  # comment on this function said the opposite, from reading a local desc file
  # where they are genuinely absent.
  function multilib_only(   i, n, nx64) {
    if (d !~ /^lib.*\.so$/) return 0
    n = split(drop_multilib(), pl, ",")
    nx64 = 0
    for (i = 1; i <= n; i++) if (pl[i] != "") nx64++
    return (nx64 < 2)
  }
  BEGIN {
    FS = "\n"; total = 0; open = 0
    nt = split(targets, tl, " ")
    for (i = 1; i <= nt; i++) if (tl[i] != "") isexplicit[tl[i]] = 1
    ni = split(installed, il, " ")
    for (i = 1; i <= ni; i++) if (il[i] != "") isinstalled[il[i]] = 1
    nk = split(asked, kl, " ")
    for (i = 1; i <= nk; i++) if (kl[i] != "") isasked[kl[i]] = 1
  }
  /^%NAME%$/ { flush(); sect = "NAME"; next }
  /^%[A-Z]+%$/ { sect = $0; sub(/^%/, "", sect); sub(/%$/, "", sect); next }
  {
    if (sect == "NAME") { if (name == "") name = trim($0) }
    else if (sect == "PROVIDES") {
      line = $0; sub(/=.*$/, "", line); line = trim(line)
      if (line != "") provs = (provs == "" ? line : provs "," line)
    }
    else if (sect == "DEPENDS") {
      line = $0; sub(/:.*$/, "", line); sub(/[<>=].*$/, "", line); line = trim(line)
      if (line != "") deps = (deps == "" ? line : deps "," line)
    }
  }
  END {
    flush()
    nrec = split(recs, r, ",")
    for (i = 1; i <= nrec; i++) {
      p = index(r[i], "=")
      if (p > 0) recfor[substr(r[i], 1, p - 1)] = substr(r[i], p + 1)
    }
    nt = split(targets, tl, " ")
    for (i = 1; i <= nt; i++) {
      if (tl[i] == "" || (tl[i] in seen_name)) continue
      seen_name[tl[i]] = 1; q[++nq] = tl[i]
    }
    # Seeds join the queue behind the targets, and the seen check above keeps a
    # seed that is also a target from being walked twice.
    ns = split(seeds, sl, " ")
    for (i = 1; i <= ns; i++) {
      if (sl[i] == "" || (sl[i] in seen_name)) continue
      seen_name[sl[i]] = 1; q[++nq] = sl[i]
    }
    head = 1
    while (head <= nq) {
      cur = q[head++]
      if (!(cur in depsby)) continue
      nd = split(depsby[cur], dl, ",")
      for (j = 1; j <= nd; j++) {
        d = dl[j]
        if (d == "" || (d in seen_name)) continue
        np = (d in provby) ? split(drop_multilib(), pl, ",") : 0
        if (np == 0) continue
        seen_name[d] = 1
        # A virtual already put to the user is left out of the report, but the
        # walk carries on through it below either way: something behind it can
        # be ambiguous too.
        if (np > 1 && !multilib_only() && !(d in isasked)) {
          total++
          state = (d in satisfied) ? "pinned" : "open"
          if (state == "open") open++
          rec = (d in recfor) ? recfor[d] : "-"
          line = "AMB\t" d "\t" cur "\t" rec "\t" state
          for (k = 1; k <= np; k++) line = line "\t" pl[k]
          print line
        }
        chosen = (d in depsby) ? d : pl[1]
        if ((chosen in depsby) && !(chosen in seen_pkg)) {
          seen_pkg[chosen] = 1; q[++nq] = chosen
        }
      }
    }
    print "COUNT\t" total "\t" open
  }'

  local -a dbs=(/var/lib/pacman/sync/*.db)
  if [[ ! -e "${dbs[0]}" ]]; then
    warn "No pacman sync databases found, skipping the provider preview."
    PROVIDER_REPORT=""
    return 0
  fi

  # IFS is newline and tab in this script, so join by hand for the -v argument.
  local targets=""
  printf -v targets '%s ' "${PACMAN_TARGETS[@]}"

  # The installed set is passed in so a dependency already satisfied by
  # something on the system counts as decided. Without it a second run on a
  # configured machine asks about every provider again, because the targets
  # that would have answered those questions were dropped as already present.
  local installed=""
  printf -v installed '%s ' $(pacman -Qq 2> /dev/null || true)

  # Recommendations come from the single table in provider_recommendations, so a
  # provider added there reaches the preview, the resolver and the post-install
  # check without being written out a second and third time. The three used to be
  # separate lists and had already drifted: the check named jack2 as a provider
  # of jack, which it is not.
  local recs rec_line
  recs=""
  while IFS= read -r rec_line; do
    [[ -z "${rec_line}" ]] && continue
    recs+="${recs:+,}${rec_line}"
  done < <(provider_recommendations)

  # Seeds and the already-asked list are space joined for the same reason.
  #
  # Seeds given as arguments are remembered, because resolve_virtual_providers
  # re-runs this analysis once per round to catch the follow-up rows an answer
  # surfaces, and it calls it with no arguments. Without this the AUR step's
  # seeds survived only the first round, so from round two the walk started from
  # the providers chosen so far and anything reachable only through an AUR
  # dependency was never reported. The five round loop silently degraded to one.
  local seeds=""
  if [[ $# -gt 0 ]]; then
    printf -v seeds '%s ' "$@"
    ANALYZER_SEEDS=("${@}")
  elif [[ ${#ANALYZER_SEEDS[@]} -gt 0 ]]; then
    printf -v seeds '%s ' "${ANALYZER_SEEDS[@]}"
  fi

  # `|| true` so a missing tar or awk degrades to no report instead of
  # aborting the install.
  PROVIDER_REPORT="$(for db in "${dbs[@]}"; do
    tar -xzOf "${db}" 2> /dev/null || true
  done | awk -v targets="${targets}" -v recs="${recs}" \
    -v installed="${installed}" -v seeds="${seeds}" \
    -v asked="${ASKED_VIRTUALS}" "${program}")" || true
}

# Tab separated analysis of the current target list, refreshed by
# analyze_virtual_providers. Empty when the sync databases are unreadable.
PROVIDER_REPORT=""

# Seeds the current analysis was started from, so the per-round re-analysis
# inside resolve_virtual_providers walks the same set rather than only what the
# previous round's answers happened to reach.
ANALYZER_SEEDS=()

# Basenames whose backup copy failed in create_backup, read by create_symlinks
# so it leaves those in place instead of deleting the only remaining copy.
BACKUP_FAILED=()

# Virtuals already put to the user, space separated, and read by the analyzer to
# keep a question from being asked twice. Unlike the report above this survives
# from one step to the next, which is the point: the AUR step reuses the analyzer
# and reaches back into the packages the pacman step has already decided.
ASKED_VIRTUALS=""

# The rows for the choices made by the last resolve_virtual_providers call, one
# per line as virtual|chosen provider|pattern matching its providers, ready for
# report_providers to check once the install is done. Reset by every resolver
# call, so it always describes the step that just asked.
RESOLVED_PROVIDERS=()

# Walks the sync databases and reports every dependency that has more than one
# provider, before pacman gets the chance to ask about one of them. On a first
# boot the console is 80x24 and a long list scrolls off the top, so answering
# the real prompt means guessing; this makes the whole decision visible up
# front, with the entry this installer wants marked.
#
# The optional argument says where this set of dependencies came from. It is
# printed under the heading and suppresses the longer explanation of why the
# question is being asked at all, which the AUR step does not need to repeat
# two steps after the first one already gave it.
preview_virtual_providers() {
  local report="${PROVIDER_REPORT}"
  local origin="${1:-}"

  if [[ -z "${report}" ]]; then
    return 0
  fi

  printf "\n"
  printf "${BOLD}Dependencies that have more than one provider${NC}\n"
  if [[ -n "${origin}" ]]; then
    printf "  ${CYAN}Reached from %s.${NC}\n" "${origin}"
  else
    printf "  ${CYAN}pacman asks about these one at a time. On an 80x24 console the\n"
    printf "  list scrolls off the top, so you are asked below instead, with the\n"
    printf "  same numbering and the recommendation marked.${NC}\n"
  fi
  printf "\n"

  local line virtual needed_by rec provider
  local -a fields
  local -i number
  local -i total=0 open_count=0
  while IFS= read -r line; do
    if [[ -z "${line}" ]]; then
      continue
    fi
    IFS=$'\t' read -r -a fields <<< "${line}"

    if [[ "${fields[0]}" == "COUNT" ]]; then
      total="${fields[1]}"
      open_count="${fields[2]}"
      continue
    fi

    # fields[4] is the pinned/open state, which every row is now asked about
    # regardless of, so it is not read here.
    virtual="${fields[1]}"
    needed_by="${fields[2]}"
    rec="${fields[3]}"

    printf "  ${BOLD}%s${NC}  ${CYAN}(needed by %s)${NC}\n" "${virtual}" "${needed_by}"
    number=0
    for provider in "${fields[@]:5}"; do
      number+=1
      if [[ "${provider}" == "${rec}" ]]; then
        printf "     %2d) %s  ${GREEN}<- recommended${NC}\n" "${number}" "${provider}"
      else
        printf "     %2d) %s\n" "${number}" "${provider}"
      fi
    done
    printf "\n"
  done <<< "${report}"

  if [[ "${open_count}" -eq 0 ]]; then
    msg "${total} ambiguous dependencies, every one covered by an installer default."
  else
    warn "${total} ambiguous dependencies, ${open_count} decided only by the answer below."
  fi
  printf "\n"
}

# Asks about every multi-provider dependency, and appends the answer to the
# target list so the install itself never blocks. The question is asked here
# rather than left to pacman because pacman cannot show the list properly on a
# first boot, and because the answer can be acted on: a chosen provider is
# just another explicit target.
#
# Every one is asked, including the ones the list above already pins. A
# recommendation is a default, not a decision: the pinned entries are
# reasonable readings of what this desktop wants, but the person running the
# install is the one who knows whether they want the wlr portal instead of the
# gnome one, or a lighter font package. Each prompt shows the recommendation
# marked and takes it on a bare Enter, so the common case stays a single key
# press while overriding stays possible.
resolve_virtual_providers() {
  local -i round
  local tab=$'\t'
  # Virtuals already put to the user. Answering one makes it pinned rather
  # than open, but it stays in the report, so without this the loop would ask
  # the same question five times.
  local -A asked=()

  # The rows checked after the install describe the choices made here, so the
  # previous step's are dropped rather than reported a second time.
  RESOLVED_PROVIDERS=()

  # An answer can pull in packages that are ambiguous in their own right, the
  # way choosing pipewire-jack surfaces pipewire-session-manager, so the
  # analysis is repeated to catch the follow-up rows. The bound is a guard
  # against a pathological mirror rather than an expected exit.
  for (( round = 1; round <= 5; round++ )); do
    local -a pending_rows=()
    local line
    local -a fields

    while IFS= read -r line; do
      if [[ -z "${line}" ]]; then
        continue
      fi
      IFS=$'\t' read -r -a fields <<< "${line}"
      # fields is  <kind> <virtual> <needed-by> <rec> <state> <providers...>
      # so the providers start at index 5. Storing the line with the leading
      # "AMB\t" already removed keeps the slicing in ask_for_provider readable.
      #
      # The removal uses a literal tab assigned to a variable rather than
      # $'\t' inline: nesting $'...' inside ${var#...} inside double quotes is
      # a parse error in bash when it appears in an array assignment.
      if [[ "${fields[0]}" == "AMB" && -z "${asked[${fields[1]}]:-}" ]]; then
        pending_rows+=("${line#*"${tab}"}")
      fi
    done <<< "${PROVIDER_REPORT}"

    if [[ ${#pending_rows[@]} -eq 0 ]]; then
      if (( round > 1 )); then
        msg "Provider choices settled after $((round - 1)) round(s)."
      fi
      return 0
    fi

    if (( round == 1 )); then
      printf "\n"
      printf "${BOLD}Choosing providers${NC}\n"
      printf "  ${CYAN}Each of these has more than one provider. The recommendation is\n"
      printf "  marked and taken on a bare Enter; pick a number to override it.\n"
      printf "  ${CYAN}Answering here means pacman never stops to ask during the install.${NC}\n"
      printf "\n"
    fi

    local row
    for row in "${pending_rows[@]}"; do
      IFS=$'\t' read -r -a fields <<< "${row}"
      asked["${fields[0]}"]=1
      ask_for_provider "${fields[@]}"
    done

    analyze_virtual_providers
  done

  # Reached only by exhausting the loop: settling returns from inside it.
  warn "Stopped after 5 rounds with ${#asked[@]} chosen. See the list above."
}

# Prints one numbered provider list and reads the choice, then appends the
# chosen package to PACMAN_TARGETS. The virtual goes on the list of questions
# already asked, and the choice goes into RESOLVED_PROVIDERS so it can be
# checked against what actually got installed.
#
# Takes the fields of one AMB row in order: virtual, the package that needs
# it, the recommendation, the state, then the providers. The state is skipped
# rather than named because the providers start after it.
ask_for_provider() {
  local virtual="$1" needed_by="$2" rec="$3" state="$4"
  shift 4
  local -a providers=("$@")

  local -i count=${#providers[@]}
  local -i default=1 number
  local choice=""

  printf "\n"
  if [[ "${state}" == "pinned" ]]; then
    printf "  ${BOLD}%s${NC}  ${CYAN}(needed by %s, installer default below)${NC}\n" \
      "${virtual}" "${needed_by}"
  else
    printf "  ${BOLD}%s${NC}  ${CYAN}(needed by %s)${NC}\n" "${virtual}" "${needed_by}"
  fi

  for (( number = 1; number <= count; number++ )); do
    if [[ "${providers[number - 1]}" == "${rec}" ]]; then
      default=number
      printf "     %2d) %s  ${GREEN}<- recommended${NC}\n" "${number}" "${providers[number - 1]}"
    else
      printf "     %2d) %s\n" "${number}" "${providers[number - 1]}"
    fi
  done

  # `|| true` so a closed stdin takes the recommendation rather than tripping
  # set -e and aborting the install.
  if ! read -r -p "     Provider? [1-${count}, default ${default}]: " choice < /dev/tty; then
    printf "\n"
    warn "No input available, taking ${providers[default - 1]}."
    choice=""
  else
    printf "\n"
  fi

  if [[ -z "${choice}" ]]; then
    choice="${default}"
  elif [[ ! "${choice}" =~ ^[0-9]+$ ]] ||
    # 10# so a leading zero is not read as octal: "08" and "09" are not valid
    # octal, and bash prints a "value too great for base" error to stderr
    # before the || recovers with the default.
    (( 10#${choice} < 1 || 10#${choice} > count )); then
    warn "'${choice}' is not one of 1-${count}, taking ${providers[default - 1]}."
    choice="${default}"
  fi

  local picked="${providers[choice - 1]}"
  PACMAN_TARGETS+=("${picked}")
  ASKED_VIRTUALS+="${virtual} "

  # Recorded as virtual|answer, and only the answer. The check after the install
  # used to be handed the provider list as a regular expression so it could name
  # every provider rather than just the chosen one, but it now reads the real
  # providers out of the sync databases, so the list is not needed here and a
  # snapshot of it could only go stale.
  RESOLVED_PROVIDERS+=("${virtual}|${picked}")

  msg "${virtual} -> ${picked}"
}

# Says out loud which provider of each virtual is actually installed, so a wrong
# pick does not stay silent: the desktop still comes up and the affected feature
# just quietly does not work.
# Emits "virtual<TAB>provider" for every virtual that an installed package
# provides, one pair per line, sorted. Read once by report_providers below.
#
# This is the whole point of the function: the checks used to carry a
# hand-written regular expression listing the providers, which is a snapshot of
# one repository state and goes wrong in both directions at once. A provider
# added since the pattern was written is invisible, so a virtual that is
# satisfied looks unsatisfied; and a pattern listing several alternatives cannot
# say which one won, so it reported the expected provider as installed when it
# was merely present alongside the one that actually got chosen.
#
# The index comes from the same sync databases the analyzer reads, so it cannot
# disagree with it, and pacman -Qq supplies the installed set, so a provider
# that is not installed is not listed. `pacman -Qo` would be no use here: the
# shared directories report every package on the system.
installed_provider_index() {
  local -a dbs=(/var/lib/pacman/sync/*.db)
  local installed=""

  if [[ ! -e "${dbs[0]}" ]]; then
    return 0
  fi

  printf -v installed '%s ' $(pacman -Qq 2> /dev/null || true)

  for db in "${dbs[@]}"; do
    tar -xzOf "${db}" 2> /dev/null || true
  done | awk -v installed="${installed}" '
    # The installed set, as a lookup table. Without it flush() would skip every
    # record, since the test is `name in isinstalled`.
    BEGIN {
      ni = split(installed, il, " ")
      for (i = 1; i <= ni; i++) if (il[i] != "") isinstalled[il[i]] = 1
    }
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function flush(   i, n) {
      if (name == "" || !(name in isinstalled)) { name = ""; provs = ""; return }
      n = split(provs, a, ",")
      for (i = 1; i <= n; i++) {
        if (a[i] == "") continue
        print a[i] "\t" name
      }
      name = ""; provs = ""
    }
    # Dispatch is on the field name, and a record ends at the next %NAME% rather
    # than at a blank line. The fields of one record are separated by blank
    # lines and %PROVIDES% comes after %NAME%, so flushing on a blank would
    # discard the name before the provides were read.
    /^%NAME%$/      { flush(); sect = "NAME"; next }
    /^%[A-Z]+%$/    { sect = $0; sub(/^%/, "", sect); sub(/%$/, "", sect); next }
    {
      if (sect == "NAME") { if (name == "") name = trim($0) }
      else if (sect == "PROVIDES") {
        line = $0; sub(/=.*$/, "", line); line = trim(line)
        if (line != "") provs = (provs == "") ? line : provs "," line
      }
    }
    END { flush() }
  ' 2> /dev/null | sort -u || true
}

# Arguments are virtual|expected provider, one per argument, and the expected
# provider is compared against what is actually installed rather than against a
# pattern: a recommendation for the ones this installer pinned, and the person's
# own choice for the ones resolve_virtual_providers asked about, since warning
# someone about the answer they just gave would be pointless.
report_providers() {
  local entry virtual expected found

  # Built once for the whole table rather than per entry, because reading the
  # sync databases is the expensive part.
  local index
  index="$(installed_provider_index)"

  for entry in "$@"; do
    IFS='|' read -r virtual expected <<< "${entry}"

    found="$(printf '%s\n' "${index}" | awk -F'\t' -v v="${virtual}" '$1 == v { print $2 }' | tr '\n' ' ' || true)"
    found="${found% }"

    if [[ -z "${found}" ]]; then
      warn "No provider of '${virtual}' is installed, expected ${expected}."
      continue
    fi

    if [[ " ${found} " == *" ${expected} "* ]]; then
      msg "${virtual} -> ${expected}"
    else
      warn "${virtual} resolved to ${found} instead of ${expected}."
      info "Install ${expected} and remove the others if this feature misbehaves."
    fi
  done
}

# Pinning the providers above removes today's prompts, but it cannot cover
# every virtual a future package release might add, and the picker gives no
# hint that an answer matters. So check afterwards which providers actually
# landed and say so out loud.
verify_virtual_providers() {
  # The table is provider_recommendations, the same one the preview and the
  # resolver read. report_providers takes virtual|expected and reads the real
  # provider list out of the sync databases, so nothing here is a hand-written
  # pattern that can rot.
  #
  # The virtuals reached only from an AUR package are not in it, because their
  # recommendation depends on metadata fetched at run time rather than on this
  # table. Those are checked against the answers given, by the AUR step.
  local entry virtual expected
  local -a checks=()

  while IFS= read -r entry; do
    [[ -z "${entry}" ]] && continue
    IFS='=' read -r virtual expected <<< "${entry}"

    # org.freedesktop.secrets is in the table for the preview and the resolver,
    # but it is not checked here. Nothing in PACMAN_PACKAGES wants it: it is
    # reached only from an AUR package, through vicinae-bin's qtkeychain
    # dependency, so install_aur_packages is the step that asks about it -- and
    # that step runs after this one. Checking it here would warn about a
    # provider the person has not been asked to choose yet, on a machine that
    # already has one, which is exactly the case this check exists to be quiet
    # in. The AUR step checks it against the answer given.
    if [[ "${virtual}" == "org.freedesktop.secrets" ]]; then
      continue
    fi

    checks+=("${virtual}|${expected}")
  done < <(provider_recommendations)

  report_providers "${checks[@]}"
}

# The dependencies of every package in AUR_PACKAGES, one per line.
#
# The analyzer walks the sync databases, and an AUR package is in neither of
# them: it is built from a PKGBUILD that lives only on the AUR. Those dependency
# lists are the edges leading out of the AUR packages and into the official
# repositories, which is where the interesting virtuals are: for vicinae-bin it
# is qtkeychain-qt6 and the org.freedesktop.secrets virtual, but the shape is
# the same for any package, and the union of the lists is all the walk needs to
# see the whole graph and put the question in front of the user instead of
# pacman. The RPC serves them as JSON without building anything.
#
# A dependency that is itself only on the AUR cannot be walked into, because
# nothing local describes it. That is a real limit and the one to watch when
# packages are added here: a virtual buried in the dependencies of an AUR
# package's own AUR dependency is still asked by pacman, and the deeper the
# chain of AUR-to-AUR dependencies, the likelier that becomes. Every dependency
# of the packages in this list is an official one, so it does not bite yet, and
# the AUR helper would have to build a package to find out more.
#
# Nothing is fatal about failing to reach the AUR, or about curl not being
# there. The caller falls back to naming a provider rather than asking, which is
# the same outcome this had before the question was added, and curl is installed
# by the base tools step long before this runs.
aur_dependencies() {
  if [[ ${#AUR_PACKAGES[@]} -eq 0 ]]; then
    return 0
  fi

  # v5/info takes one package per URL, so the list goes in as the repeated
  # arguments of the older form, which does take several. The brackets are
  # percent encoded because a bare [ is not a legal character in a query string.
  local url="https://aur.archlinux.org/rpc/?v=5&type=info"
  local pkg
  for pkg in "${AUR_PACKAGES[@]}"; do
    url+="&arg%5B%5D=${pkg}"
  done

  # `|| true` and the Depends check below: an unreachable AUR means the question
  # cannot be asked, not that the install is over.
  local response
  response="$(curl -fsS --max-time 20 "${url}" 2> /dev/null)" || return 0
  if [[ "${response}" != *'"Depends"'* ]]; then
    return 0
  fi

  # "Depends":["a","b"] out to one name per line. jq is not used because the
  # array is all that is wanted from the response and this reads it without a
  # parser: the RPC returns the lot on one line, and the only quoted strings
  # between the brackets are the names. Duplicates across several packages are
  # harmless, the analyzer walks a package once.
  printf '%s' "${response}" |
    tr -d '\n' |
    grep -oE '"Depends":\[[^]]*\]' |
    sed 's/^"Depends":\[//; s/\]$//' |
    grep -oE '"[^"]+"' |
    tr -d '"' |
    tr ' ' '\n' |
    grep -v '^$' || true
}

install_aur_packages() {
  info "Installing AUR packages using ${AUR_HELPER}..."

  local -a targets=("${AUR_PACKAGES[@]}")
  local -a checks=()
  local -a seeds=()
  mapfile -t seeds < <(aur_dependencies)

  if [[ ${#seeds[@]} -gt 0 ]]; then
    # The same treatment the official packages get, for every AUR package in the
    # list: walk in from their dependencies, show what is ambiguous, and ask.
    # None of them are in the pacman step's target list, so nothing reachable
    # from one has been asked yet, and PACMAN_TARGETS is emptied so the answers
    # land on their own. Nothing reads that list again after this step, so it is
    # left holding the answers.
    PACMAN_TARGETS=()
    analyze_virtual_providers "${seeds[@]}"
    preview_virtual_providers "the AUR packages"
    resolve_virtual_providers

    # A chosen provider is a package name like any other, so it goes in the same
    # transaction: the helper hands it to pacman, which finds it in the official
    # repositories.
    if [[ ${#PACMAN_TARGETS[@]} -gt 0 ]]; then
      targets+=("${PACMAN_TARGETS[@]}")
    fi
    checks=("${RESOLVED_PROVIDERS[@]}")
  else
    # No metadata, so there is nothing to walk from and the question cannot be
    # asked. Naming the one provider this list knows about is the best that can
    # be done without the dependency lists, and it settles the virtual currently
    # expected here. It cannot settle a virtual that a package added to
    # AUR_PACKAGES later turns out to want, so on this path such a question
    # would still reach pacman; there is no way to know what it is without the
    # metadata, which is exactly what is missing. The AUR serves the RPC and the
    # PKGBUILD alike, so reaching this means the AUR is unreachable and the
    # install below is about to fail anyway.
    warn "Could not read the AUR metadata, so the provider questions are skipped."
    info "Naming ${PACMAN_PROVIDER_SECRETS} instead, so pacman does not stop to ask."
    targets+=("${PACMAN_PROVIDER_SECRETS}")
  fi

  # IFS is newline+tab in this script, so join explicitly for a single-line hint.
  local target_list
  printf -v target_list '%s ' "${targets[@]}"
  info "Installing: ${target_list% }"
  info "This may take several minutes..."

  if "${AUR_HELPER}" -S --needed "${targets[@]}" < /dev/tty 2>&1 | log_and_show "${LOG_FILE}"; then
    msg "AUR packages installed successfully."
  else
    fatal "Failed to install AUR packages."
  fi

  # A no-op when nothing was asked, which is the case for the fallback above.
  report_providers "${checks[@]}"
}

# ==========================
# GREETER MANAGEMENT
# ==========================

disable_conflicting_display_managers() {
  local service
  local -a disabled=()

  for service in "${CONFLICTING_DMS[@]}"; do
    if ! systemctl list-unit-files "${service}.service" &> /dev/null; then
      continue
    fi

    if systemctl is-enabled --quiet "${service}.service" &> /dev/null; then
      # Never --now. If this install is being run from inside a GDM/SDDM/LightDM
      # session then stopping that display manager ends the session, and the
      # installer with it, at the second to last step with the dotfiles already
      # in place. Disabling is enough: it is off at the next boot, which is
      # when greetd needs it to be.
      if sudo systemctl disable "${service}.service" > /dev/null 2>&1; then
        disabled+=("${service}")
        msg "Disabled conflicting display manager: ${service} (takes effect at next boot)"
      else
        warn "Could not disable ${service}. Turn it off manually: sudo systemctl disable ${service}"
      fi
    fi
  done

  if [[ ${#disabled[@]} -eq 0 ]]; then
    info "No conflicting display manager is enabled."
  elif [[ ${#disabled[@]} -gt 0 ]]; then
    # Without --now the old display manager is still running, and it owns the
    # session this install may be running inside. Say so rather than letting
    # the user find out at their next login.
    info "Log out and back in, or reboot, for the change to take effect."
    info "Until then the display manager you are logged into is still the one running."
  fi
}

write_greetd_config() {
  local config_file="/etc/greetd/config.toml"

  if [[ -f "${config_file}" ]]; then
    if sudo cp -f "${config_file}" "${config_file}.jupiter-backup" 2> /dev/null; then
      warn "Existing greetd config backed up to ${config_file}.jupiter-backup"
    else
      warn "Could not back up ${config_file}. It will be overwritten."
    fi
  fi

  info "Writing greetd configuration to ${config_file}..."

  # niri-session sets up the systemd user session and XDG environment, which a
  # bare `niri` does not. --asterisks gives feedback while typing, --remember
  # pre-fills the username. The F3 session menu picks up niri.desktop from the
  # default /usr/share/wayland-sessions, so no --sessions flag is needed.
  if sudo tee "${config_file}" > /dev/null 2>&1 << 'GREETER_CONFIG'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --asterisks --cmd niri-session"
user = "greeter"
GREETER_CONFIG
  then
    msg "greetd configuration written."
  else
    fatal "Failed to write ${config_file}."
  fi
}

configure_greeter() {
  info "Configuring the login greeter..."

  # IFS is newline+tab in this script, so join explicitly for single-line hints.
  local package_list
  printf -v package_list '%s ' "${GREETER_PACKAGES[@]}"
  package_list="${package_list% }"

  printf "\n"
  printf "${BOLD}These packages will be installed:${NC}\n"
  printf "  ${CYAN}greetd${NC}             minimal console display manager, takes over TTY1\n"
  printf "  ${CYAN}greetd-tuigreet${NC}    terminal greeter used in place of greetd's GTK one\n"
  printf "\n"
  printf "${BLUE}${BOLD}What this does:${NC}\n"
  printf "  • Takes over the graphical login screen on TTY1\n"
  printf "  • Other display managers (gdm, lightdm, sddm) are disabled if enabled\n"
  printf "  • Turn the greeter off with: ${CYAN}sudo systemctl disable greetd${NC}\n"
  printf "\n"
  printf "${BLUE}${BOLD}Note:${NC}\n"
  printf "  • It is enabled but not started now, so it takes effect on next boot\n"
  printf "  • The greeter starts niri after you log in\n"
  printf "\n"

  local reply=""
  # `|| true` so a closed stdin counts as "no" rather than tripping set -e
  # and aborting the install at the last step through the ERR trap.
  read -r -p "Install and enable the greetd + tuigreet greeter? (Y/n): " reply < /dev/tty || true
  printf "\n"

  if [[ "${reply}" =~ ^[Nn]$ ]]; then
    warn "Skipping greeter setup."
    info "Set it up later with: ${CYAN}sudo pacman -S ${package_list}${NC}"
    return 0
  fi

  # greetd 0.10.3 depends on the greetd-greeter virtual as well as on
  # greetd-agreety by name, so this call is where pacman would open a provider
  # picker: three packages provide the virtual, greetd-agreety, greetd-regreet
  # and this one. Naming greetd-tuigreet on the command line is what settles it.
  # Keep it, and keep the pair in one call: a bare `pacman -S greetd` here would
  # ask. This is the one provider in the installer that is named rather than
  # asked about, because which greeter runs is a choice about the look of the
  # login screen rather than a gap in the desktop, and tuigreet is what this one
  # wants.
  if ! binary_installed tuigreet || ! pacman -Qi greetd &> /dev/null; then
    info "Installing greeter packages..."
    if sudo pacman -S --needed "${GREETER_PACKAGES[@]}" < /dev/tty 2>&1 | log_and_show "${LOG_FILE}"; then
      msg "Greeter packages installed successfully."
    else
      fatal "Failed to install greeter packages."
    fi
  else
    msg "greetd and tuigreet are already installed."
  fi

  if ! binary_installed tuigreet; then
    fatal "tuigreet binary not found after installation."
  fi

  disable_conflicting_display_managers

  # tuigreet stores its remembered username here and it must belong to greeter.
  info "Preparing the tuigreet cache directory..."
  if sudo mkdir -p /var/cache/tuigreet &&
    sudo chown greeter:greeter /var/cache/tuigreet &&
    sudo chmod 0755 /var/cache/tuigreet; then
    msg "tuigreet cache directory ready."
  else
    warn "Could not prepare /var/cache/tuigreet. Remembering the username may not work."
  fi

  write_greetd_config

  info "Enabling greetd service..."
  if sudo systemctl enable greetd.service > /dev/null 2>&1; then
    if systemctl is-enabled --quiet greetd.service; then
      INSTALL_GREETER=true
      msg "greetd enabled. It will start on your next boot."
    else
      fatal "greetd did not reach an enabled state."
    fi
  else
    fatal "Failed to enable greetd.service."
  fi
}

install_colloid_theme() {
  local theme_installed=false
  local themes_dir="${HOME}/.themes"

  if [[ -d "${themes_dir}/Colloid" ]] ||
    [[ -d "${themes_dir}/Colloid-Dark" ]] ||
    [[ -d "${themes_dir}/Colloid-Grey" ]] ||
    [[ -d "${themes_dir}/Colloid-Grey-Dark" ]]; then
    theme_installed=true
  fi

  if [[ "${theme_installed}" == "true" ]]; then
    msg "Colloid GTK theme is already installed. Skipping..."
    return 0
  fi

  local theme_dir
  theme_dir="$(mktemp -d)"

  if [[ ! -d "${theme_dir}" ]]; then
    warn "Failed to create temporary directory for Colloid theme"
    return 1
  fi

  info "Installing Colloid GTK theme..."
  info "Cloning Colloid theme repository (this may take a moment)..."

  if ! retry_command 3 git clone --depth=1 https://github.com/vinceliuice/Colloid-gtk-theme "${theme_dir}" 2>&1 | log_and_show "${LOG_FILE}"; then
    rm -rf "${theme_dir}"
    warn "Failed to clone Colloid theme repository after multiple attempts."
    return 1
  fi

  info "Installing Colloid theme variants..."
  if ! (cd "${theme_dir}" && ./install.sh --libadwaita --tweaks all rimless 2>&1 | log_and_show "${LOG_FILE}"); then
    rm -rf "${theme_dir}"
    warn "Failed to install Colloid theme (default variant)."
    return 1
  fi

  info "Installing Colloid theme (grey-black variant)..."
  if ! (cd "${theme_dir}" && ./install.sh --libadwaita --theme grey --tweaks black rimless 2>&1 | log_and_show "${LOG_FILE}"); then
    rm -rf "${theme_dir}"
    warn "Failed to install Colloid theme (grey-black variant)."
    return 1
  fi

  rm -rf "${theme_dir}"
  msg "Colloid GTK theme installed successfully."
  return 0
}

install_rosepine_theme() {
  local theme_installed=false
  local themes_dir="${HOME}/.themes"

  if [[ -d "${themes_dir}/Rosepine-Dark-Moon" ]] ||
    [[ -d "${themes_dir}/Rosepine-Light-Moon" ]]; then
    theme_installed=true
  fi

  if [[ "${theme_installed}" == "true" ]]; then
    msg "Rose Pine GTK theme is already installed. Skipping..."
    return 0
  fi

  local theme_dir
  theme_dir="$(mktemp -d)"

  if [[ ! -d "${theme_dir}" ]]; then
    warn "Failed to create temporary directory for Rose Pine theme"
    return 1
  fi

  info "Installing Rose Pine GTK theme..."
  info "Cloning Rose Pine theme repository (this may take a moment)..."

  if ! retry_command 3 git clone --depth=1 https://github.com/Fausto-Korpsvart/Rose-Pine-GTK-Theme "${theme_dir}" 2>&1 | log_and_show "${LOG_FILE}"; then
    rm -rf "${theme_dir}"
    warn "Failed to clone Rose Pine theme repository after multiple attempts."
    return 1
  fi

  info "Installing Rose Pine theme with moon variant..."
  if ! (cd "${theme_dir}/themes" && ./install.sh --libadwaita --tweaks moon macos 2>&1 | log_and_show "${LOG_FILE}"); then
    rm -rf "${theme_dir}"
    warn "Failed to install Rose Pine theme."
    return 1
  fi

  rm -rf "${theme_dir}"
  msg "Rose Pine GTK theme installed successfully."
  return 0
}

install_osaka_theme() {
  local theme_installed=false
  local themes_dir="${HOME}/.themes"

  if [[ -d "${themes_dir}/Osaka-Dark-Solarized" ]] ||
    [[ -d "${themes_dir}/Osaka-Light-Solarized" ]]; then
    theme_installed=true
  fi

  if [[ "${theme_installed}" == "true" ]]; then
    msg "Osaka GTK theme is already installed. Skipping..."
    return 0
  fi

  local theme_dir
  theme_dir="$(mktemp -d)"

  if [[ ! -d "${theme_dir}" ]]; then
    warn "Failed to create temporary directory for Osaka theme"
    return 1
  fi

  info "Installing Osaka GTK theme..."
  info "Cloning Osaka theme repository (this may take a moment)..."

  if ! retry_command 3 git clone --depth=1 https://github.com/Fausto-Korpsvart/Osaka-GTK-Theme "${theme_dir}" 2>&1 | log_and_show "${LOG_FILE}"; then
    rm -rf "${theme_dir}"
    warn "Failed to clone Osaka theme repository after multiple attempts."
    return 1
  fi

  info "Installing Osaka theme with solarized variant..."
  if ! (cd "${theme_dir}/themes" && ./install.sh --libadwaita --tweaks solarized macos 2>&1 | log_and_show "${LOG_FILE}"); then
    rm -rf "${theme_dir}"
    warn "Failed to install Osaka theme."
    return 1
  fi

  rm -rf "${theme_dir}"
  msg "Osaka GTK theme installed successfully."
  return 0
}

install_gtk_themes() {
  info "Installing GTK themes..."
  info "This may take several minutes..."

  local themes_dir="${HOME}/.themes"
  mkdir -p "${themes_dir}"

  local installed_themes=()
  local failed_themes=()

  if install_colloid_theme; then
    installed_themes+=("Colloid")
  else
    failed_themes+=("Colloid")
  fi

  if install_rosepine_theme; then
    installed_themes+=("Rose-Pine")
  else
    failed_themes+=("Rose-Pine")
  fi

  if install_osaka_theme; then
    installed_themes+=("Osaka")
  else
    failed_themes+=("Osaka")
  fi

  if [[ ${#installed_themes[@]} -gt 0 ]]; then
    msg "Successfully installed ${#installed_themes[@]} GTK theme(s): $(IFS=' ' ; echo "${installed_themes[*]}")"
  fi

  if [[ ${#failed_themes[@]} -gt 0 ]]; then
    # "${failed_themes[*]}" alone joins with the first character of IFS, which
    # line 4 sets to $'\n\t', so it printed one theme per line inside a single
    # warn and, because log() uses $*, as a multi-line log entry.
    local joined_failed_themes
    joined_failed_themes="$(IFS=' ' ; echo "${failed_themes[*]}")"
    warn "Failed to install ${#failed_themes[@]} GTK theme(s): ${joined_failed_themes}"
    warn "You can manually install these themes later if needed."
  fi

  # A theme is cosmetic. Returning 1 here reached the ERR trap through set -e
  # and killed an install that had not yet reached the dotfiles, over a GitHub
  # outage while cloning a stylesheet. The failure is already reported above and
  # the install carries on without it.
  if [[ ${#installed_themes[@]} -eq 0 ]]; then
    warn "No GTK themes were installed. The desktop will use the default theme."
    warn "theme-sync.sh will report this until a theme is installed by hand."
  fi

  return 0
}

install_colloid_icons() {
  local icon_dir="${HOME}/.icons"

  if [[ -d "${icon_dir}/Colloid" ]]; then
    msg "Colloid icon theme is already installed. Skipping..."
    return 0
  fi

  local icons_dir
  icons_dir="$(mktemp -d)"

  if [[ ! -d "${icons_dir}" ]]; then
    warn "Failed to create temporary directory for Colloid icons"
    return 1
  fi

  info "Installing Colloid icon theme..."
  info "Cloning Colloid icon theme repository (this may take a moment)..."

  if ! retry_command 3 git clone --depth=1 https://github.com/vinceliuice/Colloid-icon-theme "${icons_dir}" 2>&1 | log_and_show "${LOG_FILE}"; then
    rm -rf "${icons_dir}"
    warn "Failed to clone Colloid icon theme repository after multiple attempts."
    return 1
  fi

  info "Installing Colloid icon theme with all schemes (bold)..."
  # -d ensures we install to ~/.icons and do NOT trigger a hidden sudo prompt
  if ! (cd "${icons_dir}" && ./install.sh -d "${HOME}/.icons" --scheme all --bold 2>&1 | log_and_show "${LOG_FILE}"); then
    rm -rf "${icons_dir}"
    warn "Failed to install Colloid icon theme."
    return 1
  fi

  rm -rf "${icons_dir}"
  msg "Colloid icon theme installed successfully."
  return 0
}

install_icon_themes() {
  info "Installing icon themes..."
  info "This may take several minutes..."

  local icons_dir="${HOME}/.icons"
  mkdir -p "${icons_dir}"

  local installed_icons=()
  local failed_icons=()

  if install_colloid_icons; then
    installed_icons+=("Colloid")
  else
    failed_icons+=("Colloid")
  fi

  if [[ ${#installed_icons[@]} -gt 0 ]]; then
    msg "Successfully installed ${#installed_icons[@]} icon theme(s): ${installed_icons[*]}"
  fi

  if [[ ${#failed_icons[@]} -gt 0 ]]; then
    # joined explicitly for the same reason as the themes above: [*] would
    # otherwise join on newline.
    local joined_failed_icons
    joined_failed_icons="$(IFS=' ' ; echo "${failed_icons[*]}")"
    warn "Failed to install ${#failed_icons[@]} icon theme(s): ${joined_failed_icons}"
    warn "You can manually install these icon themes later if needed."
  fi

  # Cosmetic, and nothing downstream depends on it, so this warns rather than
  # returning 1 into the ERR trap.
  if [[ ${#installed_icons[@]} -eq 0 ]]; then
    warn "No icon themes were installed. The desktop will use the default icons."
  fi

  return 0
}

verify_all_binaries() {
  info "Verifying all required binaries are installed..."
  local missing_binaries=()
  local binaries_to_check=(
    niri waybar fish fastfetch mako alacritty starship
    nvim vicinae gtklock zathura matugen awww librewolf btm
  )

  for binary in "${binaries_to_check[@]}"; do
    if ! verify_binary "${binary}"; then
      missing_binaries+=("${binary}")
    fi
  done

  if [[ ${#missing_binaries[@]} -gt 0 ]]; then
    error "The following required binaries are missing:"
    printf '  - %s\n' "${missing_binaries[@]}"
    fatal "Please install missing packages manually and re-run the script."
  fi

  msg "All required binaries verified."

  verify_polkit_agent
}

# The polkit agent is not on PATH, so the loop above cannot see it, and its
# absence is silent: niri starts it, the spawn fails, and the desktop comes up
# with no way to ask for a password. Nothing that needs root works after that
# and nothing on screen says why. Not fatal, the rest of the desktop is fine
# without it, but too quiet to leave to be discovered.
verify_polkit_agent() {
  if [[ -x "${POLKIT_AGENT_PATH}" ]]; then
    msg "polkit agent: ${POLKIT_AGENT_PATH}"
    return 0
  fi

  warn "No polkit agent at ${POLKIT_AGENT_PATH}, which is where niri starts it."
  warn "Without it nothing can ask for a password: mounting disks, changing"
  warn "network settings or installing packages from a desktop tool will fail."
  info "Install it with: ${CYAN}sudo pacman -S polkit-gnome${NC}"
  info "The polkit daemon itself is a dependency of that package."
}

# ==========================
# SHELL MANAGEMENT
# ==========================

configure_shells() {
  info "Configuring fish shell (default and only shell)..."
  CONFIGURE_FISH=true

  if ! binary_installed fish; then
    info "Installing fish..."
    if sudo pacman -S --needed fish < /dev/tty 2>&1 | log_and_show "${LOG_FILE}"; then
      msg "fish installed successfully."
    else
      warn "Failed to install fish. It may already be installed."
    fi
  else
    info "fish already installed."
  fi

  msg "Fish shell configuration ready."
}

# Resolves the account the installer is acting on. `$USER` is not reliable here:
# it is inherited from the environment and is simply absent or wrong when the
# script runs through sudo, a login manager, or a minimal container.
target_username() {
  id -un 2> /dev/null || printf '%s' "${USER:-}"
}

# Reads the login shell straight from the passwd database.
# `|| true` because a failing getent would otherwise trip pipefail and abort
# the whole install through the ERR trap.
current_login_shell() {
  getent passwd "$(target_username)" 2> /dev/null | cut -d: -f7 || true
}

set_default_shell() {
  info "Setting fish as default shell..."
  local current_shell=""
  current_shell="$(current_login_shell)"

  # `command -v` exits non-zero when fish is absent, and a variable assignment
  # whose command substitution fails is itself a simple command, so under set -e
  # the bare form aborted the installer here and the fish-absent path below
  # could never run. `|| :` keeps the assignment successful either way.
  local fish_bin
  fish_bin="$(command -v fish)" || fish_bin=""

  if [[ -z "${fish_bin}" ]]; then
    warn "fish is not installed. Installing it now..."

    if sudo pacman -S --needed fish < /dev/tty 2>&1 | log_and_show "${LOG_FILE}"; then
      fish_bin="$(command -v fish)" || fish_bin=""
      if [[ -z "${fish_bin}" ]]; then
        error "Failed to locate fish after installation."
        return 0
      fi
      msg "fish installed successfully."
    else
      error "Failed to install fish."
      return 0
    fi
  fi

  if [[ "${current_shell}" == "${fish_bin}" ]]; then
    msg "fish is already your default shell."
    SET_DEFAULT_SHELL_OK=true
    return 0
  fi

  info "Changing default shell to fish..."

  # usermod does not require the shell to be listed in /etc/shells, but chsh
  # does and so does anything else that validates login shells. Add the entry
  # first so a later manual `chsh` or a stricter login stack keeps working.
  if ! grep -qx "${fish_bin}" /etc/shells 2> /dev/null; then
    info "Adding fish to /etc/shells..."

    printf "%s\n" "${fish_bin}" | sudo tee -a /etc/shells > /dev/null 2>&1 || true

    if ! grep -qx "${fish_bin}" /etc/shells 2> /dev/null; then
      error "${fish_bin} could not be added to /etc/shells."
      info "Add it manually: ${CYAN}sudo sh -c 'echo ${fish_bin} >> /etc/shells'${NC}"
      return 0
    fi
  fi

  # Rewrite the passwd entry through usermod under the sudo credentials the
  # installer already holds (see check_sudo), never through chsh.
  #
  # This script is documented to run as `curl -fsSL ... | sh`, so stdin is the
  # script's own source. chsh authenticates via pam_unix, whose conversation
  # reads the password from stdin: it would eat a line of the running script,
  # the "password" could never match, and the desynchronised read leaves bash
  # reading garbage for the rest of the install. usermod neither prompts nor
  # touches stdin, so neither failure mode can occur. It only edits the passwd
  # entry, so the running shell is untouched and fish starts at next login.
  local user_name
  user_name="$(target_username)"

  if [[ -z "${user_name}" ]]; then
    error "Could not determine the current user."
    info "Set it later with: ${CYAN}sudo usermod -s /usr/bin/fish <your-username>${NC}"
    return 0
  fi

  if ! sudo usermod -s "${fish_bin}" "${user_name}"; then
    # shadow's chsh skips the password check entirely when run as root, so
    # this fallback is equally prompt-free. It only matters on a system where
    # usermod is unavailable.
    warn "usermod failed, falling back to chsh as root..."

    if sudo chsh -s "${fish_bin}" "${user_name}"; then
      warn "Used chsh instead of usermod."
    else
      error "Failed to change the default shell."
      info "Set it later with: ${CYAN}sudo usermod -s ${fish_bin} ${user_name}${NC}"
      return 0
    fi
  fi

  # Read the entry back: the change can silently not land, for example when
  # nsswitch hands the account to something other than the local files.
  local new_shell=""
  new_shell="$(current_login_shell)"

  if [[ "${new_shell}" != "${fish_bin}" ]]; then
    error "The shell change reported success but the login shell is still ${new_shell:-unknown}."
    info "Set it later with: ${CYAN}sudo usermod -s ${fish_bin} ${user_name}${NC}"
    return 0
  fi

  SET_DEFAULT_SHELL_OK=true
  msg "Default shell changed to fish successfully."
  info "Your current shell keeps running as-is; fish starts from your next login."
}

# ==========================
# DOTFILES MANAGEMENT
# ==========================

# Prints one line per thing the checkout holds that a fresh clone would not:
# modified and untracked files, and commits that were never pushed. Nothing is
# printed when it is safe to delete, which is also what happens when the answer
# cannot be worked out, except that an unreadable status prints a line of its own
# so the caller asks rather than assumes.
#
# The status is only data, never a message: the caller prints it, so that
# mapfile cannot pick up a warning as if it were a file entry.
dotfiles_local_changes() {
  local status

  if ! status="$(git -C "${DOTDIR}" status --porcelain 2> /dev/null)"; then
    printf '?  could not read the git status of %s\n' "${DOTDIR}"
    return 0
  fi

  if [[ -n "${status}" ]]; then
    printf '%s\n' "${status}"
  fi

  # git status says nothing about commits, so a local commit is invisible to it
  # and would be lost just as silently. Only meaningful once an upstream is
  # recorded, which a clone does and a detached tree does not.
  if git -C "${DOTDIR}" rev-parse --verify --quiet '@{u}' &> /dev/null; then
    local unpushed
    unpushed="$(git -C "${DOTDIR}" log --oneline '@{u}..HEAD' 2> /dev/null || true)"
    if [[ -n "${unpushed}" ]]; then
      printf '   commits not pushed to the remote:\n'
      printf '%s\n' "${unpushed}"
    fi
  fi

  return 0
}

# What a directory that is not a checkout holds. Used for the listing when the
# dotfiles path turns out not to be a repository, where there is no git status
# to ask and the contents are the only thing that can be shown.
dotfiles_directory_listing() {
  ls -A "${DOTDIR}" 2> /dev/null | sed 's/^/   /' || true
}

# Asks before removing the checkout. The answer defaults to keeping it, both on
# a bare Enter and on a closed stdin, so no path through this deletes anything
# the person running the install did not ask for. The second argument is the
# function that produces the listing, so the non-repository case can show the
# directory's own contents.
confirm_replace_dotfiles() {
  local reason="$1"
  local lister="${2:-dotfiles_local_changes}"
  local reply=""

  warn "${reason}"
  warn "These would be lost:"
  local -a changes=()
  local -a shown=()

  mapfile -t changes < <("${lister}")
  if [[ ${#changes[@]} -eq 0 ]]; then
    printf '  (nothing to show)\n'
  else
    shown=("${changes[@]:0:10}")
    printf '  %s\n' "${shown[@]}"
    if [[ ${#changes[@]} -gt ${#shown[@]} ]]; then
      printf '  ... and %d more\n' "$(( ${#changes[@]} - ${#shown[@]} ))"
    fi
  fi
  printf "\n"

  # `|| true` so a closed stdin falls through to the default below, which is to
  # keep, matching every other prompt in this script.
  read -r -p "Replace ${DOTDIR} with a fresh copy? (y/N): " reply < /dev/tty || true
  printf "\n"

  [[ "${reply}" =~ ^[Yy]$ ]]
}

clone_or_update_dotfiles() {
  if [[ -d "${DOTDIR}/.git" ]]; then
    msg "Dotfiles directory exists. Updating..."

    # git refuses to rebase over uncommitted work, and used to be read as a
    # network failure, which answered it by deleting the checkout. So the state
    # is established first and the question is put to the person running the
    # install. Checking here also means the pull is not attempted at all when it
    # cannot succeed, rather than retried three times first.
    local -a changes=()
    mapfile -t changes < <(dotfiles_local_changes)

    if [[ ${#changes[@]} -gt 0 ]]; then
      if confirm_replace_dotfiles "The dotfiles checkout has changes that a fresh copy would not have:"; then
        clone_dotfiles
      else
        warn "Keeping ${DOTDIR}. The dotfiles update is skipped."
        info "Your files are untouched. To update later, deal with the changes first:"
        info "  git -C ${DOTDIR} status"
      fi
    elif ! retry_command 3 git -C "${DOTDIR}" pull --rebase 2>&1 | log_and_show "${LOG_FILE}"; then
      # Reached only when the checkout is clean, so there is nothing here worth
      # asking about: no modified files, no untracked files and no unpushed
      # commits. The re-clone still stages its copy first, so even this branch
      # cannot leave the machine with no dotfiles if the network stays down.
      warn "Failed to update dotfiles after retries. Re-cloning from scratch..."
      clone_dotfiles
    else
      msg "Dotfiles updated successfully."
    fi
  elif [[ -d "${DOTDIR}" ]]; then
    # Not a checkout, so it is not ours and there is no way to tell what is in
    # it. Deleting it unasked is the one case with no recovery at all.
    if confirm_replace_dotfiles "The dotfiles directory exists but is not a git repository:" dotfiles_directory_listing; then
      clone_dotfiles
    else
      warn "Keeping ${DOTDIR}, so no configurations will be linked from the repository."
      info "Move or remove it yourself and re-run to install the dotfiles."
    fi
  else
    clone_dotfiles
  fi

  # Only a checkout can have submodules, and the directory is not necessarily
  # one: it is left alone when it turns out not to be a repository.
  if [[ -d "${DOTDIR}/.git" ]]; then
    info "Updating git submodules..."
    if retry_command 3 git -C "${DOTDIR}" submodule update --init --recursive 2>&1 | log_and_show "${LOG_FILE}"; then
      msg "Submodules updated."
    else
      warn "Failed to update submodules after retries. Continuing anyway..."
    fi
  fi
}

clone_dotfiles() {
  local target="${DOTDIR}"

  # Replaces whatever is at ${DOTDIR}, in the only order that cannot lose
  # anything. When a directory is already there, the fresh copy is cloned
  # somewhere else first and swapped in only once it has been verified, so a
  # failed clone leaves the old one exactly as it was rather than leaving
  # nothing at all. With nothing to replace there is nothing to protect, the
  # clone goes straight to ${DOTDIR}, and no staging is involved.
  #
  # The staging directory is a sibling of ${DOTDIR} and so on the same
  # filesystem, which makes the swap a rename rather than a copy of the lot.
  if [[ -e "${DOTDIR}" ]]; then
    msg "Cloning a fresh copy first, so the current one is only replaced once it works..."
    DOTFILES_STAGING_DIR="$(mktemp -d "${HOME}/.dotfiles-staging.XXXXXX")"
    if [[ ! -d "${DOTFILES_STAGING_DIR}" ]]; then
      DOTFILES_STAGING_DIR=""
      fatal "Failed to create a staging directory for the fresh copy."
    fi
    target="${DOTFILES_STAGING_DIR}/repo"
  fi

  info "Cloning dotfiles repository (this may take a moment)..."
  if ! retry_command 3 git clone --depth=1 "${REPO_URL}" "${target}" 2>&1 | log_and_show "${LOG_FILE}"; then
    # Deliberately no rm -rf of ${DOTDIR} here. That is the whole point of the
    # staging: whatever it was is still there, and cleanup_temp_files removes
    # the unusable staged copy on the way out.
    fatal "Failed to clone dotfiles repository after multiple attempts. Check your internet connection."
  fi

  if [[ ! -d "${target}/.git" ]]; then
    fatal "Repository cloned but .git directory not found. Clone may be corrupted."
  fi

  if [[ "${target}" != "${DOTDIR}" ]]; then
    msg "Fresh copy verified. Replacing the previous one..."
    rm -rf "${DOTDIR}"
    mv "${target}" "${DOTDIR}"
    # The staging directory itself is now empty, and clearing the variable first
    # would leave it behind for the exit cleanup to miss.
    rmdir "${DOTFILES_STAGING_DIR}" 2> /dev/null || true
    DOTFILES_STAGING_DIR=""
  fi

  msg "Dotfiles cloned successfully."
}

validate_repo_structure() {
  info "Validating repository structure..."
  local missing_folders=()
  local missing_files=()

  for folder in "${CONFIG_FOLDERS[@]}"; do
    if [[ ! -d "${DOTDIR}/${folder}" ]]; then
      missing_folders+=("${folder}")
    fi
  done

  for file in "${CONFIG_FILES[@]}"; do
    if [[ ! -f "${DOTDIR}/${file}" ]]; then
      missing_files+=("${file}")
    fi
  done

  if [[ ${#missing_folders[@]} -gt 0 ]]; then
    warn "The following expected folders are missing from the repository:"
    printf '  - %s\n' "${missing_folders[@]}"
    warn "Installation will continue, but these configurations will be skipped."
  fi

  if [[ ${#missing_files[@]} -gt 0 ]]; then
    warn "The following expected configuration files are missing from the repository:"
    printf '  - %s\n' "${missing_files[@]}"
    warn "Installation will continue, but these configurations will be skipped."
  fi

  if [[ ${#missing_folders[@]} -eq 0 ]] && [[ ${#missing_files[@]} -eq 0 ]]; then
    msg "Repository structure validated."
  fi
}

create_symlinks() {
  msg "Creating symbolic links to ~/.config..."
  local linked=0
  local skipped=0

  for folder in "${CONFIG_FOLDERS[@]}"; do
    if [[ -d "${DOTDIR}/${folder}" ]]; then
      local target="${CONFIG_DIR}/${folder}"

      # Safety check for path validation
      if [[ -z "${CONFIG_DIR}" ]] || [[ -z "${target}" ]]; then
        fatal "Path validation failed: CONFIG_DIR or target is empty"
      fi

      # A config whose backup failed is still the user's only copy, so it is
      # left alone and reported rather than removed. Replacing it with a
      # symlink into the repository would destroy it.
      if printf '%s\n' "${BACKUP_FAILED[@]:-}" | grep -qxF -- "${folder}"; then
        warn "Keeping existing ${folder}: its backup failed earlier, so this is the only copy."
        warn "Not linking ${folder}. Move it aside by hand if you want the dotfiles version."
        ((++skipped)) || true
        continue
      fi

      if [[ -e "${target}" ]] || [[ -L "${target}" ]]; then
        warn "Target still exists: ${folder} (removing)"
        rm -rf "${target}"
      fi

      if ln -s "${DOTDIR}/${folder}" "${target}" 2>> "${LOG_FILE}"; then
        info "Linked: ${folder}"
        ((++linked)) || true
      else
        error "Failed to link: ${folder} (check log for details)"
      fi
    else
      info "Skipping: ${folder} (not found in repository)"
      ((++skipped)) || true
    fi
  done

  # The same for the single file configurations, which land directly in the
  # config directory under their own name.
  local file target
  for file in "${CONFIG_FILES[@]}"; do
    if [[ -f "${DOTDIR}/${file}" ]]; then
      target="${CONFIG_DIR}/${file}"

      if printf '%s\n' "${BACKUP_FAILED[@]:-}" | grep -qxF -- "${file}"; then
        warn "Keeping existing ${file}: its backup failed earlier, so this is the only copy."
        warn "Not linking ${file}. Move it aside by hand if you want the dotfiles version."
        ((++skipped)) || true
        continue
      fi

      if [[ -e "${target}" ]] || [[ -L "${target}" ]]; then
        warn "Target still exists: ${file} (removing)"
        rm -f "${target}"
      fi

      if ln -s "${DOTDIR}/${file}" "${target}" 2>> "${LOG_FILE}"; then
        info "Linked: ${file}"
        ((++linked)) || true
      else
        error "Failed to link: ${file} (check log for details)"
      fi
    else
      info "Skipping: ${file} (not found in repository)"
      ((++skipped)) || true
    fi
  done

  msg "Created ${linked} symlink(s), skipped ${skipped}."
}

install_wallpapers() {
  if [[ -d "${DOTDIR}/wallpapers" ]]; then
    info "Installing wallpapers..."
    local wallpaper_dir="${HOME}/Pictures/Wallpapers"
    mkdir -p "${wallpaper_dir}"

    shopt -s nullglob
    local wallpapers=("${DOTDIR}/wallpapers/"*)
    shopt -u nullglob

    if [[ ${#wallpapers[@]} -gt 0 ]]; then
      if cp -r "${DOTDIR}/wallpapers/"* "${wallpaper_dir}/" 2> /dev/null; then
        msg "Wallpapers installed to: ${wallpaper_dir}"
      else
        warn "Failed to copy wallpapers."
      fi
    else
      info "No wallpapers found in repository."
    fi
  else
    info "No wallpapers directory found in repository."
  fi
}

# ==========================
# SYSTEMD SERVICE MANAGEMENT
# ==========================

create_systemd_services() {
  info "Niri handles autostart via its config file."
  info "The following services are started by niri.conf:"
  printf "  - polkit-gnome-authentication-agent\n"
  printf "  - awww-daemon\n"
  printf "  - waybar\n"
  printf "  - vicinae server\n"
  printf "\n"
  info "Creating gtklock service for manual/idle trigger only..."

  local service_dir="${HOME}/.config/systemd/user"
  mkdir -p "${service_dir}"
  create_gtklock_service "${service_dir}"

  systemctl --user daemon-reload 2>&1 | log_and_show "${LOG_FILE}" || warn "Failed to reload systemd daemon."
   
  printf "\n"
  info "gtklock service has been created but NOT enabled by default."
  info "To manually lock your screen: systemctl --user start gtklock"
  info "To enable autostart on login: systemctl --user enable gtklock"
  printf "\n"
   
  msg "Systemd services configured."
}

create_gtklock_service() {
  local service_dir="$1"

  if ! binary_installed gtklock; then
    warn "gtklock binary not found, skipping service creation"
    return
  fi

  local gtklock_bin
  gtklock_bin="$(command -v gtklock)"

  cat > "${service_dir}/gtklock.service" << EOF
[Unit]
Description=GTKLock Screen Locker
Documentation=man:gtklock(1)

[Service]
Type=simple
ExecStart=${gtklock_bin}
Restart=no
EOF

  info "Created: gtklock.service (manual trigger only)"
  info "Note: gtklock will NOT autostart. Trigger it via 'systemctl --user start gtklock'"
}

# ==========================
# MAIN INSTALLATION FLOW
# ==========================

print_header() {
  printf "\n"
  printf "${GREEN}${BOLD}"
  cat << "EOF"
════════════════════════════════════════════════════════════
  JUPITER - Installation Script v1.3
  Automated setup for your Niri window manager configuration
════════════════════════════════════════════════════════════
EOF
  printf "${NC}"
  printf "\n"
  printf "Repository: ${BLUE}%s${NC}\n" "${REPO_URL}"
  printf "Log file: ${BLUE}%s${NC}\n" "${LOG_FILE}"
  printf "\n"
}

print_summary() {
  separator
  printf "${GREEN}${BOLD}"
  cat << "EOF"
════════════════════════════════════════════════════════════
  INSTALLATION COMPLETED SUCCESSFULLY!
  Your jupiter configuration has been installed
════════════════════════════════════════════════════════════
EOF
  printf "${NC}\n"

  if [[ ${#INSTALL_SUMMARY[@]} -gt 0 ]]; then
    printf "\n"
    printf "${CYAN}${BOLD}Installation Summary:${NC}\n"
    printf "${CYAN}────────────────────${NC}\n"
    for item in "${INSTALL_SUMMARY[@]}"; do
      printf "  ${GREEN}✓${NC} %s\n" "${item}"
    done
  fi

  separator
  printf "${MAGENTA}${BOLD}Next Steps:${NC}\n"
  printf "  1. Log out of your current session\n"
  printf "  2. Select 'Niri' from your display manager\n"
  printf "  3. Log in to start using your new setup\n"
  printf "\n"
  printf "${BLUE}${BOLD}Important Notes:${NC}\n"
  printf "  • Services are auto-started by niri.conf, not systemd\n"
  printf "  • awww-daemon, waybar, vicinae, and polkit start automatically\n"
  printf "  • gtklock can be triggered manually or via idle timeout\n"
  printf "\n"

  if [[ -d "${JUPITER_TEMP}" ]]; then
    info "Cleaning up temporary installer files..."
    rm -rf "${JUPITER_TEMP}"
    msg "Removed ${JUPITER_TEMP} (backup and log)."
  fi
  printf "\n"
  separator
}

main() {
  mkdir -p "${JUPITER_TEMP}"

  print_header

  step "Pre-flight System Checks"
  check_not_root
  check_arch_based
  check_disk_space
  check_sudo
  check_internet
  add_summary "System validated and prerequisites checked"

  step "Checking Optional Dependencies"
  check_optional_dependencies
  add_summary "Optional dependencies checked (audio/Bluetooth backends)"

  step "System Update"
  update_system
  add_summary "System packages updated"

  step "Configuring NVIDIA Graphics"
  configure_nvidia
  if [[ "${INSTALL_NVIDIA}" == "true" ]]; then
    add_summary "NVIDIA driver installed (${NVIDIA_DRIVER})"
  else
    add_summary "NVIDIA driver skipped"
  fi

  # MOVED UP: Must install git/base-devel BEFORE attempting to build yay
  step "Installing Base Development Tools"
  install_base_tools
  add_summary "Base development tools installed (git, base-devel, curl)"

  step "AUR Helper Selection and Installation"
  choose_aur_helper
  add_summary "AUR helper configured: ${AUR_HELPER}"

  step "Installing Official Repository Packages"
  install_pacman_packages
  add_summary "Official packages installed (niri, waybar, fish, etc.)"

  # CRITICAL: This checks for the broken libalpm link before using yay
  step "Checking broken yay"
  check_yay_linkage
  add_summary "Checked for yay linkage issues"

  step "Installing AUR Packages"
  install_aur_packages
  add_summary "AUR packages installed (vicinae)"

  step "Installing GTK Themes"
  install_gtk_themes
  add_summary "GTK themes installed (Colloid, Rose-Pine, Osaka)"

  step "Installing Icon Themes"
  install_icon_themes
  add_summary "Icon themes installed (Colloid icons)"

  step "Verifying Installed Binaries"
  verify_all_binaries
  add_summary "All required binaries verified"

  step "Configuring Fish Shell"
  configure_shells
  add_summary "Fish shell configured"

  step "Setting Fish as Default Shell"
  set_default_shell
  if [[ "${SET_DEFAULT_SHELL_OK}" == "true" ]]; then
    add_summary "Fish set as default shell"
  else
    add_summary "Default shell unchanged, still $(current_login_shell || echo unknown)"
  fi

  step "Creating Configuration Backup"
  create_backup
  add_summary "Existing configurations backed up to ${BACKUP_DIR}"

  step "Cloning Dotfiles Repository"
  clone_or_update_dotfiles
  add_summary "Dotfiles repository cloned from ${REPO_URL}"

  step "Validating Repository Structure"
  validate_repo_structure
  add_summary "Repository structure validated"

  step "Creating Symbolic Links"
  create_symlinks
  add_summary "Configuration symlinks created in ~/.config"

  step "Installing Wallpapers"
  install_wallpapers
  add_summary "Wallpapers installed to ~/Pictures/Wallpapers"

  step "Configuring Login Greeter"
  configure_greeter
  if [[ "${INSTALL_GREETER}" == "true" ]]; then
    add_summary "Login greeter configured (greetd + tuigreet)"
  else
    add_summary "Login greeter skipped"
  fi

  step "Configuring System Services"
  create_systemd_services
  add_summary "Systemd services configured"

  print_summary
}

# ==========================
# ARGUMENT PARSING
# ==========================

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      -v | --version)
        version
        exit 0
        ;;
      *)
        error "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done
}

# ==========================
# ERROR HANDLING & EXECUTION
# ==========================

trap 'cleanup_on_error ${LINENO}' ERR
# INT and TERM get their own handlers that exit. cleanup_on_exit is a plain
# cleanup function, and bash resumes at the next command after a trap handler
# returns, so sharing EXIT's handler with them meant a single Ctrl-C during
# `pacman -Syu` killed pacman, ran the cleanup, and then carried on with the
# rest of the install minus the sudo keepalive.
trap 'cleanup_on_exit' EXIT
trap 'cleanup_on_exit; exit 130' INT
trap 'cleanup_on_exit; exit 143' TERM

parse_arguments "$@"
main
