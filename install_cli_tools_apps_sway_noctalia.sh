#!/bin/sh

# Void install, part 1, standalone variant: packages, graphics, session and seat
# management, plus the home directory scaffolding that makes a hand-run stow work.
#
# This is 1_cli_tools_apps_sway_noctalia_install.sh with the useful half of
# 2_after_restart_env_prepare.sh folded in. Run this one instead of that pair if
# you clone the dotfiles repo and stow it yourself:
#
#   sh 1_alt_cli_tools_apps_sway_noctalia_install.sh
#   reboot
#   git clone https://github.com/simple-sketch/dotfiles ~/dotfiles
#   cd ~/dotfiles && stow */
#
# Run one of the two variants, never both. They install the same packages, so
# the second run would be a long no-op rather than a disaster, but a package
# added to one and not the other is how they drift apart.
#
# What is folded in from script 2, and why each part has to happen before the
# stow rather than after:
#
#   ~/.config exists    given a missing ~/.config, stow does not create the
#                       directory, it "folds" and makes ~/.config itself a
#                       symlink into whichever package it saw first. Every
#                       program on the machine then writes its config into the
#                       dotfiles repo, and unstowing that one package takes the
#                       whole directory with it
#   skel files moved    /etc/skel puts a real .bashrc, .bash_profile and
#                       .inputrc in every new home. stow will not overwrite a
#                       file it does not own, and it aborts the *entire* run on
#                       the first conflict, so those three block all twelve
#                       packages until they are out of the way
#   git installed       needed to clone the dotfiles repo, and it is not pulled
#                       in by base-devel on Void
#
# Everything else script 2 did is either gone (it used to copy configs that now
# live in the dotfiles repo) or is a check you can run by hand after the reboot,
# see the closing message.
#
#
# elogind variant. Where the seatd scripts build the session out of seatd +
# turnstile, this one installs elogind, which covers all three of their jobs at
# once:
#
#   seat management   sway pulls in wlroots -> libseat, and Void's libseat is
#                     linked against libelogind, so with elogind running it uses
#                     the logind backend and no seatd daemon is needed. The
#                     seatd package ships only the daemon, not the library, so
#                     it is never installed here and its service stays disabled
#   XDG_RUNTIME_DIR   pam_elogind.so is already listed in
#                     /etc/pam.d/system-login on Void, it creates /run/user/$UID
#                     at login, which is the only reason turnstile was there
#   power management  loginctl poweroff/reboot/suspend are authorised by polkit
#                     for the active local session, so the /etc/sudoers.d
#                     NOPASSWD workaround from the other variant is not needed
#
# Written for a plain Void base image. Pick one variant per machine, the elogind
# scripts or the seatd/turnstile ones, never both: Void's /etc/pam.d/system-login
# carries pam_turnstile.so and pam_elogind.so in the same session stack, each
# prefixed with "-" so it is skipped while its package is absent, and installing
# both means two things racing to own the session.

set -eu

REAL_USER="${SUDO_USER:-$(id -un)}"

# Not $HOME: under sudo that is /root, and the directories below have to be
# created in the home of the user who will actually log in.
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
[ -n "$USER_HOME" ] || {
  echo "cannot resolve home directory for $REAL_USER" >&2
  exit 1
}

# https://docs.voidlinux.org/xbps/index.html#updating
sudo xbps-install -Syu xbps
sudo xbps-install -Syu

# https://docs.voidlinux.org/xbps/repositories/index.html#nonfree
sudo xbps-install -Sy void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree
sudo xbps-install -Syu

# https://docs.voidlinux.org/config/graphical-session/graphics-drivers/intel.html
sudo xbps-install -Sy linux-firmware-intel mesa-dri vulkan-loader mesa-vulkan-intel intel-video-accel intel-media-driver

# https://docs.voidlinux.org/config/graphical-session/portals.html
sudo xbps-install -Sy xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk xdg-utils

# auto XDG dir generation
sudo xbps-install -Sy xdg-user-dirs xdg-user-dirs-gtk
xdg-user-dirs-update

# https://docs.voidlinux.org/config/graphical-session/fonts.html
sudo xbps-install -Sy dejavu-fonts-ttf noto-fonts-emoji noto-fonts-ttf

# Useful apps and cli tools. git and stow are what the manual dotfiles step
# needs: git is not a base-devel dependency on Void, so it is named explicitly.
sudo xbps-install -Sy kitty Thunar thunar-volman thunar-archive-plugin thunar-media-tags-plugin nodejs delta git eza bash-completion stow neovide shikane alacritty gvfs wmenu vim playerctl libnotify grim slurp grimshot satty flameshot btop fastfetch brightnessctl base-devel wl-clipboard sway foot firefox vlc xtools vsv lazygit neovim ghostty rsync yazi bat upower ffmpeg 7zip unzip zip jq poppler fd ripgrep fzf zoxide resvg ImageMagick

# Switch the vim alternatives group from the neovim provider to the vim provider. So that they run own separate commands
sudo xbps-alternatives -s vim -g vim

####################################################################################################################################################################################################

# https://docs.voidlinux.org/config/services/logging.html
sudo xbps-install -Sy socklog-void

sudo ln -sfn /etc/sv/socklog-unix /var/service/
sudo ln -sfn /etc/sv/nanoklogd /var/service/

# wait for runsvdir to pick the services up instead of guessing at a sleep
i=0
while [ "$i" -lt 10 ]; do
  sudo sv check socklog-unix >/dev/null 2>&1 &&
    sudo sv check nanoklogd >/dev/null 2>&1 && break
  i=$((i + 1))
  sleep 1
done

sudo sv status socklog-unix || echo "warning: socklog-unix did not come up" >&2
sudo sv status nanoklogd || echo "warning: nanoklogd did not come up" >&2

# reading logs is limited to root and members of the socklog group
sudo usermod -aG socklog "$REAL_USER"

echo "socklog logging enabled, logs are under /var/log/socklog"
echo "log out and back in for the socklog group to apply, then read logs with svlogtail"

####################################################################################################################################################################################################

# D-Bus. Installed and started before elogind because /etc/sv/elogind/run does
# "sv check dbus || exit 1", and elogind's login1 interface lives on the system
# bus anyway.
#
# Plain "dbus", not "dbus-elogind": older elogind guides tell you to swap in
# dbus-elogind and polkit-elogind, but on current Void both are transitional
# dummy packages. The normal ones are built with elogind support already.
sudo xbps-install -Sy dbus
sudo ln -sfn /etc/sv/dbus /var/service/

# wait for runsvdir to pick the service up instead of guessing at a sleep
i=0
while [ "$i" -lt 10 ]; do
  sudo sv check dbus >/dev/null 2>&1 && break
  i=$((i + 1))
  sleep 1
done

sudo sv status dbus || echo "warning: dbus did not come up" >&2

# Session, seat and power management. Replaces seatd + turnstile + the sudoers
# power workaround of the other variant.
# https://docs.voidlinux.org/config/session-management.html
#
# elogind also ships a D-Bus activation file (org.freedesktop.login1.service),
# so the first loginctl call would start it on demand. The service is enabled
# anyway: power key and lid handling have to be live from boot, before anything
# touches the bus, and pam_elogind needs it at login to create the session.
sudo xbps-install -Sy elogind
sudo ln -sfn /etc/sv/elogind /var/service/

# wait for runsvdir to pick the service up instead of guessing at a sleep
i=0
while [ "$i" -lt 10 ]; do
  sudo sv check elogind >/dev/null 2>&1 && break
  i=$((i + 1))
  sleep 1
done

sudo usermod -aG video "$REAL_USER"
#sudo usermod -aG input "$REAL_USER"

sudo sv status elogind || echo "warning: elogind did not come up" >&2

# Void's pam-base already lists pam_elogind.so in the login stack, prefixed with
# "-" so it is skipped without complaint while elogind is not installed. Now
# that it is, that line is what registers the session and creates
# /run/user/$UID. Nothing else in this setup does, so check rather than assume.
if ! grep -q 'pam_elogind.so' /etc/pam.d/system-login; then
  echo "warning: pam_elogind.so is missing from /etc/pam.d/system-login" >&2
  echo "without it there is no XDG_RUNTIME_DIR and no registered session" >&2
  echo "add: -session   optional   pam_elogind.so" >&2
fi

# elogind ships udev rules (70-uaccess, 71-seat, 73-seat-late, 70-power-switch)
# that assign devices to seats and hand the active session ACLs on /dev/dri,
# /dev/snd and input devices. Load them now so the first boot after this is
# already correct.
sudo udevadm control --reload-rules
sudo udevadm trigger

# polkit is what turns "the user has an active local session" into permission to
# call loginctl poweroff/reboot/suspend. Without it those calls fail for anyone
# but root.
sudo ln -sfn /etc/sv/polkitd /var/service/

# wait for runsvdir to pick the service up instead of guessing at a sleep
i=0
while [ "$i" -lt 10 ]; do
  sudo sv check polkitd >/dev/null 2>&1 && break
  i=$((i + 1))
  sleep 1
done

sudo sv status polkitd || echo "warning: polkitd did not come up" >&2

# A polkit *agent* is a separate thing from polkitd, it is the GUI that prompts
# for a password when a request needs one. GTK based, to match Thunar and gvfs.
# Started from sway, see the exec in the dotfiles sway config.
sudo xbps-install -Sy xfce-polkit

echo "elogind, polkit and dbus enabled"
echo "after reboot, check with: loginctl session-status"

####################################################################################################################################################################################################

# Noctalia install
# 1. Add the repo config
echo "repository=https://repo.voiders.dev" | sudo tee /etc/xbps.d/10-voiders-community.conf
# 2. Sync + import key without prompting
yes | sudo xbps-install -Sy
# 3. Install noctalia  package
sudo xbps-install -Sy noctalia

####################################################################################################################################################################################################

# tlp service install and  run
sudo xbps-install -Sy tlp
sudo ln -sfn /etc/sv/tlp /var/service/

####################################################################################################################################################################################################

#sudo xbps-install -S zramen
#sudo ln -sfn /etc/sv/zramen /var/service/

####################################################################################################################################################################################################

# Home directory scaffolding for the manual stow.
#
# These directories are created rather than left to stow because an existing
# directory is what makes stow descend into it and link the files inside. A
# missing one makes it fold instead, replacing the directory with a symlink to
# a single package. ~/.config is the one that matters most, ~/.local/state is
# where .bash_profile writes sway.log, and Screenshots is what the flameshot and
# grim bindings save into.
#
# One level down is a different matter: ~/.config/sway is *meant* to become a
# symlink to the sway package, and it does, because it does not exist yet.
for dir in \
  "$USER_HOME/.config" \
  "$USER_HOME/.local/share" \
  "$USER_HOME/.local/state" \
  "$USER_HOME/.local/bin" \
  "$USER_HOME/Pictures/Screenshots"; do

  mkdir -p "$dir"
done

# Under sudo everything above belongs to root, including any parent that had to
# be created. Hand it back before stow, which runs as the user, has to write
# into it.
if [ "$(id -u)" -eq 0 ]; then
  chown -R "$REAL_USER" "$USER_HOME/.config" "$USER_HOME/.local" "$USER_HOME/Pictures"
fi

####################################################################################################################################################################################################

# Move the /etc/skel copies out of the way.
#
# stow refuses to overwrite a regular file it does not own, and it aborts the
# whole run on the first conflict rather than stowing the packages that would
# have worked. On a fresh Void home that is three files against twelve packages,
# so `stow */` fails having linked nothing until these are gone.
#
# Moved, never deleted, and only if they are regular files: a symlink here is
# already stowed, which is the state a second run of this script finds.
BACKUP_DIR="$USER_HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"

for name in .bashrc .bash_profile .inputrc .vimrc; do
  target="$USER_HOME/$name"

  [ -f "$target" ] || continue # -f follows symlinks, so also skips a
  [ -L "$target" ] && continue # link that resolves to a real file

  mkdir -p "$BACKUP_DIR"
  mv "$target" "$BACKUP_DIR/$name"
  echo "moved $target out of stow's way, kept at $BACKUP_DIR/$name"
done

if [ -d "$BACKUP_DIR" ] && [ "$(id -u)" -eq 0 ]; then
  chown -R "$REAL_USER" "$USER_HOME/.dotfiles-backup"
fi

####################################################################################################################################################################################################

cat <<EOF

PLEASE RESTART THE SYSTEM, THEN:

  git clone https://github.com/simple-sketch/dotfiles ~/dotfiles
  cd ~/dotfiles && stow */

"stow */" and not "stow .": with a bare dot stow treats the whole repo as one
package and links ~/bashrc -> dotfiles/bashrc, giving you no ~/.bashrc and no
~/.config links at all. The trailing slash on the glob is what keeps .git out.

Then log out and back in to tty1, .bash_profile starts sway from there.

Worth checking after the reboot, in this order, each explains the next failure:

  loginctl session-status         the session is registered and active
  ls -d /run/user/\$(id -u)        pam_elogind created XDG_RUNTIME_DIR
  ls -l ~/.bashrc                 points into ~/dotfiles
  less ~/.local/state/sway.log    only exists once sway has been started once
EOF
