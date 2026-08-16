#!/bin/sh

# Void install, part 2 of 3: user environment. Run after the reboot that
# follows elogind_1_cli_tools_apps_sway_noctalia_install.sh.

set -eu

# Variable definition
REAL_USER="${SUDO_USER:-$(id -un)}"
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

[ -n "$USER_HOME" ] || { echo "cannot resolve home directory for $REAL_USER" >&2; exit 1; }

#####################################################################

# home dir various folder structure genereration
SCREENSHOT_DIR="$USER_HOME/Pictures/Screenshots"
mkdir -p "$SCREENSHOT_DIR"

#####################################################################

# Set ownership before writing anything into them.
mkdir -p "$USER_HOME/.config"
sudo chown -R "$REAL_USER:$REAL_USER" "$USER_HOME/.config"

#####################################################################

# Sanity check: the runtime directory is the one thing this variant gets for
# free and the one thing that silently breaks everything if it is missing.
# pam_elogind.so creates it at login, so it only appears after the reboot.
# Tested by path rather than by $XDG_RUNTIME_DIR, because sudo strips that from
# the environment and would give a false warning.
RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")"

if [ ! -d "$RUNTIME_DIR" ]; then
	echo "warning: $RUNTIME_DIR does not exist" >&2
	echo "pam_elogind.so creates it at login, so either the reboot after" >&2
	echo "script 1 has not happened yet, or elogind is not running" >&2
	echo "check with: sudo sv status elogind" >&2
fi

#####################################################################

# Copy configs from the repo into the user config directory. Each entry is
# "source in the repo:destination under ~/.config", spelled out on both sides
# because sway is the one config whose two names differ: the elogind variant
# ships sway/elogind_config and sway still wants to read it as "config".
# The first run keeps any pre-existing file as <name>.bak; later runs leave that
# backup alone so re-running never clobbers the original with a repo copy.
for pair in \
	"sway/elogind_config:sway/config" \
	"shikane/config.toml:shikane/config.toml" \
	"noctalia/settings.toml:noctalia/settings.toml" \
	"foot/foot.ini:foot/foot.ini" \
	"satty/config.toml:satty/config.toml" \
	"flameshot/flameshot.ini:flameshot/flameshot.ini" \
	"yazi/yazi.toml:yazi/yazi.toml" \
	"yazi/keymap.toml:yazi/keymap.toml" \
	"xdg-desktop-portal/portals.conf:xdg-desktop-portal/portals.conf"; do

	src="$SCRIPT_DIR/${pair%%:*}"
	dest="$USER_HOME/.config/${pair##*:}"
	dest_dir=$(dirname "$dest")

	[ -f "$src" ] || { echo "missing config source $src, skipping"; continue; }

	mkdir -p "$dest_dir"
	if [ -f "$dest" ] && [ ! -f "$dest.bak" ]; then
		cp "$dest" "$dest.bak"
	fi
	cp "$src" "$dest"

	echo "copied $src to $dest"
done

#####################################################################

# Define the target file
PROFILE_FILE="$USER_HOME/.bash_profile"

# Append the Sway startup logic safely
if grep -q 'exec dbus-run-session sway' "$PROFILE_FILE" 2>/dev/null; then
	echo "Sway startup script already present in $PROFILE_FILE"
else
	cat <<'EOF' >>"$PROFILE_FILE"

# sway autostart
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    export XDG_CURRENT_DESKTOP=sway
    export XDG_SESSION_DESKTOP=sway
    export XDG_SESSION_TYPE=wayland
    export QT_QPA_PLATFORM=wayland

    # elogind has no user service manager, so nothing has started a session bus
    # by this point. dbus-run-session starts one, exports its address and execs
    # sway inside it, which ties the bus to the session instead of to the boot.
    exec dbus-run-session sway
fi
EOF

	echo "Sway startup script added to $PROFILE_FILE"
fi

#####################################################################

# Define the target file
BASHRC_FILE="$USER_HOME/.bashrc"

# Append the Yazy wrapper script
if grep -q 'yazi-cwd' "$BASHRC_FILE" 2>/dev/null; then
	echo "Yazi wrapper script already present in $BASHRC_FILE"
else
	cat <<'EOF' >>"$BASHRC_FILE"

# yazi y() wrapper
# y shell wrapper that provides ability to change current working directory when exiting Yazi.
function y() {
	local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
	command yazi "$@" --cwd-file="$tmp"
	IFS= read -r -d '' cwd < "$tmp"
	[ "$cwd" != "$PWD" ] && [ -d "$cwd" ] && builtin cd -- "$cwd"
	command rm -f -- "$tmp"
}
EOF

	echo "Yazi wrapper script added to $BASHRC_FILE"
fi

#####################################################################

# Everything above may have been written as root when invoked through sudo, so
# hand the directories back to the user as the last step.
sudo chown -R "$REAL_USER:$REAL_USER" "$USER_HOME/.config" "$SCREENSHOT_DIR"

echo "environment prepared, log out and back in to tty1 to start the session"