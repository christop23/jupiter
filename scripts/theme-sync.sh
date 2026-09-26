#!/bin/bash

set -uo pipefail

sleep 0.8 # let awww set the wallpaper

log_info() {
    local -r timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\033[1;34m[$timestamp] INFO: $*\033[0m" >&2
}

log_error() {
    local -r timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\033[1;31m[$timestamp] ERROR: $*\033[0m" >&2
}

log_success() {
    local -r timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\033[1;32m[$timestamp] SUCCESS: $*\033[0m" >&2
}

log_warn() {
    local -r timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "\033[1;33m[$timestamp] WARN: $*\033[0m" >&2
}

log_debug() {
    if [[ ${DEBUG:-0} -eq 1 ]]; then
        local -r timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo -e "\033[1;90m[$timestamp] DEBUG: $*\033[0m" >&2
    fi
}

die() {
    log_error "$*"
    exit 1
}

validate_dependencies() {
    local -ra required_deps=("$@")
    local missing_deps=()

    for dep in "${required_deps[@]}"; do
        command -v "$dep" > /dev/null 2>&1 || missing_deps+=("$dep")
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        die "Missing required dependencies: ${missing_deps[*]}"
    fi
}

send_notification() {
    local -r app_name="$1"
    local -r title="$2"
    local -r message="$3"
    local -r urgency="${4:-normal}"
    local -r icon="${5:-}"

    local notify_args=(
        --app-name="$app_name"
        --urgency="$urgency"
    )

    [[ -n "$icon" ]] && notify_args+=(--icon="$icon")

    notify-send "${notify_args[@]}" "$title" "$message"
}

# --- Configuration ---
readonly SCRIPT_NAME="${0##*/}"
readonly WALLPAPERS_DIR="$HOME/Pictures/Wallpapers"
readonly DEFAULT_GTK_THEME="Colloid-Dark"
readonly DEFAULT_ICON_THEME="Colloid-Dark"
readonly THEME_STATE_FILE="$HOME/.cache/theme-sync-state"

# Get theme based on directory and variation
map_to_gtk_theme() {
  local theme_name="$1"
  local variation="$2"

  case "${theme_name}" in
    "catppuccin")
      if [[ "$variation" == "light" ]]; then
        echo "Colloid-Light-Catppuccin"
      else
        echo "Colloid-Dark-Catppuccin"
      fi
      ;;
    "dracula")
      if [[ "$variation" == "light" ]]; then
        echo "Colloid-Light-Dracula"
      else
        echo "Colloid-Dark-Dracula"
      fi
      ;;
    "everforest")
      if [[ "$variation" == "light" ]]; then
        echo "Colloid-Light-Everforest"
      else
        echo "Colloid-Dark-Everforest"
      fi
      ;;
    "gruvbox")
      if [[ "$variation" == "light" ]]; then
        echo "Colloid-Light-Gruvbox"
      else
        echo "Colloid-Dark-Gruvbox"
      fi
      ;;
    "material")
      if [[ "$variation" == "light" ]]; then
        echo "Colloid-Light"
      else
        echo "Colloid-Grey-Dark"
      fi
      ;;
    "nord")
      if [[ "$variation" == "light" ]]; then
        echo "Colloid-Light-Nord"
      else
        echo "Colloid-Dark-Nord"
      fi
      ;;
    "solarized")
      if [[ "$variation" == "light" ]]; then
        echo "Osaka-Light-Solarized"
      else
        echo "Osaka-Dark-Solarized"
      fi
      ;;
    "rose-pine")
      if [[ "$variation" == "light" ]]; then
        echo "Rosepine-Light"
      else
        echo "Rosepine-Dark"
      fi
      ;;
    "tokyo-night")
      if [[ "$variation" == "light" ]]; then
        echo "Tokyonight-Light"
      else
        echo "Tokyonight-Dark"
      fi
      ;;
    *)
      log_warn "Unknown theme: $theme_name, using default theme"
      if [[ "$variation" == "light" ]]; then
        echo "Colloid-Light"
      else
        echo "Colloid-Dark"
      fi
      ;;
  esac
}

map_to_icon_theme() {
  local theme_name="$1"
  local variation="$2"

  case "${theme_name}" in
    "catppuccin")
      if [[ "$variation" == "light" ]]; then
        echo "Colloid-Catppuccin-Light"
      else
        echo "Colloid-Catppuccin-Dark"
      fi
      ;;
    "dracula")
      if [[ "$variation" == "light" ]]; then
        echo "Colloid-Dracula-Light"
      else
        echo "Colloid-Dracula-Dark"
      fi
      ;;
    "everforest")
      if [[ "$variation" == "light" ]]; then
        echo "Colloid-Everforest-Light"
      else
        echo "Colloid-Everforest-Dark"
      fi
      ;;
    "gruvbox")
      if [[ "$variation" == "light" ]]; then
        echo "Colloid-Gruvbox-Light"
      else
        echo "Colloid-Gruvbox-Dark"
      fi
      ;;
    "material")
      # Base colloid-dark for material as requested
      if [[ "$variation" == "light" ]]; then
        echo "Colloid-Light"
      else
        echo "Colloid-Dark"
      fi
      ;;
    "nord")
      if [[ "$variation" == "light" ]]; then
        echo "Colloid-Nord-Light"
      else
        echo "Colloid-Nord-Dark"
      fi
      ;;
    "solarized")
      # everforest for osaka (solarized) as requested
      if [[ "$variation" == "light" ]]; then
        echo "Colloid-Everforest-Light"
      else
        echo "Colloid-Everforest-Dark"
      fi
      ;;
    "rose-pine" | "tokyo-night")
      # catppuccin for rose-pine and tokyo-night as requested
      if [[ "$variation" == "light" ]]; then
        echo "Colloid-Catppuccin-Light"
      else
        echo "Colloid-Catppuccin-Dark"
      fi
      ;;
    *)
      log_warn "Unknown theme: $theme_name, using default icon theme"
      if [[ "$variation" == "light" ]]; then
        echo "Colloid-Light"
      else
        echo "Colloid-Dark"
      fi
      ;;
  esac
}

# --- Functions ---

detect_theme_from_wallpaper() {
  log_info "Detecting theme from current wallpaper directory"

  local wallpaper_path
  wallpaper_path=$(awww query 2> /dev/null | grep -oP '(?<=image: ).*' | head -n1 | tr -d '\n\r')

  if [[ -z "$wallpaper_path" ]]; then
    die "No wallpaper detected from awww query"
  fi

  if [[ ! -f "$wallpaper_path" ]]; then
    die "Wallpaper file does not exist: $wallpaper_path"
  fi

  log_debug "Found wallpaper: $wallpaper_path"

  local theme_dir
  theme_dir=$(dirname "$wallpaper_path")
  local parent_dir
  parent_dir=$(dirname "$theme_dir")

  local theme_name
  theme_name=$(basename "$parent_dir" | tr '[:upper:]' '[:lower:]')

  local variation
  variation=$(basename "$theme_dir" | tr '[:upper:]' '[:lower:]')

  if [[ "$theme_name" == "osaka" ]]; then
    theme_name="solarized"
  fi

  log_debug "Detected theme: $theme_name, variation: $variation"

  WALLPAPER_PATH="$wallpaper_path"
  WALLPAPER_VARIATION="$variation"
  DETECTED_THEME="$theme_name"

  export WALLPAPER_PATH WALLPAPER_VARIATION
}

check_theme_changed() {
  local -r current_theme="$1"
  local -r current_variation="$2"
  local -r current_wallpaper="${3:-}"

  # Create cache directory if it doesn't exist
  mkdir -p "$(dirname "$THEME_STATE_FILE")"

  if [[ ! -f "$THEME_STATE_FILE" ]]; then
    log_info "No previous theme state found, this is first run or cache was cleared"
    return 0 # Theme changed (first run)
  fi

  # Read into one variable rather than two: the state is a single line written
  # with a plain redirect, and a concurrent read can see a partial write. An
  # unparseable line is treated as changed, which costs one redundant pass and
  # cannot leave the colours stale.
  local state_line
  state_line="$(cat "$THEME_STATE_FILE" 2>/dev/null || true)"
  if [[ -z "$state_line" ]]; then
    log_info "Previous theme state was empty, treating as changed"
    return 0
  fi

  local previous_wallpaper="${state_line#*|}"
  local previous_theme_variation="${state_line%%|*}"
  local previous_theme="${previous_theme_variation%% *}"
  local previous_variation="${previous_theme_variation##* }"

  # The wallpaper is part of the key, not just the scheme. Keying on the scheme
  # alone meant a second wallpaper in the same folder read as unchanged and
  # skipped matugen entirely, so the colours stayed from the previous image --
  # and most folders here hold three or four of them, so it happened constantly.
  # The colours come from the image, so the image is what has to be compared.
  if [[ -n "$current_wallpaper" && -n "$previous_wallpaper" && "$current_wallpaper" != "$previous_wallpaper" ]]; then
    log_info "Wallpaper changed: $(basename "$previous_wallpaper") → $(basename "$current_wallpaper")"
    return 0
  fi

  if [[ "$current_theme" == "$previous_theme" && "$current_variation" == "$previous_variation" ]]; then
    log_info "Theme unchanged: $current_theme ($current_variation)"
    return 1 # Theme did not change
  else
    log_info "Theme changed: $previous_theme ($previous_variation) → $current_theme ($current_variation)"
    return 0 # Theme changed
  fi
}

save_theme_state() {
  local -r theme="$1"
  local -r variation="$2"
  local -r wallpaper="${3:-}"

  mkdir -p "$(dirname "$THEME_STATE_FILE")"
  # Written to a temporary file and renamed, so a reader never sees a partial
  # line. The wallpaper may contain spaces, so the two fields are separated by a
  # pipe and the wallpaper is last, which keeps the parse in
  # check_theme_changed unambiguous.
  local tmp_file="${THEME_STATE_FILE}.tmp.$$"
  printf '%s %s|%s\n' "$theme" "$variation" "$wallpaper" > "$tmp_file" \
    && mv -f "$tmp_file" "$THEME_STATE_FILE" \
    || { rm -f "$tmp_file"; log_warn "Could not write theme state"; return 1; }
  log_info "Saved theme state: $theme ($variation)"
}

# Function to set values in INI files
set_ini_value() {
  local -r file="$1"
  local -r section="$2"
  local -r key="$3"
  local -r value="$4"

  [[ -f "$file" ]] || touch "$file"
  if grep -q "^\\[$section\\]" "$file"; then
    if grep -q "^$key=" "$file"; then
      sed -i "/^\\[$section\\]/,/^\\[/ s/^$key=.*/$key=$value/" "$file"
    else
      sed -i "/^\\[$section\\]/a $key=$value" "$file"
    fi
  else
    # Single backslashes on purpose. Quoted, '\\n' reaches printf as
    # two characters: it prints one backslash and leaves the n alone, so every
    # run appended a literal \n instead of a newline and the file ended up as
    # one long line that GTK cannot parse. The sed patterns above get this right
    # only because they are double quoted, where bash collapses \\ to \.
    printf '\n[%s]\n%s=%s\n' "$section" "$key" "$value" >> "$file"
  fi
}

manage_gtk_config() {
  local -r version="$1"
  local -r theme="$2"
  local -r variation="${3:-dark}"
  local -r config_file="$HOME/.config/gtk-$version/settings.ini"

  # Create directory if it doesn't exist
  mkdir -p "$(dirname "$config_file")"

  set_ini_value "$config_file" "Settings" "gtk-theme-name" "$theme"

  # Set prefer-dark-theme based on variation
  if [[ "$variation" == "light" ]]; then
    set_ini_value "$config_file" "Settings" "gtk-application-prefer-dark-theme" "0"
  else
    set_ini_value "$config_file" "Settings" "gtk-application-prefer-dark-theme" "1"
  fi
}

update_xsettingsd() {
  local -r theme="$1"
  local -r icon_theme="$2"
  local -r config_file="$HOME/.config/xsettingsd/xsettingsd.conf"

  # Create directory if it doesn't exist
  mkdir -p "$(dirname "$config_file")"

  # Check if file exists, create it with proper format if it doesn't
  if [[ ! -f "$config_file" ]]; then
    printf 'Net/ThemeName "%s"
Net/IconThemeName "%s"
' "$theme" "$icon_theme" > "$config_file"
  else
    sed -i "s/Net\/ThemeName \".*\"/Net\/ThemeName \"$theme\"/; s/Net\/IconThemeName \".*\"/Net\/IconThemeName \"$icon_theme\"/" "$config_file" 2> /dev/null ||
      log_warn "Failed to update xsettingsd config for theme name"
  fi
}

update_gtk_settings() {
  local -r gtk_theme="$1"
  local -r variation="$2"

  # Set the GTK theme using gsettings
  gsettings set org.gnome.desktop.interface gtk-theme "$gtk_theme" 2> /dev/null || {
    log_warn "Failed to set GTK theme via gsettings, may not be available"
  }

  # Set color scheme based on variation
  if [[ "$variation" == "light" ]]; then
    gsettings set org.gnome.desktop.interface color-scheme "prefer-light" 2> /dev/null || {
      log_warn "Failed to set light color scheme via gsettings"
    }
  else
    gsettings set org.gnome.desktop.interface color-scheme "prefer-dark" 2> /dev/null || {
      log_warn "Failed to set dark color scheme via gsettings"
    }
  fi

  # Force reload of GTK settings for running applications
  if command -v dbus-send > /dev/null 2>&1; then
    dbus-send --session --dest=org.gtk.Settings --type=method_call \
      /org/gtk/Settings org.gtk.Settings.NotifyThemeChange 2> /dev/null || true
  fi

  # Reload xsettingsd if running
  if command -v pgrep > /dev/null 2>&1 && command -v pkill > /dev/null 2>&1; then
    if pgrep -x xsettingsd > /dev/null; then
      pkill -HUP xsettingsd
    fi
  else
    log_warn "pgrep/pkill not available, skipping xsettingsd reload"
  fi
}

manage_symlinks() {
  local -r theme="$1"
  local target_dir=""

  # Find theme directory
  local -ra theme_paths=(
    "$HOME/.themes/$theme"
    "$HOME/.local/share/themes/$theme"
    "/usr/share/themes/$theme"
  )

  for path in "${theme_paths[@]}"; do
    if [[ -d "$path" ]]; then
      target_dir="$path"
      break
    fi
  done

  [[ -n "$target_dir" ]] || {
    log_warn "Theme assets not found: $theme, skipping symlinks"
    return 1
  }

  # Create symlinks for GTK 4.0
  local -r gtk4_dir="$HOME/.config/gtk-4.0"
  mkdir -p "$gtk4_dir"

  # matugen writes this one now, so a link left behind by an earlier run has to
  # go before anything else touches the path. Writing to a symlink follows it,
  # which would land in the theme's own stylesheet and gut it.
  if [[ -L "$gtk4_dir/gtk.css" ]]; then
    rm -f "$gtk4_dir/gtk.css" &&
      log_info "Removed the gtk.css link, matugen owns that file now"
  fi

  declare -A links=(
    ["$gtk4_dir/gtk-dark.css"]="gtk-4.0/gtk-dark.css"
    ["$gtk4_dir/assets"]="gtk-4.0/assets"
  )

  # Create symlinks
  for link in "${!links[@]}"; do
    local target="$target_dir/${links[$link]}"
    [[ -e "$target" ]] || continue

    mkdir -p "$(dirname "$link")"
    ln -sf "$target" "$link" && log_info "Created symlink: ${link##*/}"
  done
}

set_gtk_theme() {
  local -r gtk_theme="$1"
  local -r variation="${2:-dark}"
  local -r icon_theme="${3:-$DEFAULT_ICON_THEME}"

  log_info "Setting GTK theme to: $gtk_theme"

  # Check if theme directory exists
  local theme_found=0
  local -ra theme_paths=(
    "$HOME/.themes/$gtk_theme"
    "$HOME/.local/share/themes/$gtk_theme"
    "/usr/share/themes/$gtk_theme"
  )

  for path in "${theme_paths[@]}"; do
    if [[ -d "$path" ]]; then
      theme_found=1
      break
    fi
  done

  if [[ $theme_found -eq 0 ]]; then
    log_warn "GTK theme not found: $gtk_theme, skipping theme change"
    return
  fi

  # Apply theme through multiple methods to ensure coverage
  update_gtk_settings "$gtk_theme" "$variation"
  manage_gtk_config "3.0" "$gtk_theme" "$variation"
  manage_gtk_config "4.0" "$gtk_theme" "$variation"
  manage_symlinks "$gtk_theme"
  update_xsettingsd "$gtk_theme" "$icon_theme"

  log_success "GTK theme set to: $gtk_theme with comprehensive configuration"
}

set_icon_theme() {
  local -r icon_theme="$1"

  log_info "Setting icon theme to: $icon_theme"

  # Check if icon theme directory exists
  local theme_found=0
  local -ra icon_theme_paths=(
    "$HOME/.icons/$icon_theme"
    "$HOME/.local/share/icons/$icon_theme"
    "/usr/share/icons/$icon_theme"
  )

  for path in "${icon_theme_paths[@]}"; do
    if [[ -d "$path" ]]; then
      theme_found=1
      break
    fi
  done

  if [[ $theme_found -eq 0 ]]; then
    log_warn "Icon theme not found: $icon_theme, skipping icon theme change"
    return
  fi

  # Set the icon theme
  gsettings set org.gnome.desktop.interface icon-theme "$icon_theme" || {
    log_warn "Failed to set icon theme, gsettings may not be available"
  }

  log_success "Icon theme set to: $icon_theme"
}

run_matugen_theme() {
  local -r mode="$1"
  local -r wallpaper_path="$2"

  log_info "Running matugen (mode: $mode) for wallpaper: $wallpaper_path"

  # stdout is captured rather than discarded. matugen prints its colour table
  # there, so leaving it alone spammed the terminal and, worse, threw away the
  # only output that explains a failure -- which is why a failed run used to
  # carry on silently and then report success.
  local output
  if output="$(matugen image "$wallpaper_path" --mode "$mode" --type scheme-smart 2>&1)"; then
    log_success "Matugen theme generation completed"
    return 0
  fi

  log_error "Matugen theme generation failed"
  if [[ -n "$output" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && log_warn "  matugen: $line"
    done <<< "$output"
  fi
  return 1
}

update_niri_config() {
  local -r niri_config_file="$HOME/.config/niri/config.kdl"
  local -r matugen_colors_file="$HOME/.cache/wal/colors.json"

  if [[ ! -f "$matugen_colors_file" ]]; then
    log_warn "Matugen color cache not found, skipping niri config update"
    return
  fi

  if [[ ! -f "$niri_config_file" ]]; then
    log_warn "niri config not found at ${niri_config_file}, skipping"
    return 1
  fi

  # .special.cursor, not .special.background. The focus ring and insert hint
  # are drawn against the backdrop, so painting them the background colour made
  # them invisible. The cursor value is the accent, which is what matugen's
  # pywal cache pairs with colors.primary.
  #
  # jq -e with the interpolated form, so a missing key exits non-zero instead of
  # printing the string "null": the old -z test did not catch that, and
  # `active-color "null"` in config.kdl is a value niri rejects on reload.
  local accent_color
  if ! accent_color="$(jq -re '"\(.special.cursor)" // empty' "$matugen_colors_file" 2>/dev/null)" \
     || [[ ! "$accent_color" =~ ^#[[:xdigit:]]{6,8}$ ]]; then
    log_warn "Could not read a usable accent colour from ${matugen_colors_file}, skipping niri update"
    return 1
  fi

  log_info "Updating niri config with accent color: $accent_color"

  # The overview backdrop is a direct substitution rather than a range: an
  # /overview {/,/}/ range stops at the closing brace of the nested
  # workspace-shadow block, not the outer one.
  #
  # Every sed is checked, because none of them failing was previously visible
  # and the function logged success regardless.
  local rc=0
  sed -i "/focus-ring {/,/}/ s/active-color \".*\"/active-color \"$accent_color\"/" "$niri_config_file" || rc=1
  sed -i "/insert-hint {/,/}/ s/color \".*\"/color \"$accent_color\"/" "$niri_config_file" || rc=1
  sed -i "s/backdrop-color \".*\"/backdrop-color \"$accent_color\"/" "$niri_config_file" || rc=1

  if [[ $rc -ne 0 ]]; then
    log_error "Failed to update niri config"
    return 1
  fi

  # The two blocks this patches are switched off in the config it is patching:
  # focus-ring has width 0 and insert-hint is off, so the accent just written
  # has no visible effect. Say so rather than leaving it looking applied.
  if grep -A2 'focus-ring {' "$niri_config_file" | grep -qE '^\s*width 0'; then
    log_warn "focus-ring width is 0, so the accent is not visible."
    log_warn "Set it to 2 in niri/config.kdl to see the focus ring."
  fi
  if grep -A1 'insert-hint {' "$niri_config_file" | grep -qE '^\s*off'; then
    log_warn "insert-hint is off, so the accent is not visible there either."
    log_warn "Remove 'off' from insert-hint in niri/config.kdl to enable it."
  fi

  log_success "Niri config updated"
}

update_vscode_theme() {
  local -r vscode_settings_file="$HOME/.config/Code/User/settings.json"
  local theme

  if [[ ! -f "$vscode_settings_file" ]]; then
    log_warn "VSCode settings file not found, skipping theme update"
    return
  fi

  if [[ "$WALLPAPER_VARIATION" == "light" ]]; then
    theme="Light Modern"
  else
    theme="Dark Modern"
  fi

  log_info "Updating VSCode theme to: $theme"

  if ! sed -i "s/\"workbench.colorTheme\": \".*\"/\"workbench.colorTheme\": \"$theme\"/" "$vscode_settings_file"; then
    log_error "Failed to update VSCode theme with sed"
    return 1
  fi

  log_success "VSCode theme updated successfully"
}

main() {
  log_info "Starting dynamic theme synchronization"

  # Validate dependencies
  validate_dependencies "awww" "matugen" "jq" "sed" "grep" "head" "tr"

  # Detect theme from current wallpaper
  detect_theme_from_wallpaper

  local detected_theme="${DETECTED_THEME:-}"
  local wallpaper_path="${WALLPAPER_PATH:-}"
  local wallpaper_variation="${WALLPAPER_VARIATION:-}"

  if [[ -z "$detected_theme" ]]; then
    die "Unable to determine theme from current wallpaper"
  fi

  if [[ -z "$wallpaper_path" || ! -f "$wallpaper_path" ]]; then
    die "Wallpaper file does not exist: ${wallpaper_path:-unknown}"
  fi

  if [[ -z "$wallpaper_variation" ]]; then
    die "Unable to determine wallpaper variation"
  fi

  log_info "Detected theme: $detected_theme, variation: $wallpaper_variation"

  # Check if the wallpaper, theme or variation changed
  local theme_changed=0
  if check_theme_changed "$detected_theme" "$wallpaper_variation" "$wallpaper_path"; then
    theme_changed=1
  fi

  # Map to appropriate themes using both theme and variation
  local gtk_theme
  gtk_theme=$(map_to_gtk_theme "$detected_theme" "$wallpaper_variation")

  local icon_theme
  icon_theme=$(map_to_icon_theme "$detected_theme" "$wallpaper_variation")

  local matugen_mode
  if [[ "$wallpaper_variation" == "light" ]]; then
    matugen_mode="light"
  else
    matugen_mode="dark"
  fi

  # Only apply themes if the wallpaper, theme or variation changed
  if [[ $theme_changed -eq 1 ]]; then
    set_gtk_theme "$gtk_theme" "$wallpaper_variation" "$icon_theme"
    set_icon_theme "$icon_theme"

    # The state is only saved once the colours are actually known to be new.
    # Saving it unconditionally meant one failed matugen run was cached as
    # success, which turned a transient failure into theming staying stale for
    # that wallpaper until the user picked one from a different scheme folder.
    if ! run_matugen_theme "$matugen_mode" "$wallpaper_path"; then
      log_error "Theme generation failed. State not saved, so the next run retries."
      save_theme_state "$detected_theme" "$wallpaper_variation" ""
      send_notification "Theme Manager" "Theme Generation Failed" "The wallpaper colours were not applied" "critical" "preferences-desktop-theme"
      return 1
    fi

    update_niri_config
    update_vscode_theme

    if command -v vicinae > /dev/null 2>&1; then
      vicinae theme set matugen || log_warn "Failed to set vicinae theme"
    else
      log_warn "vicinae not found, skipping vicinae theme update"
    fi

    if command -v makoctl > /dev/null 2>&1; then
      makoctl reload 2> /dev/null || log_warn "Failed to reload mako"
    else
      log_warn "makoctl not available, skipping notification daemon reload"
    fi

    save_theme_state "$detected_theme" "$wallpaper_variation" "$wallpaper_path"

    log_success "Dynamic theme synchronization completed successfully"
    send_notification "Theme Manager" "Theme Synchronization Complete" "" "normal" "preferences-desktop-theme"
  else
    log_info "Wallpaper and theme unchanged, skipping all theming operations"
    log_success "Wallpaper applied, no theme changes needed"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

