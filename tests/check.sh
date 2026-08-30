#!/bin/sh

set -eu

REPO_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
cd "$REPO_DIR"

SCRIPTS="
install.sh
tests/check.sh
tests/service_transitions.sh
"

for script in $SCRIPTS; do
  [ -x "$script" ] || {
    echo "FAIL: $script is not executable" >&2
    exit 1
  }
  dash -n "$script"
done

if command -v shellcheck >/dev/null 2>&1; then
  for script in $SCRIPTS; do
    shellcheck -s sh "$script"
  done
else
  echo "note: shellcheck is unavailable; syntax checks still passed" >&2
fi

if command -v shfmt >/dev/null 2>&1; then
  for script in $SCRIPTS; do
    shfmt -d -i 2 -ci "$script"
  done
else
  echo "note: shfmt is unavailable; formatting check was skipped" >&2
fi

"$REPO_DIR/tests/service_transitions.sh"
echo "PASS: installer syntax, lint, format, and sandbox checks"
