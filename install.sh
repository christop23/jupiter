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
readonly TOTAL_STEPS=15

# Installation summary tracking
declare -a INSTALL_SUMMARY=()

# Shell configuration - fish is the default and only shell
CONFIGURE_FISH=true

# Whether the login shell was confirmed as fish, not merely requested
SET_DEFAULT_SHELL_OK=false

# Process ID for sudo keep-alive
SUDO_PID=""

# Expected configuration folders in the repo
readonly CONFIG_FOLDERS=(
  niri waybar fish fastfetch mako alacritty starship
  vicinae gtklock zathura matugen scripts
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

# AUR packages to install
readonly AUR_PACKAGES=(
  vicinae-bin
)

# Official repository packages
readonly PACMAN_PACKAGES=(
  niri waybar fish fastfetch mako alacritty starship eza
  zathura zathura-pdf-mupdf ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols
  qt5-wayland qt6-wayland polkit-gnome jq 7zip man-db bat
  gtklock curl libnotify pavucontrol thunar awww matugen librewolf bottom
  # Referenced by the configs, so installed rather than left dangling:
  #   qt5ct, qt6ct        the platform-theme plugin niri/config.kdl names with
  #                       QT_QPA_PLATFORMTHEME, without which Qt cannot read
  #                       the Colloid theme in ~/.themes
  #   networkmanager      nmtui, which fish/config.fish aliases as `wifi`
  qt5ct qt6ct networkmanager
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
  printf "Jupiter Installer v2.0\n"
  printf "Split base/install edition\n"
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

# Runs a command, retrying it up to max_attempts times with a growing wait.
#
# A destination directory can be cleared between attempts, given as the second
# argument. A clone that fails partway leaves the target behind, and
# `git clone` refuses a non-empty destination, so without this the second and
# third attempts of every clone in this file could only fail immediately: the
# retry was a no-op that burned two warn lines and two sleeps. The caller is
# already deleting the directory on a final failure, so clearing it here does
# not take away any recovery it relied on.
retry_command() {
  local max_attempts="$1"
  shift
  local -a cmd=("$@")
  local clean_dir=""
  local attempt=1

  # A trailing argument of the form --clean-dir=PATH names the destination to
  # clear between attempts. It is stripped before the command runs, since git
  # would not understand it.
  #
  # The two refusals are belt and braces on an rm -rf. At every call site the
  # path is either a mktemp directory or a fresh clone target, so in practice
  # neither can fire; they are here so that a future caller passing something
  # else gets a warning and no deletion rather than a deleted home directory.
  if [[ "${cmd[-1]:-}" == --clean-dir=* ]]; then
    clean_dir="${cmd[-1]#--clean-dir=}"
    cmd=("${cmd[@]:0:${#cmd[@]} - 1}")
    if [[ -z "${clean_dir}" || "${clean_dir}" == "/" || ! "${clean_dir}" == /* ]]; then
      warn "Refusing to clear '${clean_dir}': not an absolute path."
      clean_dir=""
    fi
  fi

  while [[ ${attempt} -le ${max_attempts} ]]; do
    if [[ -n "${clean_dir}" ]]; then
      rm -rf "${clean_dir}" 2> /dev/null || true
    fi

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
        read -r -p "Retry backup of ${folder}? (Y/n): " reply < /dev/tty || true
        if [[ -z "${reply}" || "${reply}" =~ ^[Yy]$ ]]; then
          if cp -rL "${target}" "${BACKUP_DIR}/" 2> /dev/null; then
            rm -rf "${target}"
            info "Backed up: ${folder}"
            ((++backed_up)) || true
          else
            warn "Failed to backup: ${folder} again"
            warn "It will be left in place rather than deleted, so nothing is lost."
            BACKUP_FAILED+=("${folder}")
          fi
        else
          warn "It will be left in place rather than deleted, so nothing is lost."
          BACKUP_FAILED+=("${folder}")
        fi
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
        read -r -p "Retry backup of ${file}? (Y/n): " reply < /dev/tty || true
        if [[ -z "${reply}" || "${reply}" =~ ^[Yy]$ ]]; then
          if cp -L "${target}" "${BACKUP_DIR}/" 2> /dev/null; then
            rm -f "${target}"
            info "Backed up: ${file}"
            ((++backed_up)) || true
          else
            warn "Failed to backup: ${file} again"
            warn "It will be left in place rather than deleted, so nothing is lost."
            BACKUP_FAILED+=("${file}")
          fi
        else
          warn "It will be left in place rather than deleted, so nothing is lost."
          BACKUP_FAILED+=("${file}")
        fi
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
  if ! retry_command 3 git clone --depth=1 https://aur.archlinux.org/yay-bin.git "${TEMP_BUILD_DIR}" --clean-dir="${TEMP_BUILD_DIR}" 2>&1 | log_and_show "${LOG_FILE}"; then
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
  info "Installing official repository packages..."
  info "This may take several minutes..."

  if sudo pacman -S --needed "${PACMAN_PACKAGES[@]}" < /dev/tty 2>&1 | log_and_show "${LOG_FILE}"; then
    msg "Official packages installed successfully."
  else
    fatal "Failed to install official repository packages."
  fi
}

install_aur_packages() {
  info "Installing AUR packages using ${AUR_HELPER}..."

  # IFS is newline+tab in this script, so join explicitly for a single-line hint.
  local target_list
  printf -v target_list '%s ' "${AUR_PACKAGES[@]}"
  info "Installing: ${target_list% }"
  info "This may take several minutes..."

  if "${AUR_HELPER}" -S --needed "${AUR_PACKAGES[@]}" < /dev/tty 2>&1 | log_and_show "${LOG_FILE}"; then
    msg "AUR packages installed successfully."
  else
    fatal "Failed to install AUR packages."
  fi
}

# ==========================
# THEME MANAGEMENT
# ==========================

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

  if ! retry_command 3 git clone --depth=1 https://github.com/vinceliuice/Colloid-gtk-theme "${theme_dir}" --clean-dir="${theme_dir}" 2>&1 | log_and_show "${LOG_FILE}"; then
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

  if ! retry_command 3 git clone --depth=1 https://github.com/Fausto-Korpsvart/Rose-Pine-GTK-Theme "${theme_dir}" --clean-dir="${theme_dir}" 2>&1 | log_and_show "${LOG_FILE}"; then
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

  if ! retry_command 3 git clone --depth=1 https://github.com/Fausto-Korpsvart/Osaka-GTK-Theme "${theme_dir}" --clean-dir="${theme_dir}" 2>&1 | log_and_show "${LOG_FILE}"; then
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

  if ! retry_command 3 git clone --depth=1 https://github.com/vinceliuice/Colloid-icon-theme "${icons_dir}" --clean-dir="${icons_dir}" 2>&1 | log_and_show "${LOG_FILE}"; then
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
    vicinae gtklock zathura matugen awww librewolf btm
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
  if ! retry_command 3 git clone --depth=1 "${REPO_URL}" "${target}" --clean-dir="${target}" 2>&1 | log_and_show "${LOG_FILE}"; then
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

delete_config_folder() {
  info "Deleting .config folder..."
  if [[ -d "${CONFIG_DIR}" ]]; then
    rm -rf "${CONFIG_DIR}"
    msg ".config folder deleted."
  else
    info ".config folder does not exist, nothing to delete."
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
   JUPITER - Installation Script v2.0
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

  step "System Update"
  update_system
  add_summary "System packages updated"

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

  step "Deleting .config Folder"
  delete_config_folder
  add_summary ".config folder deleted"

  step "Creating Symbolic Links"
  create_symlinks
  add_summary "Configuration symlinks created in ~/.config"

  step "Installing Wallpapers"
  install_wallpapers
  add_summary "Wallpapers installed to ~/Pictures/Wallpapers"

  step "Configuring System Services"
  create_systemd_services
  add_summary "Systemd services configured"

  print_summary

  # Cleanup, asked rather than done outright, the same way base.sh asks. The
  # directory holds the config backup taken before the dotfiles were linked
  # over them, and the log that every `fatal` points at, whose path was
  # printed only in the header at the start of the run. Default is to keep it:
  # an empty answer is not consent.
  if [[ -d "${JUPITER_TEMP}" ]]; then
    read -r -p "Delete ${JUPITER_TEMP} (backup and log)? (y/N): " reply < /dev/tty || true
    if [[ "${reply}" =~ ^[Yy]$ ]]; then
      rm -rf "${JUPITER_TEMP}"
      msg "Removed ${JUPITER_TEMP} (backup and log)."
    else
      msg "Kept ${JUPITER_TEMP}. Log file: ${LOG_FILE}"
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
