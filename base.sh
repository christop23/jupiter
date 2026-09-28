#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# ==========================
# CONFIGURATION
# ==========================

readonly REPO_URL="https://github.com/christop23/jupiter.git"
readonly CONFIG_DIR="${HOME}/.config"
readonly JUPITER_TEMP="${HOME}/jupiter_temp"
readonly LOG_FILE="${JUPITER_TEMP}/jupiter-base-install-$(date +%Y%m%d_%H%M%S).log"

# Process ID for sudo keep-alive
SUDO_PID=""

# Progress tracking
CURRENT_STEP=0
readonly TOTAL_STEPS=8

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
  printf "[%s] %s\n" "${timestamp}" "$*" 2> /dev/null >> "${LOG_FILE}" || true
}

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

# Every transaction below ends in `| log_and_show`, and that pipe is what used
# to hide pacman's provider list. The "1)" markers and the "Enter a number"
# prompt go to stderr, which is unbuffered, but the provider names are printf'd
# to stdout with no flush, and stdout is block-buffered once it is a pipe: the
# prompt arrived while the options it was asking about were still in the
# buffer, and the names only appeared in one burst when pacman exited.
# `stdbuf -oL` in front of pacman fixes that, and it has to wrap the process
# doing the writing, not the tee at the other end. Line buffering, not _IONBF,
# so a line stays whole when a package's install script shares the descriptor.
# `sudo stdbuf -oL pacman`, never `stdbuf -oL sudo pacman`: sudo resets the
# environment and drops LD_PRELOAD, so the preload would never reach pacman.
# stdbuf is in coreutils, which pacman depends on, so it is always installed.
# The log file is identical either way, only the live display changes.
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

# ==========================
# CLEANUP FUNCTIONS
# ==========================

cleanup_sudo_keepalive() {
  if [[ -n "${SUDO_PID}" ]] && kill -0 "${SUDO_PID}" 2> /dev/null; then
    kill "${SUDO_PID}" 2> /dev/null || true
    wait "${SUDO_PID}" 2> /dev/null || true
  fi
}

cleanup_on_exit() {
  local exit_code=$?
  cleanup_sudo_keepalive
  if [[ ${exit_code} -ne 0 ]]; then
    error "Script exited with error code: ${exit_code}"
  fi
}

cleanup_on_error() {
  local line_no=$1
  error "Error occurred on line ${line_no}"
  cleanup_on_exit
}

# ==========================
# UTILITY FUNCTIONS
# ==========================

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
}

check_arch_based() {
  info "Verifying Arch-based system..."
  if ! command -v pacman &> /dev/null; then
    fatal "This script requires pacman package manager (Arch-based distribution)."
  fi
  local distro_name="Unknown"
  if [[ -f /etc/os-release ]]; then
    distro_name="$(grep -E '^NAME=' /etc/os-release | cut -d'"' -f2)"
  fi
  msg "Arch-based system detected: ${distro_name}"
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
    trap - ERR
    while true; do
      sudo -n -v || exit 0
      sleep 50
    done
  ) &
  SUDO_PID=$!
  msg "Sudo privileges verified."
}

# ==========================
# PACKAGE MANAGEMENT
# ==========================

update_system() {
  info "Updating system packages..."
  if sudo stdbuf -oL pacman -Syu < /dev/tty 2>&1 | log_and_show "${LOG_FILE}"; then
    msg "System updated successfully."
  else
    fatal "Failed to update system packages."
  fi
}

install_base_tools() {
  info "Installing base development tools..."
  if sudo stdbuf -oL pacman -S --needed git base-devel curl < /dev/tty 2>&1 | log_and_show "${LOG_FILE}"; then
    msg "Base tools installed."
  else
    fatal "Failed to install base development tools."
  fi
}

install_niri_stack() {
  info "Installing niri, alacritty, greetd, tuigreet, xdg-desktop-portal..."
  # All packages explicitly named to avoid provider prompts.
  # greetd-tuigreet is named explicitly to settle the greetd-greeter virtual.
  # xdg-desktop-portal-gnome and xdg-desktop-portal-gtk provide portal backends
  # for file chooser, screenshot, and other desktop integration features.
  if sudo stdbuf -oL pacman -S --needed niri alacritty greetd greetd-tuigreet xdg-desktop-portal-gnome xdg-desktop-portal-gtk pacman-contrib < /dev/tty 2>&1 | log_and_show "${LOG_FILE}"; then
    msg "Niri stack installed successfully."
  else
    fatal "Failed to install niri stack."
  fi
}

install_nvidia() {
  local -a packages=(
    libva-nvidia-driver
  )

  if [[ "$(uname -r)" == *-zen* ]]; then
    packages=("dkms" "linux-zen-headers" "${packages[@]}" "nvidia-open-dkms")
  else
    packages+=("nvidia-open")
  fi

  read -r -p "Install xwayland-satellite? (Y/n): " reply < /dev/tty || true
  if [[ -z "${reply}" || "${reply}" =~ ^[Yy]$ ]]; then
    packages+=("xwayland-satellite")
  fi

  info "Installing NVIDIA packages: ${packages[*]}"
  if sudo stdbuf -oL pacman -S --needed "${packages[@]}" < /dev/tty 2>&1 | log_and_show "${LOG_FILE}"; then
    msg "NVIDIA packages installed successfully."
  else
    fatal "Failed to install NVIDIA packages."
  fi
}

# ==========================
# GREETER CONFIGURATION
# ==========================

configure_greeter() {
  info "Configuring greetd + tuigreet..."

  # Disable conflicting display managers
  local service
  for service in lightdm gdm sddm ly xdm lxdm; do
    if systemctl list-unit-files "${service}.service" &> /dev/null; then
      if systemctl is-enabled --quiet "${service}.service" &> /dev/null; then
        sudo systemctl disable "${service}.service" > /dev/null 2>&1 || true
        msg "Disabled conflicting display manager: ${service}"
      fi
    fi
  done

  # Write greetd config
  local config_file="/etc/greetd/config.toml"
  if [[ -f "${config_file}" ]]; then
    sudo cp -f "${config_file}" "${config_file}.jupiter-backup" 2> /dev/null || true
  fi

  # --background matrix paints the digital rain behind the login form. tuigreet
  # draws the form on top and clears the cells it covers, so the prompt stays
  # readable. Animations are off by default, and F4 opens a menu to switch to
  # doom or back to none, so the animation is not baked in. Stream length, fall
  # speed and the three green bands live in [background.matrix] in
  # /etc/tuigreet/config.toml, which tuigreet hot-reloads while it runs.
  sudo tee "${config_file}" > /dev/null 2>&1 << 'GREETER_CONFIG'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --asterisks --background matrix --cmd niri-session"
user = "greeter"
GREETER_CONFIG

  msg "greetd configuration written."

  # Enable greetd
  if sudo systemctl enable greetd.service > /dev/null 2>&1; then
    msg "greetd enabled. It will start on your next boot."
  else
    fatal "Failed to enable greetd.service."
  fi
}

# ==========================
# PACMAN CONFIGURATION
# ==========================

configure_pacman_conf() {
  info "Enabling Color, VerbosePkgLists, and ParallelDownloads in /etc/pacman.conf..."
  if [ -f /etc/pacman.conf ]; then
    # VerbosePkgLists goes first because it is the anchor the pair below hangs
    # off. It has to be uncommented before the anchor test can see it, so the
    # order of these two is not free.
    sudo sed -i "/^#VerbosePkgLists/c\VerbosePkgLists" /etc/pacman.conf
    sudo sed -i "/^#ParallelDownloads/c\ParallelDownloads = 5" /etc/pacman.conf

    # Color and ILoveCandy are a pair: Color turns on pacman's coloured output
    # and ILoveCandy chooses the progress bar it draws. Setting only the first
    # gives coloured text with a plain bar, so both are written together.
    #
    # Keyed off the state of the file rather than off a commented line. The
    # stock file has "#Color", but a machine that already has Color enabled --
    # because the user set it, or because an earlier run of this script did --
    # has no "#Color" line to match, and a sed whose pattern does not match
    # changes nothing and reports success. That is how ILoveCandy went missing
    # on a machine that already had colour. So every variant is deleted first
    # and the pair is then written unconditionally, which makes the step
    # idempotent and repairs a file left half-configured.
    sudo sed -i -e '/^[[:space:]]*#\?Color[[:space:]]*$/d' \
      -e '/^[[:space:]]*#\?ILoveCandy[[:space:]]*$/d' /etc/pacman.conf

    # The pair goes directly under VerbosePkgLists, which is where the stock
    # file keeps its block of display options. The anchor is tested rather than
    # assumed: a file that has no VerbosePkgLists line at all would make the
    # append a silent no-op, which is the same failure as above, so it falls
    # back to the top of [options] and says so.
    if grep -qx 'VerbosePkgLists' /etc/pacman.conf; then
      sudo sed -i '/^VerbosePkgLists$/a Color\nILoveCandy' /etc/pacman.conf
    else
      warn "No VerbosePkgLists line to sit under, putting Color/ILoveCandy at the top of [options]."
      sudo sed -i '/^\[options\]/a Color\nILoveCandy' /etc/pacman.conf
    fi

    msg "pacman.conf updated: Color, VerbosePkgLists, ParallelDownloads enabled."
  else
    warn "/etc/pacman.conf not found. Skipping."
  fi
}

# ==========================
# PACCACHE TIMER
# ==========================

configure_paccache_timer() {
  info "Enabling paccache timer..."
  if sudo systemctl enable --now paccache.timer > /dev/null 2>&1; then
    msg "paccache timer enabled. Old package cache entries will be cleaned automatically."
  else
    warn "Failed to enable paccache.timer. You can enable it manually with:"
    warn "  sudo systemctl enable --now paccache.timer"
  fi
}

# ==========================
# MAIN INSTALLATION FLOW
# ==========================

print_header() {
  printf "\n"
  printf "${GREEN}${BOLD}"
  cat << "EOF"
════════════════════════════════════════════════════════════
   JUPITER - Base Installer v1.0
   Minimal setup for first boot (niri + greetd)
════════════════════════════════════════════════════════════
EOF
  printf "${NC}"
  printf "\n"
  printf "Log file: ${BLUE}%s${NC}\n" "${LOG_FILE}"
  printf "\n"
}

print_summary() {
  printf "\n"
  printf "${GREEN}${BOLD}"
  cat << "EOF"
════════════════════════════════════════════════════════════
   BASE INSTALLATION COMPLETED!
   niri is ready for first boot.
════════════════════════════════════════════════════════════
EOF
  printf "${NC}\n"
  printf "\n"
  printf "${MAGENTA}${BOLD}Next Steps:${NC}\n"
  printf "  1. Reboot your system\n"
  printf "  2. Log in through tuigreet (niri will start)\n"
  printf "  3. Once in niri, run install.sh for the full desktop setup\n"
  printf "\n"
}

main() {
  mkdir -p "${JUPITER_TEMP}"

  print_header

  step "Pre-flight System Checks"
  check_not_root
  check_arch_based
  check_sudo
  check_internet

  step "System Update"
  update_system

  step "Installing Base Development Tools"
  install_base_tools

  step "Installing Niri Stack"
  install_niri_stack

  step "Installing NVIDIA Packages"
  install_nvidia

  step "Configuring Greetd + Tuigreet"
  configure_greeter

  step "Enabling Paccache Timer"
  configure_paccache_timer

  step "Configuring pacman.conf"
  configure_pacman_conf

  print_summary

  # Cleanup
  if [[ -d "${JUPITER_TEMP}" ]]; then
    read -r -p "Delete ${JUPITER_TEMP}? (y/N): " reply < /dev/tty || true
    if [[ "${reply}" =~ ^[Yy]$ ]]; then
      rm -rf "${JUPITER_TEMP}"
    fi
  fi
}

# ==========================
# ARGUMENT PARSING
# ==========================

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        echo "Usage: ${0##*/} [OPTIONS]"
        echo ""
        echo "Jupiter Base Installer - Minimal setup for first boot"
        echo ""
        echo "OPTIONS:"
        echo "  -h, --help      Display this help message and exit"
        echo "  -v, --version   Display version information"
        echo ""
        exit 0
        ;;
      -v | --version)
        echo "Jupiter Base Installer v1.0"
        exit 0
        ;;
      *)
        error "Unknown option: $1"
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
trap 'cleanup_on_exit' EXIT
trap 'cleanup_on_exit; exit 130' INT
trap 'cleanup_on_exit; exit 143' TERM

parse_arguments "$@"
main
