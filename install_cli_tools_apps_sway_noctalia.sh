#!/bin/sh

# Install an Intel Sway/Noctalia desktop with elogind and multimedia.
# Do not combine this setup with seatd or turnstile.

set -eu

REAL_USER="${SUDO_USER:-$(id -un)}"
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

[ -n "$USER_HOME" ] || {
  echo "cannot resolve home directory for $REAL_USER" >&2
  exit 1
}

run_as_user() {
  if [ "$(id -u)" -eq 0 ] && [ "$REAL_USER" != root ]; then
    sudo -u "$REAL_USER" env HOME="$USER_HOME" "$@"
  else
    HOME="$USER_HOME" "$@"
  fi
}

enable_service() {
  service_name=$1
  sudo ln -sfn "/etc/sv/$service_name" /var/service/

  i=0
  while [ "$i" -lt 10 ]; do
    if sudo sv check "$service_name" >/dev/null 2>&1; then
      sudo sv status "$service_name" ||
        echo "warning: $service_name stopped unexpectedly" >&2
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done

  sudo sv status "$service_name" ||
    echo "warning: $service_name did not come up" >&2
}

# Update XBPS.
sudo xbps-install -Syu xbps
sudo xbps-install -Syu

# Enable official nonfree and multilib repositories.
sudo xbps-install -Sy \
  void-repo-nonfree void-repo-multilib \
  void-repo-multilib-nonfree
sudo xbps-install -Syu

# Enable the Voiders repository for Noctalia and Bibata.
printf '%s\n' 'repository=https://repo.voiders.dev' |
  sudo tee /etc/xbps.d/10-voiders-community.conf >/dev/null
yes | sudo xbps-install -Sy

# Intel graphics.
sudo xbps-install -Sy \
  linux-firmware-intel mesa-dri vulkan-loader \
  mesa-vulkan-intel intel-video-accel intel-media-driver

# Portals and user directories.
sudo xbps-install -Sy \
  xdg-desktop-portal xdg-desktop-portal-wlr \
  xdg-desktop-portal-gtk xdg-utils \
  xdg-user-dirs xdg-user-dirs-gtk
run_as_user xdg-user-dirs-update

# Fonts.
sudo xbps-install -Sy \
  font-hack-ttf nerd-fonts-symbols-ttf \
  dejavu-fonts-ttf noto-fonts-emoji noto-fonts-ttf

# Desktop apps and CLI tools.
sudo xbps-install -Sy \
  ddcutil kitty Thunar thunar-volman \
  thunar-archive-plugin thunar-media-tags-plugin \
  nodejs delta git eza bash-completion stow \
  neovide shikane alacritty gvfs wmenu vim \
  playerctl libnotify grim slurp grimshot satty \
  flameshot btop fastfetch brightnessctl base-devel \
  wl-clipboard sway foot firefox vlc xtools vsv \
  lazygit neovim ghostty rsync yazi bat upower \
  ffmpeg 7zip unzip zip jq poppler fd ripgrep \
  fzf zoxide resvg ImageMagick noctalia bibata-modern-ice

# Audio and Bluetooth; elogind supplies device ACLs instead of an audio group.
sudo xbps-install -Sy \
  bluez alsa-utils alsa-pipewire alsa-pipewire-32bit \
  libjack-pipewire libspa-bluetooth pipewire \
  wireplumber wireplumber-elogind

# Keep Vim's alternatives on Vim.
sudo xbps-alternatives -s vim -g vim

# Logging and session services.
sudo xbps-install -Sy socklog-void dbus elogind xfce-polkit

enable_service socklog-unix
enable_service nanoklogd
sudo usermod -aG socklog "$REAL_USER"

# D-Bus must start before elogind.
enable_service dbus
enable_service elogind
sudo usermod -aG video "$REAL_USER"

if ! grep -q 'pam_elogind.so' /etc/pam.d/system-login; then
  echo "warning: pam_elogind.so is missing from /etc/pam.d/system-login" >&2
  echo "add: -session optional pam_elogind.so" >&2
fi

sudo udevadm control --reload-rules
sudo udevadm trigger
enable_service polkitd

# Power management.
sudo xbps-install -Sy tlp
sudo ln -sfn /etc/sv/tlp /var/service/

# ALSA state and Bluetooth.
enable_service alsa
sudo usermod -aG bluetooth "$REAL_USER"
sudo rfkill unblock bluetooth || true
enable_service bluetoothd

# Prepare user directories for stow.
run_as_user mkdir -p \
  "$USER_HOME/.config" \
  "$USER_HOME/.local/share" \
  "$USER_HOME/.local/state" \
  "$USER_HOME/.local/bin" \
  "$USER_HOME/Pictures/Screenshots" \
  "$USER_HOME/Pictures/Wallpapers"

# Back up dotfiles that conflict with stow.
BACKUP_DIR="$USER_HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"

for name in .bashrc .bash_profile .inputrc .vimrc; do
  target="$USER_HOME/$name"

  [ -f "$target" ] || continue
  [ -L "$target" ] && continue

  run_as_user mkdir -p "$BACKUP_DIR"
  run_as_user mv "$target" "$BACKUP_DIR/$name"
  echo "backup: $BACKUP_DIR/$name"
done

# Sway starts PipeWire; these drop-ins start its session services.
PIPEWIRE_DIR="$USER_HOME/.config/pipewire/pipewire.conf.d"
run_as_user mkdir -p "$PIPEWIRE_DIR"
run_as_user ln -sfn \
  /usr/share/examples/wireplumber/10-wireplumber.conf \
  "$PIPEWIRE_DIR/10-wireplumber.conf"
run_as_user ln -sfn \
  /usr/share/examples/pipewire/20-pipewire-pulse.conf \
  "$PIPEWIRE_DIR/20-pipewire-pulse.conf"

# Route ALSA clients through PipeWire.
sudo mkdir -p /etc/alsa/conf.d
sudo ln -sfn \
  /usr/share/alsa/alsa.conf.d/50-pipewire.conf \
  /etc/alsa/conf.d/50-pipewire.conf
sudo ln -sfn \
  /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf \
  /etc/alsa/conf.d/99-pipewire-default.conf

SWAY_CONFIG="$USER_HOME/.config/sway/config"
AUDIO_START="$USER_HOME/.config/sway/scripts/start-audio.sh"

if ! grep -q 'scripts/start-audio.sh' "$SWAY_CONFIG" 2>/dev/null; then
  echo "warning: $SWAY_CONFIG does not start scripts/start-audio.sh" >&2
fi

if [ ! -x "$AUDIO_START" ]; then
  echo "warning: $AUDIO_START is missing or not executable" >&2
fi

echo "setup complete"
echo "log out and back in, then start Sway"
echo "check the session with: loginctl session-status"
echo "check audio with: wpctl status"
echo "read logs with: svlogtail"
