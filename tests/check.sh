#!/bin/sh

set -eu

REPO_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
cd "$REPO_DIR"

SCRIPTS="
flatpak_flathub_install.sh
install.sh
iwd.sh
nerd_fonts_install.sh
networkmanager_install.sh
zramen_install.sh
"
TEST_SCRIPTS="
tests/check.sh
tests/service_transitions.sh
"

script_count=0
for script in $SCRIPTS; do
  script_count=$((script_count + 1))
  script_path="$REPO_DIR/$script"
  [ -x "$script_path" ] || {
    echo "FAIL: $script is not executable" >&2
    exit 1
  }
  sh -n "$script_path"
done

for script in $TEST_SCRIPTS; do
  [ -x "$REPO_DIR/$script" ] || {
    echo "FAIL: $script is not executable" >&2
    exit 1
  }
  sh -n "$REPO_DIR/$script"
done

if command -v shellcheck >/dev/null 2>&1; then
  for script in $SCRIPTS $TEST_SCRIPTS; do
    shellcheck -s sh "$REPO_DIR/$script"
  done
else
  echo "note: shellcheck is unavailable; syntax checks still passed" >&2
fi

"$REPO_DIR/tests/service_transitions.sh"
printf 'PASS: %s installer scripts\n' "$script_count"
