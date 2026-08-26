#!/bin/sh

# Install CLI tools and desktop apps for an elogind-based Sway session on
# Void Linux. Target: a plain installation with Intel graphics.
# This script also prepares the user's home directory for GNU stow.
# Do not combine this setup with seatd/turnstile.

set -eu

REAL_USER="${SUDO_USER:-$(id -un)}"

# Resolve the login user's home; sudo may set HOME to /root.
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
[ -n "$USER_HOME" ] || {
  echo "cannot resolve home directory for $REAL_USER" >&2
  exit 1
}

# Update XBPS.
# https://docs.voidlinux.org/xbps/index.html#updating
sudo xbps-install -Syu xbps
sudo xbps-install -Syu

# Enable official nonfree and multilib repositories.
# https://docs.voidlinux.org/xbps/repositories/index.html#nonfree
sudo xbps-install -Sy \
  void-repo-nonfree void-repo-multilib \
  void-repo-multilib-nonfree
sudo xbps-install -Syu

# Intel graphics stack.
# https://docs.voidlinux.org/config/graphical-session/graphics-drivers/intel.html
sudo xbps-install -Sy \
  linux-firmware-intel mesa-dri vulkan-loader \
  mesa-vulkan-intel intel-video-accel \
  intel-media-driver

# Desktop portals and utilities.
# https://docs.voidlinux.org/config/graphical-session/portals.html
sudo xbps-install -Sy \
  xdg-desktop-portal xdg-desktop-portal-wlr \
  xdg-desktop-portal-gtk xdg-utils

# XDG user directories.
sudo xbps-install -Sy xdg-user-dirs xdg-user-dirs-gtk
xdg-user-dirs-update

# Fonts.
# https://docs.voidlinux.org/config/graphical-session/fonts.html
sudo xbps-install -Sy \
  font-hack-ttf nerd-fonts-symbols-ttf \
  dejavu-fonts-ttf noto-fonts-emoji \
  noto-fonts-ttf

# Desktop apps and CLI tools, including git and stow for dotfiles.
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
  fzf zoxide resvg ImageMagick

# Keep Vim's alternatives on Vim rather than Neovim.
sudo xbps-alternatives -s vim -g vim

# Logging
# https://docs.voidlinux.org/config/services/logging.html
sudo xbps-install -Sy socklog-void

sudo ln -sfn /etc/sv/socklog-unix /var/service/
sudo ln -sfn /etc/sv/nanoklogd /var/service/

# Wait up to 10 seconds for runsvdir.
i=0
while [ "$i" -lt 10 ]; do
  sudo sv check socklog-unix >/dev/null 2>&1 &&
    sudo sv check nanoklogd >/dev/null 2>&1 && break
  i=$((i + 1))
  sleep 1
done

sudo sv status socklog-unix ||
  echo "warning: socklog-unix did not come up" >&2
sudo sv status nanoklogd ||
  echo "warning: nanoklogd did not come up" >&2

# Grant the login user access to logs.
sudo usermod -aG socklog "$REAL_USER"

echo "socklog logging enabled"
echo "logs are under /var/log/socklog"
echo "log out and back in for the socklog group to apply"
echo "then read logs with svlogtail"

# D-Bus
# Start the system bus before elogind.
# Use current packages; legacy *-elogind packages are transitional.
sudo xbps-install -Sy dbus
sudo ln -sfn /etc/sv/dbus /var/service/

# Wait up to 10 seconds for runsvdir.
i=0
while [ "$i" -lt 10 ]; do
  sudo sv check dbus >/dev/null 2>&1 && break
  i=$((i + 1))
  sleep 1
done

sudo sv status dbus ||
  echo "warning: dbus did not come up" >&2

# Session, seat, and power management
# https://docs.voidlinux.org/config/session-management.html
# Enable elogind at boot for PAM sessions and hardware power events.
sudo xbps-install -Sy elogind
sudo ln -sfn /etc/sv/elogind /var/service/

# Wait up to 10 seconds for runsvdir.
i=0
while [ "$i" -lt 10 ]; do
  sudo sv check elogind >/dev/null 2>&1 && break
  i=$((i + 1))
  sleep 1
done

sudo usermod -aG video "$REAL_USER"

sudo sv status elogind ||
  echo "warning: elogind did not come up" >&2

# pam_elogind registers sessions and creates /run/user/$UID.
if ! grep -q 'pam_elogind.so' /etc/pam.d/system-login; then
  echo "warning: pam_elogind.so is missing from" >&2
  echo "  /etc/pam.d/system-login" >&2
  echo "without it there is no XDG_RUNTIME_DIR" >&2
  echo "and no registered session" >&2
  echo "add: -session   optional   pam_elogind.so" >&2
fi

# Apply elogind's seat and device-access rules now.
sudo udevadm control --reload-rules
sudo udevadm trigger

# Authorize power actions for active local sessions.
sudo ln -sfn /etc/sv/polkitd /var/service/

# Wait up to 10 seconds for runsvdir.
i=0
while [ "$i" -lt 10 ]; do
  sudo sv check polkitd >/dev/null 2>&1 && break
  i=$((i + 1))
  sleep 1
done

sudo sv status polkitd ||
  echo "warning: polkitd did not come up" >&2

# GTK authentication agent; started by the Sway config.
sudo xbps-install -Sy xfce-polkit

echo "elogind, polkit and dbus enabled"
echo "after reboot, check with: loginctl session-status"

# Voiders packages
# Enable the repository for Noctalia and Bibata.
echo "repository=https://repo.voiders.dev" |
  sudo tee /etc/xbps.d/10-voiders-community.conf
# Import the repository key during the initial sync.
yes | sudo xbps-install -Sy
sudo xbps-install -Sy noctalia bibata-modern-ice

# Power management
sudo xbps-install -Sy tlp
sudo ln -sfn /etc/sv/tlp /var/service/

# Home directory
# Create parent directories before stow to prevent directory folding.
for dir in \
  "$USER_HOME/.config" \
  "$USER_HOME/.local/share" \
  "$USER_HOME/.local/state" \
  "$USER_HOME/.local/bin" \
  "$USER_HOME/Pictures/Screenshots" \
  "$USER_HOME/Pictures/Wallpapers"; do

  mkdir -p "$dir"
done

# Restore ownership when invoked as root.
if [ "$(id -u)" -eq 0 ]; then
  chown -R "$REAL_USER" \
    "$USER_HOME/.config" \
    "$USER_HOME/.local" \
    "$USER_HOME/Pictures"
fi

# Back up regular skel dotfiles that would conflict with stow.
BACKUP_DIR="$USER_HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"

for name in .bashrc .bash_profile .inputrc .vimrc; do
  target="$USER_HOME/$name"

  [ -f "$target" ] || continue
  [ -L "$target" ] && continue # Preserve existing stow links.

  mkdir -p "$BACKUP_DIR"
  mv "$target" "$BACKUP_DIR/$name"
  echo "moved $target out of stow's way"
  echo "backup: $BACKUP_DIR/$name"
done

if [ -d "$BACKUP_DIR" ] && [ "$(id -u)" -eq 0 ]; then
  chown -R "$REAL_USER" "$USER_HOME/.dotfiles-backup"
fi
