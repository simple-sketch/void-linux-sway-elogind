#!/bin/sh

# Void install, part 1 of 3: packages, graphics, session and seat management.
#
# elogind variant of 1_cli_tools_apps_sway_noctalia_install.sh. Where that
# script builds the session out of seatd + turnstile, this one installs elogind,
# which covers all three of their jobs at once:
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
# Written for a plain Void base image. Pick one variant per machine, the
# elogind_* scripts or the numbered seatd/turnstile ones, never both: Void's
# /etc/pam.d/system-login carries pam_turnstile.so and pam_elogind.so in the
# same session stack, each prefixed with "-" so it is skipped while its package
# is absent, and installing both means two things racing to own the session.
#
# Reboot when this finishes, then run elogind_2_after_restart_env_prepare.sh.

set -eu

REAL_USER="${SUDO_USER:-$(id -un)}"

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
sudo xbps-install -Sy dejavu-fonts-ttf

# Useful apps and cli tools
sudo xbps-install -Sy eza bash-completion stow neovide shikane qt6-wayland alacritty nwg-look gvfs wmenu vim Thunar playerctl libnotify grim slurp grimshot satty flameshot btop fastfetch brightnessctl base-devel wl-clipboard sway foot firefox xtools vsv lazygit neovim ghostty rsync yazi bat upower ffmpeg 7zip unzip zip jq poppler fd ripgrep fzf zoxide resvg ImageMagick

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
sudo xbps-install -Sy polkit
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
# Started from sway, see the exec in sway/elogind_config.
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

# install flatpak and add flathub repo
sudo xbps-install -Sy flatpak
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

####################################################################################################################################################################################################

# tlp service run and set to power-saver
sudo xbps-install -Sy tlp
sudo ln -sfn /etc/sv/tlp /var/service/
sudo tlp power-saver

# automounter. Thunar mounting removable media needs no password because polkit
# grants udisks2 actions to the active local session, which is exactly what
# elogind is there to establish.
#
# No /var/service symlink: the udisks2 package ships no /etc/sv/udisks2, it is
# started on demand through /usr/share/dbus-1/system-services/org.freedesktop.UDisks2.service.
# Linking one anyway leaves a dangling symlink that runsvdir complains about on
# every scan.
sudo xbps-install -Sy udisks2

####################################################################################################################################################################################################

# Device access under elogind comes from the uaccess udev rules above, not from
# group membership, so no audio group here. video and input are the exception:
# brightnessctl has no logind support in the Void build, it writes sysfs
# directly, and /usr/lib/udev/rules.d/90-brightnessctl.rules chgrps
# /sys/class/backlight/*/brightness to video and /sys/class/leds/*/brightness to
# input.
sudo usermod -aG video "$REAL_USER"

#sudo usermod -aG input "$REAL_USER"

####################################################################################################################################################################################################

echo "PLEASE RESTART SYSTEM AND AFTER THAT RUN ENV PREPARE SCRIPT"
