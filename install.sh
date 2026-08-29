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

command -v sudo >/dev/null 2>&1 || {
  echo "sudo is required" >&2
  exit 1
}

# Authenticate before the first package transaction so a missing sudo setup
# cannot leave the machine half-configured.
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

  i=0
  while [ "$i" -lt "$SERVICE_START_TIMEOUT" ]; do
    if sudo sv check "$service_name" >/dev/null 2>&1; then
      sudo sv status "$service_name"
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done

  sudo sv status "$service_name" >&2 || true
  echo "error: $service_name did not become ready within ${SERVICE_START_TIMEOUT}s" >&2
  return 1
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

# Reject an unrelated directory before making system changes. Git itself is
# installed below, so the existing checkout's origin is checked afterward.
if [ -e "$DOTFILES_DIR" ] && [ ! -d "$DOTFILES_DIR/.git" ]; then
  echo "$DOTFILES_DIR already exists and is not a Git checkout" >&2
  exit 1
fi

echo "==> Updating XBPS and enabling repositories"

# Update XBPS.
sudo xbps-install -Syu xbps
sudo xbps-install -Syu

# Enable the Voiders repository for Noctalia and Bibata.
printf '%s\n' 'repository=https://repo.voiders.dev' | sudo tee /etc/xbps.d/10-voiders-community.conf >/dev/null
sudo xbps-install -Sy

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
sudo xbps-install -Sy perl-File-MimeInfo ripdrag shfmt shellcheck ddcutil kitty swayimg nodejs delta git eza bash-completion stow neovide shikane alacritty wmenu vim \
  playerctl libnotify grim slurp grimshot satty flameshot btop fastfetch brightnessctl base-devel \
  wl-clipboard sway foot firefox vlc xtools vsv lazygit neovim ghostty rsync yazi bat upower \
  ffmpeg 7zip unzip zip unrar jq poppler fd ripgrep fzf zoxide resvg ImageMagick noctalia bibata-modern-ice

# Audio and Bluetooth; elogind supplies device ACLs instead of an audio group.
sudo xbps-install -Sy bluez alsa-utils alsa-pipewire libjack-pipewire libspa-bluetooth pipewire wireplumber wireplumber-elogind

# Keep Vim's alternatives on Vim.
sudo xbps-alternatives -s vim -g vim

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

if ! grep -q 'pam_elogind.so' /etc/pam.d/system-login; then
  echo "error: pam_elogind.so is missing from /etc/pam.d/system-login" >&2
  echo "add '-session optional pam_elogind.so', then rerun the installer" >&2
  exit 1
fi

sudo udevadm control --reload-rules
sudo udevadm trigger
enable_service polkitd

# Power management. Keep TLP's power-saver profile active on both AC and
# battery; the runit service reapplies it at boot and on power-source changes.
sudo xbps-install -Sy tlp
sudo install -d -m 0755 /etc/tlp.d
sudo tee /etc/tlp.d/99-power-saver.conf >/dev/null <<'EOF'
# Managed by void-sway-noctalia-elogind/install.sh.
TLP_ENABLE=1
TLP_AUTO_SWITCH=1
TLP_PROFILE_AC=SAV
TLP_PROFILE_BAT=SAV
TLP_PROFILE_DEFAULT=SAV
EOF
enable_service tlp
sudo tlp power-saver

# ALSA state and Bluetooth.
enable_service alsa
sudo usermod -aG bluetooth "$REAL_USER"
sudo rfkill unblock bluetooth || true
enable_service bluetoothd

# Route ALSA clients through PipeWire.
sudo mkdir -p /etc/alsa/conf.d
sudo ln -sfn /usr/share/alsa/alsa.conf.d/50-pipewire.conf /etc/alsa/conf.d/50-pipewire.conf
sudo ln -sfn /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf /etc/alsa/conf.d/99-pipewire-default.conf

echo "==> Installing dotfiles for $REAL_USER"

USE_EXISTING_DOTFILES=false

if [ -d "$DOTFILES_DIR/.git" ]; then
  EXISTING_REPO=$(run_as_user git -C "$DOTFILES_DIR" remote get-url origin 2>/dev/null) || {
    echo "cannot read the origin for $DOTFILES_DIR" >&2
    exit 1
  }

  case "$EXISTING_REPO" in
  "$DOTFILES_REPO" | "$DOTFILES_REPO.git")
    USE_EXISTING_DOTFILES=true
    ;;
  *)
    echo "$DOTFILES_DIR has an unexpected origin: $EXISTING_REPO" >&2
    exit 1
    ;;
  esac
fi

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

# Back up files from /etc/skel that would otherwise conflict with Stow.
BACKUP_DIR="$USER_HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"

for name in .bashrc .bash_profile .inputrc .vimrc; do
  target="$USER_HOME/$name"

  [ -f "$target" ] || continue
  [ -L "$target" ] && continue

  run_as_user mkdir -p "$BACKUP_DIR"
  run_as_user mv "$target" "$BACKUP_DIR/$name"
  echo "backup: $BACKUP_DIR/$name"
done

# Sway starts PipeWire; these drop-ins start its session services and prevent
# the X11 bell module from keeping an otherwise-unused Xwayland process alive.
PIPEWIRE_DIR="$USER_HOME/.config/pipewire/pipewire.conf.d"
run_as_user mkdir -p "$PIPEWIRE_DIR"
run_as_user ln -sfn /usr/share/examples/wireplumber/10-wireplumber.conf "$PIPEWIRE_DIR/10-wireplumber.conf"
run_as_user ln -sfn /usr/share/examples/pipewire/20-pipewire-pulse.conf "$PIPEWIRE_DIR/20-pipewire-pulse.conf"
run_as_user tee "$PIPEWIRE_DIR/30-disable-x11-bell.conf" >/dev/null <<'EOF'
# Do not keep Xwayland alive solely to provide the legacy X11 bell.
context.properties = {
    module.x11.bell = false
}
EOF

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

echo "==> Replacing wpa_supplicant with iwd"

# The base installer normally provides dhcpcd for IP configuration and may use
# wpa_supplicant for the initial Wi-Fi connection. Keep dhcpcd for both Wi-Fi
# and ethernet; iwd is responsible only for wireless association.
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

if [ -e /var/service/iwd ] && [ ! -d /var/service/iwd ] && [ ! -L /var/service/iwd ]; then
  echo "cannot enable iwd: /var/service/iwd is not a service directory or symlink" >&2
  exit 1
fi

if [ -r "$IWD_CONFIG_FILE" ] &&
  grep -Eiq '^[[:space:]]*EnableNetworkConfiguration[[:space:]]*=[[:space:]]*true([[:space:]]|$)' "$IWD_CONFIG_FILE"; then
  echo "cannot combine dhcpcd with EnableNetworkConfiguration=true in $IWD_CONFIG_FILE" >&2
  echo "disable iwd network configuration before running this script" >&2
  exit 1
fi

# D-Bus was enabled above, and Void enables dhcpcd during base installation.
# Only install and switch the wireless daemon here.
sudo xbps-install -Sy iwd

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

sudo sv status iwd

IWD_ROLLBACK_REQUIRED=false
trap - EXIT

echo "iwd is enabled. List adapters with: sudo iwctl device list"
echo "Connect with: sudo iwctl station <device> connect <SSID>"

echo "==> Checking dotfiles for conflicts"
run_as_user stow --simulate --verbose=2 --dir="$DOTFILES_DIR" --target="$USER_HOME" "$@"

echo "==> Stowing dotfiles into $USER_HOME"
run_as_user stow --dir="$DOTFILES_DIR" --target="$USER_HOME" "$@"

echo "==> Setting default file handlers"
run_as_user xdg-mime default swayimg.desktop \
  image/avif \
  image/bmp \
  image/gif \
  image/heif \
  image/jpeg \
  image/jpg \
  image/jxl \
  image/pbm \
  image/pjpeg \
  image/png \
  image/svg+xml \
  image/tiff \
  image/webp \
  image/x-bmp \
  image/x-exr \
  image/x-png \
  image/x-portable-anymap \
  image/x-portable-bitmap \
  image/x-portable-graymap \
  image/x-portable-pixmap \
  image/x-targa \
  image/x-tga
run_as_user xdg-mime default yazi.desktop inode/directory

SWAY_CONFIG="$USER_HOME/.config/sway/config"
AUDIO_START="$USER_HOME/.config/sway/scripts/start-audio.sh"

if ! grep -q 'scripts/start-audio.sh' "$SWAY_CONFIG" 2>/dev/null; then
  echo "warning: $SWAY_CONFIG does not start scripts/start-audio.sh" >&2
fi

if [ ! -x "$AUDIO_START" ]; then
  echo "warning: $AUDIO_START is missing or not executable" >&2
fi

echo "setup complete"
echo "reboot, then log in on tty1 to start Sway"
echo "check the session with: loginctl session-status"
echo "check audio with: wpctl status"
echo "read logs with: svlogtail"
