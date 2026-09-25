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

# Process ID for sudo keep-alive
SUDO_PID=""

# Expected configuration folders in the repo
readonly CONFIG_FOLDERS=(
  niri waybar fish fastfetch mako alacritty starship
  nvim vicinae gtklock zathura matugen scripts
)

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

# AUR packages to install
readonly AUR_PACKAGES=(
  vicinae-bin
)

# Official repository packages
readonly PACMAN_PACKAGES=(
  niri waybar fish fastfetch mako alacritty starship neovim eza
  zathura zathura-pdf-mupdf ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols
  qt5-wayland qt6-wayland polkit-gnome unzip jq unrar 7zip man-db bat
  gtklock curl libnotify pavucontrol thunar awww matugen librewolf bottom
)

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
  printf "[%s] %s\n" "${timestamp}" "$*" >> "${LOG_FILE}" 2> /dev/null || true
}

msg() {
  printf "${GREEN}==>${NC} %s\n" "$1"
  log "INFO: $1"
}

info() {
  printf "${BLUE}==>${NC} %s\n" "$1"
  log "INFO: $1"
}

warn() {
  printf "${YELLOW}[WARNING]${NC} %s\n" "$1"
  log "WARNING: $1"
}

error() {
  printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
  log "ERROR: $1"
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

    local reply
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
    while true; do
      sudo -v
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

    local reply
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
    lspci 2> /dev/null |
      grep -iE '(VGA compatible controller|3D controller|Display controller)' |
      grep -qi 'nvidia'
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
  printf "  • Remove later with: ${CYAN}sudo pacman -Rns${NC} <driver> ${package_list}\n"
  printf "\n"

  local reply
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
  if sudo pacman -S --needed "${install_list[@]}" < /dev/tty 2>&1 | tee -a "${LOG_FILE}"; then
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

# ==========================
# BACKUP FUNCTIONS
# ==========================

create_backup() {
  msg "Creating backup of existing configurations..."
  mkdir -p "${BACKUP_DIR}"
  mkdir -p "${CONFIG_DIR}"

  local backed_up=0
  local symlinks_found=0

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

    local reply
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
  if sudo pacman -Syu < /dev/tty 2>&1 | tee -a "${LOG_FILE}"; then
    msg "System updated successfully."
  else
    fatal "Failed to update system packages."
  fi
}

install_base_tools() {
  info "Installing base development tools..."
  if sudo pacman -S --needed git base-devel curl < /dev/tty 2>&1 | tee -a "${LOG_FILE}"; then
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
      sudo pacman -Rns yay yay-bin < /dev/tty 2>&1 | tee -a "${LOG_FILE}" || true
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
  if ! retry_command 3 git clone --depth=1 https://aur.archlinux.org/yay-bin.git "${TEMP_BUILD_DIR}" >> "${LOG_FILE}" 2>&1; then
    fatal "Failed to clone yay-bin repository after multiple attempts."
  fi

  info "Building yay-bin package (this may take a few minutes)..."
  if ! (cd "${TEMP_BUILD_DIR}" && makepkg -si < /dev/tty 2>&1 | tee -a "${LOG_FILE}"); then
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
      sudo pacman -Rns yay yay-bin < /dev/tty 2>&1 | tee -a "${LOG_FILE}" || true
      install_yay
    fi
  fi
}

install_pacman_packages() {
  info "Installing official repository packages..."
  info "This may take several minutes..."

  if sudo pacman -S --needed "${PACMAN_PACKAGES[@]}" < /dev/tty 2>&1 | tee -a "${LOG_FILE}"; then
    msg "Official packages installed successfully."
  else
    fatal "Failed to install official repository packages."
  fi
}

install_aur_packages() {
  info "Installing AUR packages using ${AUR_HELPER}..."
  info "This may take several minutes..."

  if "${AUR_HELPER}" -S --needed "${AUR_PACKAGES[@]}" < /dev/tty 2>&1 | tee -a "${LOG_FILE}"; then
    msg "AUR packages installed successfully."
  else
    fatal "Failed to install AUR packages."
  fi
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
      if sudo systemctl disable --now "${service}.service" > /dev/null 2>&1; then
        disabled+=("${service}")
        msg "Disabled conflicting display manager: ${service}"
      else
        warn "Could not disable ${service}. Turn it off manually: sudo systemctl disable --now ${service}"
      fi
    fi
  done

  if [[ ${#disabled[@]} -eq 0 ]]; then
    info "No conflicting display manager is enabled."
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
  printf "  • Any other display manager can be restored with: ${CYAN}sudo pacman -S gdm${NC}\n"
  printf "  • Turn the greeter off with: ${CYAN}sudo systemctl disable greetd${NC}\n"
  printf "\n"
  printf "${BLUE}${BOLD}Note:${NC}\n"
  printf "  • It is enabled but not started now, so it takes effect on next boot\n"
  printf "  • The greeter starts niri after you log in\n"
  printf "\n"

  local reply
  read -r -p "Install and enable the greetd + tuigreet greeter? (Y/n): " reply < /dev/tty
  printf "\n"

  if [[ "${reply}" =~ ^[Nn]$ ]]; then
    warn "Skipping greeter setup."
    info "Set it up later with: ${CYAN}sudo pacman -S ${package_list}${NC}"
    return 0
  fi

  if ! verify_binary tuigreet || ! pacman -Qi greetd &> /dev/null; then
    info "Installing greeter packages..."
    if sudo pacman -S --needed "${GREETER_PACKAGES[@]}" < /dev/tty 2>&1 | tee -a "${LOG_FILE}"; then
      msg "Greeter packages installed successfully."
    else
      fatal "Failed to install greeter packages."
    fi
  else
    msg "greetd and tuigreet are already installed."
  fi

  if ! verify_binary tuigreet; then
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

  if ! retry_command 3 git clone --depth=1 https://github.com/vinceliuice/Colloid-gtk-theme "${theme_dir}" >> "${LOG_FILE}" 2>&1; then
    rm -rf "${theme_dir}"
    warn "Failed to clone Colloid theme repository after multiple attempts."
    return 1
  fi

  info "Installing Colloid theme variants..."
  if ! (cd "${theme_dir}" && ./install.sh --libadwaita --tweaks all rimless >> "${LOG_FILE}" 2>&1); then
    rm -rf "${theme_dir}"
    warn "Failed to install Colloid theme (default variant)."
    return 1
  fi

  info "Installing Colloid theme (grey-black variant)..."
  if ! (cd "${theme_dir}" && ./install.sh --libadwaita --theme grey --tweaks black rimless >> "${LOG_FILE}" 2>&1); then
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

  if ! retry_command 3 git clone --depth=1 https://github.com/Fausto-Korpsvart/Rose-Pine-GTK-Theme "${theme_dir}" >> "${LOG_FILE}" 2>&1; then
    rm -rf "${theme_dir}"
    warn "Failed to clone Rose Pine theme repository after multiple attempts."
    return 1
  fi

  info "Installing Rose Pine theme with moon variant..."
  if ! (cd "${theme_dir}/themes" && ./install.sh --libadwaita --tweaks moon macos >> "${LOG_FILE}" 2>&1); then
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

  if ! retry_command 3 git clone --depth=1 https://github.com/Fausto-Korpsvart/Osaka-GTK-Theme "${theme_dir}" >> "${LOG_FILE}" 2>&1; then
    rm -rf "${theme_dir}"
    warn "Failed to clone Osaka theme repository after multiple attempts."
    return 1
  fi

  info "Installing Osaka theme with solarized variant..."
  if ! (cd "${theme_dir}/themes" && ./install.sh --libadwaita --tweaks solarized macos >> "${LOG_FILE}" 2>&1); then
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
    warn "Failed to install ${#failed_themes[@]} GTK theme(s): ${failed_themes[*]}"
    warn "You can manually install these themes later if needed."
  fi

  if [[ ${#installed_themes[@]} -eq 0 ]]; then
    error "All GTK themes failed to install."
    return 1
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

  if ! retry_command 3 git clone --depth=1 https://github.com/vinceliuice/Colloid-icon-theme "${icons_dir}" >> "${LOG_FILE}" 2>&1; then
    rm -rf "${icons_dir}"
    warn "Failed to clone Colloid icon theme repository after multiple attempts."
    return 1
  fi

  info "Installing Colloid icon theme with all schemes (bold)..."
  # -d ensures we install to ~/.icons and do NOT trigger a hidden sudo prompt
  if ! (cd "${icons_dir}" && ./install.sh -d "${HOME}/.icons" --scheme all --bold >> "${LOG_FILE}" 2>&1); then
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
    warn "Failed to install ${#failed_icons[@]} icon theme(s): ${failed_icons[*]}"
    warn "You can manually install these icon themes later if needed."
  fi

  if [[ ${#installed_icons[@]} -eq 0 ]]; then
    error "All icon themes failed to install."
    return 1
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
}

# ==========================
# SHELL MANAGEMENT
# ==========================

configure_shells() {
  info "Configuring fish shell (default and only shell)..."
  CONFIGURE_FISH=true

  if ! verify_binary fish; then
    info "Installing fish..."
    if sudo pacman -S --needed fish < /dev/tty 2>&1 | tee -a "${LOG_FILE}"; then
      msg "fish installed successfully."
    else
      warn "Failed to install fish. It may already be installed."
    fi
  else
    info "fish already installed."
  fi

  msg "Fish shell configuration ready."
}

set_default_shell() {
  info "Setting fish as default shell..."
  local current_shell
  current_shell="$(getent passwd "${USER}" | cut -d: -f7)"

  local fish_bin
  fish_bin="$(command -v fish)"

  if [[ -z "${fish_bin}" ]]; then
    warn "fish is not installed. Installing it now..."

    if sudo pacman -S --needed fish < /dev/tty 2>&1 | tee -a "${LOG_FILE}"; then
      fish_bin="$(command -v fish)"
      if [[ -z "${fish_bin}" ]]; then
        error "Failed to locate fish after installation."
        return 1
      fi
      msg "fish installed successfully."
    else
      error "Failed to install fish."
      return 1
    fi
  fi

  if [[ "${current_shell}" == "${fish_bin}" ]]; then
    msg "fish is already your default shell."
    return 0
  fi

  info "Changing default shell to fish..."

  if ! grep -q "^${fish_bin}\$" /etc/shells 2> /dev/null; then
    info "Adding fish to /etc/shells..."
    printf "%s\n" "${fish_bin}" | sudo tee -a /etc/shells >> "${LOG_FILE}" 2>&1
  fi

  if chsh -s "${fish_bin}"; then
    msg "Default shell changed to fish successfully."
    warn "You'll need to log out and back in for this to take effect."
  else
    error "Failed to change default shell."
    info "You can manually change it later with: chsh -s ${fish_bin}"
  fi
}

# ==========================
# DOTFILES MANAGEMENT
# ==========================

clone_or_update_dotfiles() {
  if [[ -d "${DOTDIR}/.git" ]]; then
    msg "Dotfiles directory exists. Updating..."
    if ! retry_command 3 git -C "${DOTDIR}" pull --rebase >> "${LOG_FILE}" 2>&1; then
      warn "Failed to update dotfiles after retries. Removing and re-cloning..."
      rm -rf "${DOTDIR}"
      clone_dotfiles
    else
      msg "Dotfiles updated successfully."
    fi
  elif [[ -d "${DOTDIR}" ]]; then
    warn "Dotfiles directory exists but is not a git repository. Removing and re-cloning..."
    rm -rf "${DOTDIR}"
    clone_dotfiles
  else
    clone_dotfiles
  fi

  info "Updating git submodules..."
  if retry_command 3 git -C "${DOTDIR}" submodule update --init --recursive >> "${LOG_FILE}" 2>&1; then
    msg "Submodules updated."
  else
    warn "Failed to update submodules after retries. Continuing anyway..."
  fi
}

clone_dotfiles() {
  info "Cloning dotfiles repository (this may take a moment)..."
  if ! retry_command 3 git clone --depth=1 "${REPO_URL}" "${DOTDIR}" >> "${LOG_FILE}" 2>&1; then
    fatal "Failed to clone dotfiles repository after multiple attempts. Check your internet connection."
  fi

  if [[ ! -d "${DOTDIR}/.git" ]]; then
    fatal "Repository cloned but .git directory not found. Clone may be corrupted."
  fi

  msg "Dotfiles cloned successfully."
}

validate_repo_structure() {
  info "Validating repository structure..."
  local missing_folders=()

  for folder in "${CONFIG_FOLDERS[@]}"; do
    if [[ ! -d "${DOTDIR}/${folder}" ]]; then
      missing_folders+=("${folder}")
    fi
  done

  if [[ ${#missing_folders[@]} -gt 0 ]]; then
    warn "The following expected folders are missing from the repository:"
    printf '  - %s\n' "${missing_folders[@]}"
    warn "Installation will continue, but these configurations will be skipped."
  else
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

  systemctl --user daemon-reload >> "${LOG_FILE}" 2>&1 || warn "Failed to reload systemd daemon."
   
  printf "\n"
  info "gtklock service has been created but NOT enabled by default."
  info "To manually lock your screen: systemctl --user start gtklock"
  info "To enable autostart on login: systemctl --user enable gtklock"
  printf "\n"
   
  msg "Systemd services configured."
}

create_gtklock_service() {
  local service_dir="$1"

  if ! verify_binary gtklock; then
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
  add_summary "Fish set as default shell"

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
trap 'cleanup_on_exit' EXIT INT TERM

parse_arguments "$@"
main
