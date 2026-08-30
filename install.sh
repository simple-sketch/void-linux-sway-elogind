#!/bin/sh

# Install an Intel Sway/Noctalia desktop with elogind, multimedia, and iwd,
# then clone and stow the matching user configuration. Keep this installer
# self-contained so it does not depend on another script's name or location.
# Do not combine this setup with seatd or turnstile.

set -eu

command -v xbps-uhelper >/dev/null 2>&1 || {
  echo "this installer requires Void Linux and XBPS" >&2
  exit 1
}

XBPS_ARCH=$(xbps-uhelper arch)
if [ "$XBPS_ARCH" != x86_64 ]; then
  echo "unsupported XBPS architecture: $XBPS_ARCH (expected x86_64 glibc)" >&2
  exit 1
fi

DOTFILES_REPO="https://github.com/simple-sketch/dotfiles-stow"
VOIDERS_REPO="https://repo.voiders.dev"
# Published independently of the repository metadata at:
# https://codeberg.org/voiders-community/repository
VOIDERS_FINGERPRINT="a8:f0:05:df:01:c4:37:92:83:f6:8b:9a:ce:ab:73:29"

if [ "$(id -u)" -eq 0 ]; then
  REAL_USER=${SUDO_USER:-}

  if [ -z "$REAL_USER" ] || [ "$REAL_USER" = root ]; then
    echo "run this script as your normal user, not directly as root" >&2
    exit 1
  fi
else
  REAL_USER=$(id -un)
fi

USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

case "$USER_HOME" in
"" | /)
  echo "unsafe home directory for $REAL_USER: ${USER_HOME:-<empty>}" >&2
  exit 1
  ;;
/*) ;;
*)
  echo "home directory is not absolute for $REAL_USER: $USER_HOME" >&2
  exit 1
  ;;
esac

DOTFILES_DIR="$USER_HOME/dotfiles-stow"
SERVICE_START_TIMEOUT=15
IWD_CONFIG_FILE=${IWD_CONFIG_FILE:-/etc/iwd/main.conf}
IWD_WAS_ENABLED=false
WPA_SUPPLICANT_WAS_ENABLED=false
IWD_ROLLBACK_REQUIRED=false
USE_EXISTING_DOTFILES=false

command -v sudo >/dev/null 2>&1 || {
  echo "sudo is required" >&2
  exit 1
}

# Authentication and read-only sudo checks are allowed during preflight.
sudo -v

run_as_user() {
  set -- env \
    HOME="$USER_HOME" \
    XDG_CONFIG_HOME="$USER_HOME/.config" \
    XDG_DATA_HOME="$USER_HOME/.local/share" \
    XDG_STATE_HOME="$USER_HOME/.local/state" \
    XDG_CACHE_HOME="$USER_HOME/.cache" \
    "$@"

  if [ "$(id -u)" -eq 0 ]; then
    sudo -u "$REAL_USER" "$@"
  else
    "$@"
  fi
}

enable_service() {
  service_name=$1
  service_source="/etc/sv/$service_name"
  service_target="/var/service/$service_name"

  if [ ! -d "$service_source" ]; then
    echo "service directory is missing: $service_source" >&2
    return 1
  fi

  if [ -e "$service_target" ] && [ ! -d "$service_target" ] && [ ! -L "$service_target" ]; then
    echo "cannot enable $service_name: $service_target is not a service directory or symlink" >&2
    return 1
  fi

  # Keep an existing service directory intact; otherwise create or repair the
  # conventional runit symlink.
  if [ ! -d "$service_target" ] || [ -L "$service_target" ]; then
    sudo ln -sfn "$service_source" "$service_target"
  fi

  # `start` explicitly changes a requested-down service to up. Its own timeout
  # bounds both the request and readiness wait.
  if ! sudo sv -w "$SERVICE_START_TIMEOUT" start "$service_target"; then
    sudo sv status "$service_target" >&2 || true
    echo "error: $service_name did not become ready within ${SERVICE_START_TIMEOUT}s" >&2
    return 1
  fi

  sudo sv status "$service_target"
}

service_is_enabled() {
  service_name=$1
  [ -e "/var/service/$service_name" ] || [ -L "/var/service/$service_name" ]
}

restore_wireless_on_exit() {
  exit_status=$?
  trap - EXIT

  if [ "$IWD_ROLLBACK_REQUIRED" = true ]; then
    echo "iwd setup failed; restoring the previous wireless service" >&2

    if [ "$IWD_WAS_ENABLED" = false ]; then
      sudo sv down iwd >/dev/null 2>&1 || true
      if [ -L /var/service/iwd ]; then
        sudo rm -f /var/service/iwd ||
          echo "warning: could not remove the iwd service link" >&2
      fi
    fi

    if [ "$WPA_SUPPLICANT_WAS_ENABLED" = true ]; then
      if sudo ln -sfn /etc/sv/wpa_supplicant /var/service/wpa_supplicant; then
        sudo sv up wpa_supplicant >/dev/null 2>&1 ||
          echo "warning: restored wpa_supplicant but could not start it" >&2
      else
        echo "warning: could not restore the wpa_supplicant service link" >&2
      fi
    fi
  fi

  exit "$exit_status"
}

root_path_exists() {
  sudo test -e "$1" || sudo test -L "$1"
}

user_path_exists() {
  run_as_user test -e "$1" || run_as_user test -L "$1"
}

require_root_file_state() {
  managed_path=$1
  expected_file=$2

  root_path_exists "$managed_path" || return 0

  if ! sudo test -f "$managed_path" || sudo test -L "$managed_path" ||
    ! sudo cmp -s "$expected_file" "$managed_path"; then
    echo "configuration collision: $managed_path differs from the installer-managed file" >&2
    echo "move or remove it, then rerun the installer" >&2
    exit 1
  fi
}

require_user_file_state() {
  managed_path=$1
  expected_file=$2

  user_path_exists "$managed_path" || return 0

  if ! run_as_user test -f "$managed_path" || run_as_user test -L "$managed_path" ||
    ! run_as_user cmp -s "$expected_file" "$managed_path"; then
    echo "configuration collision: $managed_path differs from the installer-managed file" >&2
    echo "move or remove it, then rerun the installer" >&2
    exit 1
  fi
}

require_root_link_state() {
  managed_path=$1
  expected_target=$2

  root_path_exists "$managed_path" || return 0

  if ! sudo test -L "$managed_path" ||
    [ "$(sudo readlink "$managed_path")" != "$expected_target" ]; then
    echo "configuration collision: $managed_path must link to $expected_target" >&2
    echo "move or remove it, then rerun the installer" >&2
    exit 1
  fi
}

require_user_link_state() {
  managed_path=$1
  expected_target=$2

  user_path_exists "$managed_path" || return 0

  if ! run_as_user test -L "$managed_path" ||
    [ "$(run_as_user readlink "$managed_path")" != "$expected_target" ]; then
    echo "configuration collision: $managed_path must link to $expected_target" >&2
    echo "move or remove it, then rerun the installer" >&2
    exit 1
  fi
}

require_root_directory_or_absent() {
  managed_directory=$1

  root_path_exists "$managed_directory" || return 0
  if ! sudo test -d "$managed_directory" || sudo test -L "$managed_directory"; then
    echo "configuration collision: $managed_directory must be a directory" >&2
    echo "move or remove it, then rerun the installer" >&2
    exit 1
  fi
}

require_user_directory_or_absent() {
  managed_directory=$1

  user_path_exists "$managed_directory" || return 0
  if ! run_as_user test -d "$managed_directory" || run_as_user test -L "$managed_directory"; then
    echo "configuration collision: $managed_directory must be a directory" >&2
    echo "move or remove it, then rerun the installer" >&2
    exit 1
  fi
}

ensure_root_directory() {
  managed_directory=$1
  require_root_directory_or_absent "$managed_directory"
  root_path_exists "$managed_directory" && return 0

  if ! sudo mkdir -m 0755 "$managed_directory"; then
    require_root_directory_or_absent "$managed_directory"
  fi
}

ensure_user_directory() {
  managed_directory=$1
  require_user_directory_or_absent "$managed_directory"
  user_path_exists "$managed_directory" && return 0

  if ! run_as_user mkdir -m 0755 "$managed_directory"; then
    require_user_directory_or_absent "$managed_directory"
  fi
}

install_root_file_if_absent() {
  managed_path=$1
  expected_file=$2
  require_root_file_state "$managed_path" "$expected_file"
  root_path_exists "$managed_path" && return 0

  if ! sudo sh -c 'set -C; umask 022; cat "$1" >"$2"' sh "$expected_file" "$managed_path"; then
    require_root_file_state "$managed_path" "$expected_file"
  fi
}

install_user_file_if_absent() {
  managed_path=$1
  expected_file=$2
  require_user_file_state "$managed_path" "$expected_file"
  user_path_exists "$managed_path" && return 0

  # The positional parameters intentionally expand in the nested shell.
  # shellcheck disable=SC2016
  if ! run_as_user sh -c 'set -C; umask 022; cat "$1" >"$2"' sh "$expected_file" "$managed_path"; then
    require_user_file_state "$managed_path" "$expected_file"
  fi
}

install_root_link_if_absent() {
  managed_path=$1
  expected_target=$2
  require_root_link_state "$managed_path" "$expected_target"
  root_path_exists "$managed_path" && return 0

  if ! sudo ln -s "$expected_target" "$managed_path"; then
    require_root_link_state "$managed_path" "$expected_target"
  fi
}

install_user_link_if_absent() {
  managed_path=$1
  expected_target=$2
  require_user_link_state "$managed_path" "$expected_target"
  user_path_exists "$managed_path" && return 0

  if ! run_as_user ln -s "$expected_target" "$managed_path"; then
    require_user_link_state "$managed_path" "$expected_target"
  fi
}

read_dotfiles_origin_without_git() {
  run_as_user awk "
    BEGIN { in_origin = 0 }
    /^[[:space:]]*\\[/ {
      section = tolower(\$0)
      gsub(/[[:space:]]/, \"\", section)
      in_origin = (section == \"[remote\\\"origin\\\"]\")
      next
    }
    in_origin && /^[[:space:]]*url[[:space:]]*=/ {
      value = \$0
      sub(/^[^=]*=[[:space:]]*/, \"\", value)
      print value
    }
  " "$DOTFILES_DIR/.git/config"
}

read_dotfiles_origin() {
  if command -v git >/dev/null 2>&1; then
    run_as_user git -C "$DOTFILES_DIR" remote get-url origin
  else
    read_dotfiles_origin_without_git
  fi
}

cleanup_preflight() {
  rm -rf "$PREFLIGHT_DIR"
}

# Materialize exact managed content for non-mutating collision checks.
PREFLIGHT_DIR=$(mktemp -d)
chmod 0755 "$PREFLIGHT_DIR"
trap cleanup_preflight EXIT

cat >"$PREFLIGHT_DIR/voiders.conf" <<EOF
repository=$VOIDERS_REPO
EOF
cat >"$PREFLIGHT_DIR/tlp.conf" <<'EOF'
# Managed by void-sway-noctalia-elogind/install.sh.
TLP_ENABLE=1
TLP_AUTO_SWITCH=1
TLP_PROFILE_AC=SAV
TLP_PROFILE_BAT=SAV
TLP_PROFILE_DEFAULT=SAV
EOF
cat >"$PREFLIGHT_DIR/disable-x11-bell.conf" <<'EOF'
# Do not keep Xwayland alive solely to provide the legacy X11 bell.
context.properties = {
    module.x11.bell = false
}
EOF
chmod 0644 "$PREFLIGHT_DIR"/*

# Validate an existing checkout without assuming Git has already been installed.
if [ -e "$DOTFILES_DIR" ] || [ -L "$DOTFILES_DIR" ]; then
  if [ ! -d "$DOTFILES_DIR/.git" ]; then
    echo "$DOTFILES_DIR already exists and is not a Git checkout" >&2
    exit 1
  fi

  EXISTING_REPO=$(read_dotfiles_origin 2>/dev/null) || {
    echo "cannot read the origin for $DOTFILES_DIR" >&2
    exit 1
  }

  case "$EXISTING_REPO" in
  "$DOTFILES_REPO" | "$DOTFILES_REPO.git")
    USE_EXISTING_DOTFILES=true
    ;;
  *)
    echo "$DOTFILES_DIR has an unexpected origin: ${EXISTING_REPO:-<missing>}" >&2
    exit 1
    ;;
  esac
fi

PAM_ELOGIND_PATTERN='^[[:space:]]*-?session[[:space:]]+([^#[:space:]]+|\[[^]]+\])[[:space:]]+([^#[:space:]]*/)?pam_elogind\.so([[:space:]]+[^#]*)?([[:space:]]*#.*)?$'
if ! sudo test -f /etc/pam.d/system-login ||
  ! sudo grep -Eq "$PAM_ELOGIND_PATTERN" /etc/pam.d/system-login; then
  echo "error: an active pam_elogind.so session line is missing from /etc/pam.d/system-login" >&2
  echo "add '-session optional pam_elogind.so', then rerun the installer" >&2
  exit 1
fi

for network_manager in NetworkManager connmand wicd; do
  if service_is_enabled "$network_manager"; then
    echo "$network_manager is enabled and conflicts with standalone iwd" >&2
    echo "disable it first: sudo rm /var/service/$network_manager" >&2
    exit 1
  fi
done

if service_is_enabled wpa_supplicant && [ ! -L /var/service/wpa_supplicant ]; then
  echo "cannot switch wireless: /var/service/wpa_supplicant is not a removable symlink" >&2
  exit 1
fi

if service_is_enabled iwd; then
  if [ -L /var/service/iwd ]; then
    if [ "$(readlink /var/service/iwd)" != /etc/sv/iwd ]; then
      echo "cannot enable iwd: /var/service/iwd does not link to /etc/sv/iwd" >&2
      exit 1
    fi
  elif [ ! -d /var/service/iwd ]; then
    echo "cannot enable iwd: /var/service/iwd is not a service directory" >&2
    exit 1
  fi
fi

if sudo test -e "$IWD_CONFIG_FILE" || sudo test -L "$IWD_CONFIG_FILE"; then
  if ! sudo test -f "$IWD_CONFIG_FILE" || ! sudo test -r "$IWD_CONFIG_FILE"; then
    echo "cannot inspect iwd configuration as root: $IWD_CONFIG_FILE" >&2
    exit 1
  fi

  if sudo grep -Eiq '^[[:space:]]*EnableNetworkConfiguration[[:space:]]*=[[:space:]]*true([[:space:]]|$)' "$IWD_CONFIG_FILE"; then
    echo "cannot combine dhcpcd with EnableNetworkConfiguration=true in $IWD_CONFIG_FILE" >&2
    echo "disable iwd network configuration before running this script" >&2
    exit 1
  else
    grep_status=$?
    if [ "$grep_status" -ne 1 ]; then
      echo "cannot inspect iwd configuration as root: $IWD_CONFIG_FILE" >&2
      exit 1
    fi
  fi
fi

PIPEWIRE_DIR="$USER_HOME/.config/pipewire/pipewire.conf.d"
require_root_directory_or_absent /etc/xbps.d
require_root_directory_or_absent /etc/tlp.d
require_root_directory_or_absent /etc/alsa
require_root_directory_or_absent /etc/alsa/conf.d
require_user_directory_or_absent "$USER_HOME/.config"
require_user_directory_or_absent "$USER_HOME/.config/pipewire"
require_user_directory_or_absent "$PIPEWIRE_DIR"
require_root_file_state /etc/xbps.d/10-voiders-community.conf "$PREFLIGHT_DIR/voiders.conf"
require_root_file_state /etc/tlp.d/99-power-saver.conf "$PREFLIGHT_DIR/tlp.conf"
require_root_link_state /etc/alsa/conf.d/50-pipewire.conf /usr/share/alsa/alsa.conf.d/50-pipewire.conf
require_root_link_state /etc/alsa/conf.d/99-pipewire-default.conf /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf
require_user_link_state "$PIPEWIRE_DIR/10-wireplumber.conf" /usr/share/examples/wireplumber/10-wireplumber.conf
require_user_link_state "$PIPEWIRE_DIR/20-pipewire-pulse.conf" /usr/share/examples/pipewire/20-pipewire-pulse.conf
require_user_file_state "$PIPEWIRE_DIR/30-disable-x11-bell.conf" "$PREFLIGHT_DIR/disable-x11-bell.conf"

echo "Voiders repository expected fingerprint: $VOIDERS_FINGERPRINT"
echo "==> Authenticating and enabling the Voiders repository"

# Ignore configured repositories and sync only this URL. Do not persist its
# configuration until both the signed-repository marker and fingerprint match.
sudo xbps-install -i --repository="$VOIDERS_REPO" -S

VOIDERS_REPO_DETAILS=$(xbps-query -i --repository="$VOIDERS_REPO" -vL) || {
  echo "error: could not inspect the active Voiders repository signature" >&2
  exit 1
}

SIGNED_VOIDERS_REPOSITORIES=$(printf '%s\n' "$VOIDERS_REPO_DETAILS" | awk -v repo="$VOIDERS_REPO" '
  $1 ~ /^[[:digit:]]+$/ && $2 == repo && $3 == "(RSA" && $4 == "signed)" && NF == 4 {
    signed_repositories++
  }
  END { print signed_repositories + 0 }
')

if [ "$SIGNED_VOIDERS_REPOSITORIES" -ne 1 ]; then
  echo "error: the exact Voiders repository is not reported once as RSA signed" >&2
  printf '%s\n' "$VOIDERS_REPO_DETAILS" >&2
  exit 1
fi

ACTIVE_VOIDERS_FINGERPRINTS=$(printf '%s\n' "$VOIDERS_REPO_DETAILS" | awk '
  {
    for (field = 1; field <= NF; field++) {
      count = split($field, octet, ":")
      if (count != 16) {
        continue
      }
      valid = 1
      for (part = 1; part <= count; part++) {
        if (octet[part] !~ /^[[:xdigit:]][[:xdigit:]]$/) {
          valid = 0
        }
      }
      if (valid) {
        print tolower($field)
      }
    }
  }
')

if [ "$ACTIVE_VOIDERS_FINGERPRINTS" != "$VOIDERS_FINGERPRINT" ]; then
  echo "error: Voiders repository fingerprint verification failed" >&2
  echo "expected exactly: $VOIDERS_FINGERPRINT" >&2
  echo "active fingerprint(s): ${ACTIVE_VOIDERS_FINGERPRINTS:-<missing>}" >&2
  exit 1
fi

# Persist the repository only after authentication. The no-clobber helper
# revalidates immediately before creation and never replaces differing state.
ensure_root_directory /etc/xbps.d
install_root_file_if_absent /etc/xbps.d/10-voiders-community.conf "$PREFLIGHT_DIR/voiders.conf"

# Update XBPS only after the third-party repository has been authenticated.
sudo xbps-install -Syu xbps
sudo xbps-install -Syu

# Enable official nonfree and multilib repositories.
sudo xbps-install -Sy void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree
sudo xbps-install -Syu

echo "==> Installing graphics, Sway, Noctalia, apps, and CLI tools"

# Intel graphics.
sudo xbps-install -Sy linux-firmware-intel mesa-dri vulkan-loader mesa-vulkan-intel intel-video-accel intel-media-driver

# Portals and user directories.
sudo xbps-install -Sy xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk xdg-utils xdg-user-dirs xdg-user-dirs-gtk
run_as_user xdg-user-dirs-update

# Fonts.
sudo xbps-install -Sy dejavu-fonts-ttf noto-fonts-emoji noto-fonts-ttf

# Desktop apps and CLI tools, including Git and GNU Stow for the dotfiles step.
sudo xbps-install -Sy perl-File-MimeInfo shfmt shellcheck ddcutil kitty swayimg nodejs delta git eza bash-completion stow neovide shikane alacritty wmenu vim \
  playerctl libnotify grim slurp grimshot satty flameshot btop fastfetch brightnessctl base-devel \
  wl-clipboard sway foot firefox vlc xtools vsv lazygit neovim ghostty rsync yazi bat upower \
  ffmpeg 7zip unzip zip unrar jq poppler fd ripgrep fzf zoxide resvg ImageMagick noctalia bibata-modern-ice

# Audio and Bluetooth; elogind supplies device ACLs instead of an audio group.
sudo xbps-install -Sy bluez alsa-utils alsa-pipewire libjack-pipewire libspa-bluetooth pipewire wireplumber wireplumber-elogind

# Keep Vim's alternatives on Vim.
sudo xbps-alternatives -s vim -g vim

echo "==> Preparing dotfiles for $REAL_USER"

if [ "$USE_EXISTING_DOTFILES" = true ]; then
  echo "==> Using existing dotfiles checkout: $DOTFILES_DIR"
else
  echo "==> Cloning $DOTFILES_REPO"
  run_as_user git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
fi

# Keep Stow from folding these shared parent directories into one package.
run_as_user mkdir -p \
  "$USER_HOME/.config" \
  "$USER_HOME/.local/share" \
  "$USER_HOME/.local/state" \
  "$USER_HOME/.local/bin" \
  "$USER_HOME/Pictures/Screenshots" \
  "$USER_HOME/Pictures/Wallpapers"

# Back up files from /etc/skel that would otherwise conflict with Stow. A
# unique directory prevents reruns from overwriting an earlier backup.
BACKUP_DIR=

for name in .bashrc .bash_profile .inputrc .vimrc; do
  target="$USER_HOME/$name"

  [ -f "$target" ] || continue
  [ -L "$target" ] && continue

  if [ -z "$BACKUP_DIR" ]; then
    run_as_user mkdir -p "$USER_HOME/.dotfiles-backup"
    BACKUP_DIR=$(run_as_user mktemp -d "$USER_HOME/.dotfiles-backup/install-XXXXXXXX")
  fi

  run_as_user mv "$target" "$BACKUP_DIR/$name"
  echo "backup: $BACKUP_DIR/$name"
done

# Sway starts PipeWire; these drop-ins start its session services and prevent
# the X11 bell module from keeping an otherwise-unused Xwayland process alive.
# Revalidate immediately before each no-clobber install to close the gap between
# preflight and mutation.
ensure_user_directory "$USER_HOME/.config"
ensure_user_directory "$USER_HOME/.config/pipewire"
ensure_user_directory "$PIPEWIRE_DIR"
install_user_link_if_absent "$PIPEWIRE_DIR/10-wireplumber.conf" /usr/share/examples/wireplumber/10-wireplumber.conf
install_user_link_if_absent "$PIPEWIRE_DIR/20-pipewire-pulse.conf" /usr/share/examples/pipewire/20-pipewire-pulse.conf
install_user_file_if_absent "$PIPEWIRE_DIR/30-disable-x11-bell.conf" "$PREFLIGHT_DIR/disable-x11-bell.conf"

# Build an argument for every non-hidden top-level package directory. This is
# equivalent to running `stow */` inside the checkout, while making the source
# and target directories explicit.
set --
for package_dir in "$DOTFILES_DIR"/*/; do
  [ -d "$package_dir" ] || continue
  package_path=${package_dir%/}

  if [ -L "$package_path" ]; then
    echo "refusing symlinked Stow package: $package_path" >&2
    exit 1
  fi

  package=${package_path##*/}
  case "$package" in
  -*)
    echo "invalid Stow package name (looks like an option): $package" >&2
    exit 1
    ;;
  esac

  set -- "$@" "$package"
done

[ "$#" -gt 0 ] || {
  echo "no Stow packages found in $DOTFILES_DIR" >&2
  exit 1
}

echo "==> Checking dotfiles for conflicts"
run_as_user stow --simulate --verbose=2 --dir="$DOTFILES_DIR" --target="$USER_HOME" "$@"

echo "==> Stowing dotfiles into $USER_HOME"
run_as_user stow --dir="$DOTFILES_DIR" --target="$USER_HOME" "$@"

SWAY_CONFIG="$USER_HOME/.config/sway/config"
AUDIO_START="$USER_HOME/.config/sway/scripts/start-audio.sh"

if ! grep -q 'scripts/start-audio.sh' "$SWAY_CONFIG" 2>/dev/null; then
  echo "warning: $SWAY_CONFIG does not start scripts/start-audio.sh" >&2
fi

if [ ! -x "$AUDIO_START" ]; then
  echo "warning: $AUDIO_START is missing or not executable" >&2
fi

echo "==> Configuring system services"

# Logging and session services.
sudo xbps-install -Sy socklog-void dbus elogind polkit

enable_service socklog-unix
enable_service nanoklogd
sudo usermod -aG socklog "$REAL_USER"

# D-Bus must start before elogind.
enable_service dbus
enable_service elogind
sudo usermod -aG video "$REAL_USER"

sudo udevadm control --reload-rules
sudo udevadm trigger
enable_service polkitd

# Power management. Keep TLP's power-saver profile active on both AC and
# battery; the runit service reapplies it at boot and on power-source changes.
sudo xbps-install -Sy tlp
ensure_root_directory /etc/tlp.d
install_root_file_if_absent /etc/tlp.d/99-power-saver.conf "$PREFLIGHT_DIR/tlp.conf"
enable_service tlp
sudo tlp power-saver

# ALSA state and Bluetooth.
enable_service alsa
sudo usermod -aG bluetooth "$REAL_USER"
sudo rfkill unblock bluetooth || true
enable_service bluetoothd

# Route ALSA clients through PipeWire without replacing existing state.
ensure_root_directory /etc/alsa
ensure_root_directory /etc/alsa/conf.d
install_root_link_if_absent /etc/alsa/conf.d/50-pipewire.conf /usr/share/alsa/alsa.conf.d/50-pipewire.conf
install_root_link_if_absent /etc/alsa/conf.d/99-pipewire-default.conf /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf

# Managed-content templates are no longer needed. Remove them before replacing
# the cleanup trap with the wireless rollback trap.
cleanup_preflight
trap - EXIT

echo "==> Replacing wpa_supplicant with iwd"

# Install and prove DHCP readiness before touching the current wireless daemon.
sudo xbps-install -Sy iwd dhcpcd
enable_service dhcpcd

[ -d /var/service/iwd ] && IWD_WAS_ENABLED=true
[ -d /var/service/wpa_supplicant ] && WPA_SUPPLICANT_WAS_ENABLED=true
IWD_ROLLBACK_REQUIRED=true
trap restore_wireless_on_exit EXIT

if service_is_enabled wpa_supplicant; then
  sudo sv down wpa_supplicant || true
  sudo rm -f /var/service/wpa_supplicant
fi

if ! enable_service iwd; then
  echo "error: iwd did not become ready" >&2
  exit 1
fi

sudo sv status /var/service/iwd
sudo sv status /var/service/dhcpcd

IWD_ROLLBACK_REQUIRED=false
trap - EXIT

echo "iwd is enabled. List adapters with: sudo iwctl device list"
echo "Connect with: sudo iwctl station <device> connect <SSID>"

echo "setup complete"
echo "reboot, then log in on tty1 to start Sway"
echo "check the session with: loginctl session-status"
echo "check audio with: wpctl status"
echo "read logs with: svlogtail"
