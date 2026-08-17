#!/bin/sh

# Void install, part 2 of 3: user environment. Run after the reboot that
# follows 1_cli_tools_apps_sway_noctalia_install.sh.
#
# Configs are no longer copied out of this repo. They live in the separate
# dotfiles repo, laid out as GNU stow packages:
#
#   dotfiles/sway/.config/sway/config      ->  ~/.config/sway/config
#   dotfiles/bashrc/.bashrc                ->  ~/.bashrc
#
# so this script only has to clone that repo and let stow create the symlinks.
# Symlinks rather than copies means editing ~/.config/sway/config *is* editing
# the repo, and `git -C ~/dotfiles status` is the honest answer to "what have I
# changed since the install".
#
# Nothing here appends to ~/.bashrc or ~/.bash_profile any more. Those files are
# stow symlinks into the repo, so an append would write into the git working
# tree and duplicate what the repo copies already contain (the sway autostart
# block and the yazi y() wrapper are both in there).

set -eu

#####################################################################

# Checked before anything reads $HOME, because every path below is built from
# it. Under sudo it would be root's home, and every symlink stow created would
# end up root-owned in a directory the user cannot write.
if [ "$(id -u)" -eq 0 ]; then
	echo "run this as your normal user, not root and not with sudo" >&2
	exit 1
fi

if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
	echo "\$HOME is not set to a directory" >&2
	exit 1
fi

# Variable definition
DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/simple-sketch/dotfiles.git}"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"

# Anything already sitting where stow wants to put a symlink is moved here
# instead of being deleted. One timestamped directory per run, so a second run
# can never overwrite the backup the first run took.
BACKUP_ROOT="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"
backup_used=0

#####################################################################

# home dir various folder structure generation
SCREENSHOT_DIR="$HOME/Pictures/Screenshots"
mkdir -p "$SCREENSHOT_DIR"

#####################################################################

# Legacy repair: earlier versions of this script were sometimes run through
# sudo, which left ~/.config owned by root. stow would fail on it with a
# permission error that does not name the cause, so fix it up front.
if [ -d "$HOME/.config" ] && [ ! -O "$HOME/.config" ]; then
	echo "~/.config is not owned by $(id -un), fixing"
	sudo chown -R "$(id -un):$(id -gn)" "$HOME/.config"
fi

#####################################################################

# Sanity check: the runtime directory is the one thing this variant gets for
# free and the one thing that silently breaks everything if it is missing.
# pam_elogind.so creates it at login, so it only appears after the reboot.
RUNTIME_DIR="/run/user/$(id -u)"

if [ ! -d "$RUNTIME_DIR" ]; then
	echo "warning: $RUNTIME_DIR does not exist" >&2
	echo "pam_elogind.so creates it at login, so either the reboot after" >&2
	echo "script 1 has not happened yet, or elogind is not running" >&2
	echo "check with: sudo sv status elogind" >&2
fi

#####################################################################

# git comes in with base-devel and stow is in script 1's package list, but this
# script is also the one people run on a machine that was set up by hand.
missing=""
for tool in git stow; do
	command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done

if [ -n "$missing" ]; then
	echo "installing missing tools:$missing"
	# shellcheck disable=SC2086
	sudo xbps-install -Sy $missing
fi

#####################################################################

# Clone the dotfiles repo, or update it if it is already there.
if [ ! -e "$DOTFILES_DIR" ]; then
	echo "cloning $DOTFILES_REPO into $DOTFILES_DIR"
	git clone "$DOTFILES_REPO" "$DOTFILES_DIR"

elif [ ! -d "$DOTFILES_DIR/.git" ]; then
	echo "$DOTFILES_DIR exists but is not a git repository" >&2
	echo "move it aside and re-run, or point DOTFILES_DIR somewhere else" >&2
	exit 1

else
	echo "$DOTFILES_DIR already exists, updating"

	origin=$(git -C "$DOTFILES_DIR" remote get-url origin 2>/dev/null || echo "")
	if [ "$origin" != "$DOTFILES_REPO" ]; then
		echo "note: its origin is '$origin', not '$DOTFILES_REPO', using it as is"
	fi

	# A fast-forward pull would fail anyway with local edits in the tree, and
	# those edits are the whole point of keeping configs in git. Say so and
	# carry on rather than dying halfway through the install.
	if [ -n "$(git -C "$DOTFILES_DIR" status --porcelain)" ]; then
		echo "note: uncommitted changes in $DOTFILES_DIR, skipping pull"
	else
		git -C "$DOTFILES_DIR" pull --ff-only || \
			echo "note: pull failed, continuing with the checked out version"
	fi
fi

#####################################################################

# Every top level directory in the repo that is not .git is a stow package, so
# adding a package to the repo needs no edit here.
packages=""
for dir in "$DOTFILES_DIR"/*/; do
	[ -d "$dir" ] || continue           # no match, the glob stayed literal
	name=${dir%/}
	name=${name##*/}
	packages="$packages $name"
done

[ -n "$packages" ] || { echo "no stow packages found in $DOTFILES_DIR" >&2; exit 1; }
echo "stow packages:$packages"

#####################################################################

# Create the shared parent directories before stowing.
#
# This is the ~/.config-does-not-exist case, and it matters more than it looks.
# Given a missing ~/.config, stow "folds" the tree: instead of creating the
# directory and linking the file inside it, it makes ~/.config itself a symlink
# to whichever package it happened to process first, e.g.
#
#   ~/.config -> dotfiles/foot/.config
#
# Every other program on the machine then writes its config into the dotfiles
# repo, and every unstow of that one package takes the whole directory with it.
# Creating the directory first makes it a real directory that stow descends
# into. Folding one level down (~/.config/sway -> ../dotfiles/sway/.config/sway)
# is fine and is what we want.
for pkg in $packages; do
	for dir in "$DOTFILES_DIR/$pkg"/*/; do
		[ -d "$dir" ] || continue
		name=${dir%/}
		name=${name##*/}
		mkdir -p "$HOME/$name"
	done
done

# XDG dirs the configs write into at runtime. ~/.local/state in particular is
# where .bash_profile puts sway.log before sway has produced a single line.
mkdir -p "$HOME/.config" "$HOME/.local/share" "$HOME/.local/state" "$HOME/.local/bin"

#####################################################################

# Move anything in stow's way into $BACKUP_ROOT.
#
# stow refuses to overwrite a file it does not own, which on a fresh Void
# install means the whole run aborts on ~/.bashrc from /etc/skel, and on a
# machine set up by the old version of this script it aborts on the config
# files that version copied in. Neither is a real conflict, but stow cannot
# know that, and --adopt is the wrong tool: it would pull the *system* file
# into the repo and overwrite the repo's version with it.
backup_target() {
	rel=${1#"$HOME"/}
	dest="$BACKUP_ROOT/$rel"

	mkdir -p "$(dirname "$dest")"
	mv "$1" "$dest"
	backup_used=1

	echo "  moved $1 -> $dest"
}

# True when a path already resolves into the dotfiles repo. This is the guard
# that makes the script safe to re-run, and it has to resolve the whole path
# rather than just test the last component for being a symlink.
#
# After the first run ~/.config/foot is a symlink to the package directory, so
# ~/.config/foot/foot.ini is a perfectly ordinary file *inside the repo* when
# reached through it. Treating that as a conflict and moving it would delete
# the config out of the git working tree, which is the one outcome worse than
# stow refusing to run.
resolves_into_dotfiles() {
	resolved=$(readlink -f "$1" 2>/dev/null || echo "")
	case "$resolved" in
		"$DOTFILES_DIR"/*) return 0 ;;
		*) return 1 ;;
	esac
}

echo "checking for conflicts"

for pkg in $packages; do
	pkgdir="$DOTFILES_DIR/$pkg"

	# Leaves only: -type l as well as -type f because a package may itself
	# commit a symlink, and stow links that through like any other file.
	find "$pkgdir" -mindepth 1 \( -type f -o -type l \) -print | while IFS= read -r src; do
		rel=${src#"$pkgdir"/}
		target="$HOME/$rel"

		# A regular file where stow needs a directory blocks it just as hard
		# as a conflicting leaf, e.g. a ~/.config/foot file where the foot
		# package wants a ~/.config/foot directory. A symlink to a directory
		# passes -d and is left alone, which is what folding produces.
		d=$(dirname "$rel")
		while [ "$d" != "." ]; do
			ancestor="$HOME/$d"
			if { [ -e "$ancestor" ] || [ -L "$ancestor" ]; } && [ ! -d "$ancestor" ]; then
				if ! resolves_into_dotfiles "$ancestor"; then
					backup_target "$ancestor"
				fi
			fi
			d=$(dirname "$d")
		done

		if [ -e "$target" ] || [ -L "$target" ]; then
			if ! resolves_into_dotfiles "$target"; then
				backup_target "$target"
			fi
		fi
	done
done

# backup_target runs in the subshell on the right of that pipe, so the variable
# it set is gone by now. The directory it created is the durable record. Spelled
# as an if rather than "[ ... ] && x=1", which under set -e is a status-1 last
# command when the test fails.
if [ -d "$BACKUP_ROOT" ]; then
	backup_used=1
fi

#####################################################################

# Backing files out of, say, ~/.config/foot leaves an empty directory behind,
# and an existing directory is what stops stow from folding the package into a
# single ~/.config/foot symlink. Removing the empties keeps the result
# identical to a first install on a clean machine. rmdir only ever removes
# empty directories, so anything the user put there survives.
#
# Deepest first, because ~/.config/sway/scripts has to go before ~/.config/sway
# can be empty. The repo guard matters here too: on a re-run ~/.config/sway is
# already a symlink into the package, so ~/.config/sway/scripts resolves inside
# the repo and an unguarded rmdir would delete the directory from the checkout.
for pkg in $packages; do
	pkgdir="$DOTFILES_DIR/$pkg"

	find "$pkgdir" -mindepth 2 -type d -print | sort -r | while IFS= read -r src; do
		rel=${src#"$pkgdir"/}
		target="$HOME/$rel"

		if [ -d "$target" ] && ! resolves_into_dotfiles "$target"; then
			rmdir "$target" 2>/dev/null || true
		fi
	done
done

#####################################################################

# --restow unstows first, so a config that was renamed or dropped in the repo
# does not leave a dangling symlink in ~/.config. Word splitting on $packages
# is intentional, they are one argument each. No "--" before them: stow 2.4.1
# reads it as a package name and then reports that it has nothing to do.
echo "stowing into $HOME"
# shellcheck disable=SC2086
if ! stow --dir="$DOTFILES_DIR" --target="$HOME" --restow --verbose=1 $packages; then
	echo "" >&2
	echo "stow failed, nothing was left half applied" >&2
	echo "re-run to retry, or see what it objects to with:" >&2
	echo "  stow --dir=$DOTFILES_DIR --target=$HOME --simulate --verbose=2$packages" >&2
	exit 1
fi

#####################################################################

# Verify the two files the session depends on, instead of appending to them.
for f in "$HOME/.bash_profile" "$HOME/.bashrc"; do
	if [ ! -L "$f" ]; then
		echo "warning: $f is not a symlink, the repo copy is not in use" >&2
	elif ! resolves_into_dotfiles "$f"; then
		echo "warning: $f does not point into $DOTFILES_DIR" >&2
	fi
done

# The sway autostart lives in the repo's .bash_profile. If it is missing there,
# tty1 drops to a shell and nothing explains why.
if ! grep -q 'exec dbus-run-session sway' "$HOME/.bash_profile" 2>/dev/null; then
	echo "warning: no 'exec dbus-run-session sway' in ~/.bash_profile" >&2
	echo "sway will not autostart on tty1 until that block is in the repo copy" >&2
fi

#####################################################################

if [ "$backup_used" -eq 1 ]; then
	echo ""
	echo "files that were in the way were moved to $BACKUP_ROOT"
	echo "check them for local changes, then delete the directory"
fi

echo ""
echo "environment prepared, log out and back in to tty1 to start the session"
