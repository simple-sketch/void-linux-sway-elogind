#!/bin/sh

# Optional zram swap. Kept out of the main desktop install because whether a
# compressed swap device in RAM is worth it depends on the machine: it helps on
# a low-memory laptop, while a machine with ample RAM and disk swap may only
# spend extra CPU time on compression.
#
# zramen is Void's zram manager. The service creates the device on boot
# ("zramen make") and removes it on shutdown ("zramen toss"). Size, priority,
# and compression are configured in /etc/sv/zramen/conf.

set -eu

SERVICE_START_TIMEOUT=15
ZRAMEN_WAS_ENABLED=false
ROLLBACK_REQUIRED=false

command -v sudo >/dev/null 2>&1 || {
  echo "sudo is required" >&2
  exit 1
}

sudo -v
sudo xbps-install -Sy zramen

[ -d /etc/sv/zramen ] || {
  echo "service directory is missing: /etc/sv/zramen" >&2
  exit 1
}

if [ -e /var/service/zramen ] &&
  [ ! -d /var/service/zramen ] &&
  [ ! -L /var/service/zramen ]; then
  echo "cannot enable zramen: /var/service/zramen is not a service directory or symlink" >&2
  exit 1
fi

[ -d /var/service/zramen ] && ZRAMEN_WAS_ENABLED=true

rollback_zramen() {
  exit_status=$1
  trap - EXIT

  if [ "$ROLLBACK_REQUIRED" = true ] && [ "$ZRAMEN_WAS_ENABLED" = false ]; then
    sudo sv down zramen >/dev/null 2>&1 || true
    if [ -L /var/service/zramen ]; then
      sudo rm -f /var/service/zramen ||
        echo "warning: could not remove the failed zramen service link" >&2
    fi
  fi

  exit "$exit_status"
}

if [ ! -d /var/service/zramen ] || [ -L /var/service/zramen ]; then
  sudo ln -sfn /etc/sv/zramen /var/service/zramen
fi

ROLLBACK_REQUIRED=true
trap 'rollback_zramen $?' EXIT

# Wait for runsvdir to pick the service up, and fail instead of claiming that
# swap is active when zramen could not create it.
i=0
while [ "$i" -lt "$SERVICE_START_TIMEOUT" ]; do
  if sudo sv check zramen >/dev/null 2>&1; then
    sudo sv status zramen
    echo "zram swap enabled, tune it in /etc/sv/zramen/conf"
    echo "check the device with: zramctl"
    echo "and the swap priorities with: swapon --show"
    ROLLBACK_REQUIRED=false
    trap - EXIT
    exit 0
  fi
  i=$((i + 1))
  sleep 1
done

sudo sv status zramen >&2 || true
echo "error: zramen did not become ready within ${SERVICE_START_TIMEOUT}s" >&2
rollback_zramen 1
