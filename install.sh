#!/bin/sh

# Install the desktop, clone the matching dotfiles, and stow every package.

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
INSTALL_SCRIPT="$SCRIPT_DIR/install_cli_tools_apps_sway_noctalia.sh"
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

[ -n "$USER_HOME" ] || {
  echo "cannot resolve home directory for $REAL_USER" >&2
  exit 1
}

DOTFILES_DIR="$USER_HOME/dotfiles-stow"

run_as_user() {
  if [ "$(id -u)" -eq 0 ]; then
    sudo -u "$REAL_USER" env HOME="$USER_HOME" "$@"
  else
    HOME="$USER_HOME" "$@"
  fi
}

[ -f "$INSTALL_SCRIPT" ] || {
  echo "missing installer: $INSTALL_SCRIPT" >&2
  exit 1
}

USE_EXISTING_DOTFILES=false

if [ -e "$DOTFILES_DIR" ]; then
  if [ ! -d "$DOTFILES_DIR/.git" ]; then
    echo "$DOTFILES_DIR already exists and is not a Git checkout" >&2
    exit 1
  fi

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

echo "==> Installing Sway, Noctalia, and CLI tools"
sh "$INSTALL_SCRIPT"

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
  "$USER_HOME/.local/bin"

# Build an argument for every non-hidden top-level package directory. This is
# equivalent to running `stow */` inside the checkout, while making the source
# and target directories explicit.
set --
for package_dir in "$DOTFILES_DIR"/*/; do
  [ -d "$package_dir" ] || continue
  package=${package_dir%/}
  package=${package##*/}
  set -- "$@" "$package"
done

[ "$#" -gt 0 ] || {
  echo "no Stow packages found in $DOTFILES_DIR" >&2
  exit 1
}

echo "==> Checking dotfiles for conflicts"
run_as_user stow \
  --simulate \
  --verbose=2 \
  --dir="$DOTFILES_DIR" \
  --target="$USER_HOME" \
  "$@"

echo "==> Stowing dotfiles into $USER_HOME"
run_as_user stow \
  --dir="$DOTFILES_DIR" \
  --target="$USER_HOME" \
  "$@"

echo "setup complete"
echo "reboot, then log in on tty1 to start Sway"
