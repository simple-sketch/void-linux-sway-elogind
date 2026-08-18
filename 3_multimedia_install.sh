#!/bin/sh

# Void install, part 3 of 3: audio and bluetooth.
#
# elogind variant of 3_multimedia_install.sh. Two things differ:
#
#   pipewire starts from sway   elogind is a seat and session manager, not a
#                               service manager, so there is no user runsvdir to
#                               drop a run script into. The exec of
#                               sway/scripts/start-audio.sh lives in
#                               sway/elogind_config, which script 2 deploys, so
#                               this script only sets up what that exec needs
#   no audio group              elogind's 70-uaccess.rules put an ACL for the
#                               active session's user on /dev/snd/*, which is
#                               the mechanism the audio group stands in for when
#                               there is no logind
#
# Run after elogind_2_after_restart_env_prepare.sh.

set -eu

# Variable definition
REAL_USER="${SUDO_USER:-$(id -un)}"
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

[ -n "$USER_HOME" ] || { echo "cannot resolve home directory for $REAL_USER" >&2; exit 1; }

#####################################################################

# https://docs.voidlinux.org/config/media/index.html
# https://docs.voidlinux.org/config/media/alsa.html
# https://docs.voidlinux.org/config/media/pipewire.html
# alsa-pipewire routes raw ALSA clients through pipewire, the 32bit variant does
# the same for steam and wine, libjack-pipewire provides pw-jack.
sudo xbps-install -Sy bluez alsa-utils alsa-pipewire alsa-pipewire-32bit libjack-pipewire libspa-bluetooth pipewire wireplumber

# wireplumber's shipped config references a logind module that only exists in
# this subpackage. With it, wireplumber follows session state and lets go of the
# devices when the session goes inactive, for example on a VT switch. Without
# it, wireplumber logs a missing module on every start.
sudo xbps-install -Sy wireplumber-elogind

#####################################################################

# No usermod -aG audio here, unlike the seatd/turnstile variant. Under elogind
# the active session's user gets an ACL on the sound devices from
# /usr/lib/udev/rules.d/70-uaccess.rules, so the group is redundant. Check it
# after logging in with: getfacl /dev/snd/controlC0
#
# video and input are handled in script 1, and only for brightnessctl's sysfs
# rule, not for anything pipewire needs.

#####################################################################

# the alsa service saves mixer levels on shutdown and restores them on boot
sudo ln -sfn /etc/sv/alsa /var/service/

# wait for runsvdir to pick the service up instead of guessing at a sleep
i=0
while [ "$i" -lt 10 ]; do
	sudo sv check alsa >/dev/null 2>&1 && break
	i=$((i + 1))
	sleep 1
done

sudo sv status alsa || echo "warning: alsa did not come up" >&2

#####################################################################

# These drop-ins are context.exec stanzas, they make a single pipewire process
# launch wireplumber and pipewire-pulse as children.
# https://docs.voidlinux.org/config/media/pipewire.html
mkdir -p "$USER_HOME/.config/pipewire/pipewire.conf.d"
ln -sfn /usr/share/examples/wireplumber/10-wireplumber.conf "$USER_HOME/.config/pipewire/pipewire.conf.d/"
ln -sfn /usr/share/examples/pipewire/20-pipewire-pulse.conf "$USER_HOME/.config/pipewire/pipewire.conf.d/"

echo "wireplumber and pipewire-pulse drop-ins linked into $USER_HOME/.config/pipewire/pipewire.conf.d"

#####################################################################

# Make raw ALSA clients play through pipewire instead of grabbing the card
# exclusively. Both files ship with alsa-pipewire.
sudo mkdir -p /etc/alsa/conf.d
sudo ln -sfn /usr/share/alsa/alsa.conf.d/50-pipewire.conf /etc/alsa/conf.d/
sudo ln -sfn /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf /etc/alsa/conf.d/

echo "alsa clients routed through pipewire via /etc/alsa/conf.d"

#####################################################################

# pipewire itself is started by sway/scripts/start-audio.sh, exec'd from
# sway/elogind_config, not by anything here. That single exec is enough because
# of the context.exec drop-ins above: wireplumber and pipewire-pulse come up as
# its children. It has to be started from inside sway rather than from
# .bash_profile so that it inherits DBUS_SESSION_BUS_ADDRESS from
# dbus-run-session and WAYLAND_DISPLAY from sway.
#
# That script pkills any pipewire and wireplumber left over from an earlier sway
# session before starting its own. sway does not kill what it execs, so without
# the reap a second login without a reboot leaves two of each on one graph, and
# two wireplumbers is enough to break bluetooth audio: the stale one keeps the
# bluez media endpoints it registered with bluetoothd, wins the A2DP handshake
# and then answers on a session bus that no longer exists, so the headset
# connects with no output sink and only its mic shows up.
#
# Tradeoff against the turnstile variant, which supervises pipewire with runit:
# nothing restarts this on crash. If audio disappears, restart it by hand with
#   ~/.config/sway/scripts/start-audio.sh &
# A sway reload will not do it, "exec" only runs at session start.
SWAY_CONFIG="$USER_HOME/.config/sway/config"
AUDIO_START="$USER_HOME/.config/sway/scripts/start-audio.sh"

if ! grep -q 'scripts/start-audio.sh' "$SWAY_CONFIG" 2>/dev/null; then
	echo "warning: nothing execs scripts/start-audio.sh in $SWAY_CONFIG" >&2
	echo "that line comes from sway/elogind_config, deployed by" >&2
	echo "elogind_2_after_restart_env_prepare.sh -- run it, or add the exec" >&2
	echo "by hand, otherwise nothing starts pipewire with the session" >&2
fi

if [ ! -x "$AUDIO_START" ]; then
	echo "warning: $AUDIO_START is missing or not executable" >&2
	echo "it ships in the sway dotfiles package that script 2 links into" >&2
	echo "place -- without it the exec in the sway config starts nothing" >&2
fi

sudo chown -R "$REAL_USER:$REAL_USER" "$USER_HOME/.config"

#####################################################################

# Bluetooth audio. libspa-bluetooth above is the pipewire side of it, do not
# install bluez-alsa, that is for ALSA-only setups and conflicts with it.
# https://docs.voidlinux.org/config/bluetooth.html
sudo ln -sfn /etc/sv/bluetoothd /var/service/
sudo usermod -aG bluetooth "$REAL_USER"
sudo rfkill unblock bluetooth || true

# wait for runsvdir to pick the service up instead of guessing at a sleep
i=0
while [ "$i" -lt 10 ]; do
	sudo sv check bluetoothd >/dev/null 2>&1 && break
	i=$((i + 1))
	sleep 1
done

sudo sv status bluetoothd || echo "warning: bluetoothd did not come up" >&2

#####################################################################

echo "multimedia setup done"
echo "log out and back in, pipewire only starts when sway does"
echo "then check with: pgrep -a pipewire"
echo "and: wpctl status"