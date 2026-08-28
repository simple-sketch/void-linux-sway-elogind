#!/bin/sh

set -eu

REPO_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
SERVICE_TARGET=$(readlink -f /var/service 2>/dev/null || true)
USER_HOME=$(getent passwd "$(id -un)" | cut -d: -f6)

skip() {
  echo "SKIP: service transition tests ($1)"
  exit 0
}

command -v bwrap >/dev/null 2>&1 || skip "bubblewrap is unavailable"
[ "$(id -u)" -ne 0 ] || skip "tests require a non-root user"
[ -d "$USER_HOME" ] || skip "the current user's home is unavailable"
[ -d /etc/sv ] || skip "/etc/sv is unavailable"
[ -n "$SERVICE_TARGET" ] && [ -d "$SERVICE_TARGET" ] || skip "/var/service is unavailable"
[ -d /sys/class/ieee80211 ] || skip "wireless sysfs is unavailable"

if ! bwrap --ro-bind / / --dev /dev --proc /proc \
  --unshare-user --unshare-pid /bin/true 2>/dev/null; then
  skip "unprivileged bubblewrap is disabled"
fi

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

make_case() {
  CASE_DIR="$TEST_ROOT/$1"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/etc-sv" \
    "$CASE_DIR/services" "$CASE_DIR/sys-ieee"
  : >"$CASE_DIR/log"

  cat >"$CASE_DIR/bin/mock" <<'MOCK'
#!/bin/sh
command_name=${0##*/}
printf '%s %s\n' "$command_name" "$*" >>/tmp/log

case "$command_name" in
sudo)
  [ "${1:-}" != -v ] || exit 0
  case " $* " in
  *" /etc/alsa/"*) exit 0 ;;
  esac
  exec "$@"
  ;;
git)
  if [ "${1:-}" = clone ]; then
    mkdir -p "$3/.git"
    if [ "${MALICIOUS_STOW_PACKAGE:-0}" = 1 ]; then
      mkdir -p "$3/--adopt"
    else
      mkdir -p "$3/bash"
      printf '%s\n' '# mock profile' >"$3/bash/.bash_profile"
    fi
    exit 0
  fi
  exit 1
  ;;
grep)
  case "$*" in
  *"/etc/pam.d/system-login"*) exit 0 ;;
  esac
  exec /usr/bin/grep "$@"
  ;;
tee)
  cat >/tmp/tee-output
  ;;
sv)
  if [ "${1:-}" = check ] && [ "${SV_FAIL_SERVICE:-}" = "${2:-}" ]; then
    exit 1
  fi
  ;;
nmcli)
  [ "${NMCLI_FAIL:-0}" != 1 ]
  ;;
esac
MOCK
  chmod +x "$CASE_DIR/bin/mock"

  for command_name in sudo sv xbps-install xbps-alternatives usermod \
    udevadm rfkill xdg-user-dirs-update stow git grep tee nmcli iw ip sleep; do
    ln -s mock "$CASE_DIR/bin/$command_name"
  done

  for service_name in dbus NetworkManager iwd wpa_supplicant dhcpcd zramen \
    socklog-unix nanoklogd elogind polkitd tlp alsa bluetoothd; do
    mkdir -p "$CASE_DIR/etc-sv/$service_name"
  done
}

run_case() {
  script_name=$1
  shift

  bwrap --ro-bind / / --dev /dev --proc /proc \
    --unshare-user --unshare-pid \
    --bind "$CASE_DIR" /tmp \
    --bind "$CASE_DIR/etc-sv" /etc/sv \
    --bind "$CASE_DIR/services" "$SERVICE_TARGET" \
    --ro-bind "$CASE_DIR/sys-ieee" /sys/class/ieee80211 \
    --setenv PATH "/tmp/bin:/usr/bin:/bin" \
    "$@" /bin/sh "$REPO_DIR/$script_name"
}

prepare_main_case() {
  make_case "$1"
  mkdir -p "$CASE_DIR/home/repo"
  cp "$REPO_DIR/install.sh" "$CASE_DIR/home/repo/install.sh"
}

run_main_case() {
  bwrap --ro-bind / / --dev /dev --proc /proc \
    --unshare-user --unshare-pid \
    --bind "$CASE_DIR" /tmp \
    --bind "$CASE_DIR/home" "$USER_HOME" \
    --bind "$CASE_DIR/etc-sv" /etc/sv \
    --bind "$CASE_DIR/services" "$SERVICE_TARGET" \
    --setenv PATH "/tmp/bin:/usr/bin:/bin" \
    "$@" /bin/sh "$USER_HOME/repo/install.sh"
}

assert_link() {
  [ -L "$CASE_DIR/services/$1" ] || {
    echo "FAIL: expected service link: $1" >&2
    exit 1
  }
}

assert_absent() {
  if [ -e "$CASE_DIR/services/$1" ] || [ -L "$CASE_DIR/services/$1" ]; then
    echo "FAIL: unexpected service link: $1" >&2
    exit 1
  fi
}

assert_before() {
  first_line=$(grep -n -m1 "$1" "$CASE_DIR/log" | cut -d: -f1)
  second_line=$(grep -n -m1 "$2" "$CASE_DIR/log" | cut -d: -f1)
  [ "$first_line" -lt "$second_line" ] || {
    echo "FAIL: '$1' did not run before '$2'" >&2
    exit 1
  }
}

prepare_main_case main-installer
run_main_case env >/dev/null 2>&1
for service_name in socklog-unix nanoklogd dbus elogind polkitd tlp alsa bluetoothd; do
  assert_link "$service_name"
done
[ -d "$CASE_DIR/home/dotfiles-stow/.git" ]
grep -q "stow --simulate" "$CASE_DIR/log"

prepare_main_case main-service-failure
if run_main_case env SV_FAIL_SERVICE=elogind >/dev/null 2>&1; then
  echo "FAIL: a required service failure did not stop install.sh" >&2
  exit 1
fi
assert_link dbus
assert_absent polkitd

prepare_main_case main-stow-option-injection
if run_main_case env MALICIOUS_STOW_PACKAGE=1 >/dev/null 2>&1; then
  echo "FAIL: install.sh accepted an option-like Stow package" >&2
  exit 1
fi
if grep -q '^stow ' "$CASE_DIR/log"; then
  echo "FAIL: Stow ran with an option-like package" >&2
  exit 1
fi

make_case networkmanager-success
ln -s /etc/sv/dhcpcd "$CASE_DIR/services/dhcpcd"
ln -s /etc/sv/wpa_supplicant "$CASE_DIR/services/wpa_supplicant"
run_case networkmanager_install.sh env >/dev/null
assert_link dbus
assert_link polkitd
assert_link NetworkManager
assert_absent dhcpcd
assert_absent wpa_supplicant
assert_before "sv check dbus" "sv check polkitd"
assert_before "sv check polkitd" "sv down dhcpcd"
grep -q "usermod -aG network $(id -un)" "$CASE_DIR/log"

make_case networkmanager-rollback
ln -s /etc/sv/dhcpcd "$CASE_DIR/services/dhcpcd"
ln -s /etc/sv/wpa_supplicant "$CASE_DIR/services/wpa_supplicant"
if run_case networkmanager_install.sh env NMCLI_FAIL=1 >/dev/null 2>&1; then
  echo "FAIL: NetworkManager failure was not reported" >&2
  exit 1
fi
assert_link dbus
assert_absent NetworkManager
assert_link dhcpcd
assert_link wpa_supplicant

make_case iwd-config-conflict
printf '%s\n' '[General]' 'EnableNetworkConfiguration=true' >"$CASE_DIR/iwd.conf"
ln -s /etc/sv/wpa_supplicant "$CASE_DIR/services/wpa_supplicant"
if run_case iwd.sh env IWD_CONFIG_FILE=/tmp/iwd.conf >/dev/null 2>&1; then
  echo "FAIL: iwd accepted conflicting internal network configuration" >&2
  exit 1
fi
assert_link wpa_supplicant
assert_absent dbus

make_case iwd-success
ln -s /etc/sv/dhcpcd "$CASE_DIR/services/dhcpcd"
ln -s /etc/sv/wpa_supplicant "$CASE_DIR/services/wpa_supplicant"
run_case iwd.sh env IWD_CONFIG_FILE=/tmp/no-iwd.conf >/dev/null
assert_link dbus
assert_link dhcpcd
assert_link iwd
assert_absent wpa_supplicant
assert_before "sv check dbus" "sv down wpa_supplicant"

make_case iwd-rollback
ln -s /etc/sv/dhcpcd "$CASE_DIR/services/dhcpcd"
ln -s /etc/sv/wpa_supplicant "$CASE_DIR/services/wpa_supplicant"
if run_case iwd.sh env IWD_CONFIG_FILE=/tmp/no-iwd.conf SV_FAIL_SERVICE=iwd >/dev/null 2>&1; then
  echo "FAIL: iwd failure was not reported" >&2
  exit 1
fi
assert_link dbus
assert_link dhcpcd
assert_absent iwd
assert_link wpa_supplicant

make_case zramen-success
run_case zramen_install.sh env >/dev/null
assert_link zramen

make_case zramen-rollback
if run_case zramen_install.sh env SV_FAIL_SERVICE=zramen >/dev/null 2>&1; then
  echo "FAIL: zramen failure was not reported" >&2
  exit 1
fi
assert_absent zramen

echo "PASS: installer service setup, ordering, and rollback"
