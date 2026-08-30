#!/bin/sh

set -eu

REPO_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
SERVICE_TARGET=$(readlink -f /var/service 2>/dev/null || true)
USER_HOME=$(getent passwd "$(id -un)" | cut -d: -f6)
EXPECTED_VOIDERS_FINGERPRINT="a8:f0:05:df:01:c4:37:92:83:f6:8b:9a:ce:ab:73:29"
EXPECTED_SIMPLE_SKETCH_FINGERPRINT="f0:c8:38:88:dd:5b:65:c3:40:68:7f:98:6c:69:7b:84"
SIMPLE_SKETCH_REPO="https://raw.githubusercontent.com/simple-sketch/void-xbps-repository/main"

skip() {
  echo "SKIP: installer sandbox tests ($1)"
  exit 0
}

command -v bwrap >/dev/null 2>&1 || skip "bubblewrap is unavailable"
[ "$(id -u)" -ne 0 ] || skip "tests require a non-root user"
[ -d "$USER_HOME" ] || skip "the current user's home is unavailable"
[ -d /etc/sv ] || skip "/etc/sv is unavailable"
[ -d /etc/pam.d ] || skip "/etc/pam.d is unavailable"
[ -d /etc/xbps.d ] || skip "/etc/xbps.d is unavailable"
[ -d /etc/tlp.d ] || skip "/etc/tlp.d is unavailable"
[ -d /etc/alsa ] || skip "/etc/alsa is unavailable"
[ -n "$SERVICE_TARGET" ] && [ -d "$SERVICE_TARGET" ] || skip "/var/service is unavailable"

if ! bwrap --ro-bind / / --dev /dev --proc /proc \
  --unshare-user --unshare-pid /bin/true 2>/dev/null; then
  skip "unprivileged bubblewrap is disabled"
fi

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

make_case() {
  CASE_DIR="$TEST_ROOT/$1"
  mkdir -p \
    "$CASE_DIR/bin" \
    "$CASE_DIR/etc-sv" \
    "$CASE_DIR/services" \
    "$CASE_DIR/etc-pam.d" \
    "$CASE_DIR/etc-xbps.d" \
    "$CASE_DIR/etc-tlp.d" \
    "$CASE_DIR/etc-alsa/conf.d" \
    "$CASE_DIR/home/repo"
  : >"$CASE_DIR/log"
  printf '%s\n' '-session optional pam_elogind.so' >"$CASE_DIR/etc-pam.d/system-login"
  cp "$REPO_DIR/install.sh" "$CASE_DIR/home/repo/install.sh"

  cat >"$CASE_DIR/bin/mock" <<'MOCK'
#!/bin/sh
set -eu

command_name=${0##*/}
printf '%s %s\n' "$command_name" "$*" >>/tmp/log

case "$command_name" in
sudo)
  if [ "${1:-}" = -v ]; then
    exit 0
  fi
  if [ "${1:-}" = -u ]; then
    shift 2
  fi
  exec "$@"
  ;;
xbps-uhelper)
  [ "${1:-}" = arch ] && printf '%s\n' x86_64
  ;;
xbps-query)
  case "$*" in
    *"--repository=https://repo.voiders.dev"*)
      repository=https://repo.voiders.dev
      signed_by="Voiders Community"
      fingerprint=${VOIDERS_TEST_FINGERPRINT:-a8:f0:05:df:01:c4:37:92:83:f6:8b:9a:ce:ab:73:29}
      ambiguous=${VOIDERS_AMBIGUOUS_FINGERPRINT:-0}
      ;;
    *"--repository=https://raw.githubusercontent.com/simple-sketch/void-xbps-repository/main"*)
      repository=https://raw.githubusercontent.com/simple-sketch/void-xbps-repository/main
      signed_by="simple-sketch <linas.petrenas@gmail.com>"
      fingerprint=${SIMPLE_SKETCH_TEST_FINGERPRINT:-f0:c8:38:88:dd:5b:65:c3:40:68:7f:98:6c:69:7b:84}
      ambiguous=${SIMPLE_SKETCH_AMBIGUOUS_FINGERPRINT:-0}
      ;;
    *)
      exit 1
      ;;
  esac
  printf '%s\n' \
    "  42 $repository (RSA signed)" \
    "      Signed-by: $signed_by" \
    "      4096 $fingerprint"
  if [ "$ambiguous" = 1 ]; then
    printf '%s\n' "      4096 $fingerprint"
  fi
  ;;
git)
  if [ "${1:-}" = clone ]; then
    mkdir -p "$3/.git" "$3/sway"
    cat >"$3/.git/config" <<'EOF'
[remote "origin"]
  url = https://github.com/simple-sketch/dotfiles-stow
EOF
    printf '%s\n' '# mock profile' >"$3/sway/.bash_profile"
    exit 0
  fi
  if [ "${1:-}" = -C ] && [ "${3:-}" = remote ] && [ "${4:-}" = get-url ]; then
    /usr/bin/awk -F= '/^[[:space:]]*url[[:space:]]*=/ { value=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value }' "$2/.git/config"
    exit 0
  fi
  exit 1
  ;;
stow)
  case " $* " in
    *" --simulate "*)
      [ "${STOW_SIMULATE_FAIL:-0}" != 1 ]
      ;;
  esac
  ;;
sv)
  if [ "${1:-}" = -w ] && [ "${3:-}" = start ]; then
    service_name=${4##*/}
    [ "${SV_FAIL_SERVICE:-}" != "$service_name" ]
  fi
  ;;
xbps-install | xbps-alternatives | usermod | udevadm | rfkill | xdg-user-dirs-update | xdg-mime | tlp)
  ;;
*)
  echo "unexpected mock command: $command_name" >&2
  exit 1
  ;;
esac
MOCK
  chmod +x "$CASE_DIR/bin/mock"

  for command_name in sudo xbps-uhelper xbps-query xbps-install \
    xbps-alternatives usermod udevadm rfkill xdg-user-dirs-update xdg-mime \
    stow git sv tlp; do
    ln -s mock "$CASE_DIR/bin/$command_name"
  done

  for service_name in socklog-unix nanoklogd dbus elogind polkitd tlp alsa \
    bluetoothd dhcpcd iwd wpa_supplicant NetworkManager connmand wicd; do
    mkdir -p "$CASE_DIR/etc-sv/$service_name"
  done
}

run_case() {
  bwrap --ro-bind / / --dev /dev --proc /proc \
    --unshare-user --unshare-pid \
    --bind "$CASE_DIR" /tmp \
    --bind "$CASE_DIR/home" "$USER_HOME" \
    --bind "$CASE_DIR/etc-sv" /etc/sv \
    --bind "$CASE_DIR/services" "$SERVICE_TARGET" \
    --bind "$CASE_DIR/etc-pam.d" /etc/pam.d \
    --bind "$CASE_DIR/etc-xbps.d" /etc/xbps.d \
    --bind "$CASE_DIR/etc-tlp.d" /etc/tlp.d \
    --bind "$CASE_DIR/etc-alsa" /etc/alsa \
    --setenv PATH "/tmp/bin:/usr/bin:/bin" \
    --setenv IWD_CONFIG_FILE /tmp/iwd.conf \
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

assert_log_contains() {
  grep -F "$1" "$CASE_DIR/log" >/dev/null || {
    echo "FAIL: log does not contain '$1'" >&2
    exit 1
  }
}

assert_log_excludes() {
  if grep -F "$1" "$CASE_DIR/log" >/dev/null; then
    echo "FAIL: log unexpectedly contains '$1'" >&2
    exit 1
  fi
}

assert_before() {
  first_line=$(grep -n -F -m1 "$1" "$CASE_DIR/log" | cut -d: -f1)
  second_line=$(grep -n -F -m1 "$2" "$CASE_DIR/log" | cut -d: -f1)
  [ "$first_line" -lt "$second_line" ] || {
    echo "FAIL: '$1' did not run before '$2'" >&2
    exit 1
  }
}

assert_preflight_failure() {
  if run_case env >/dev/null 2>&1; then
    echo "FAIL: expected preflight failure" >&2
    exit 1
  fi
  assert_log_excludes "xbps-install "
}

make_case pam-commented
printf '%s\n' '# -session optional pam_elogind.so' >"$CASE_DIR/etc-pam.d/system-login"
assert_preflight_failure

make_case pam-suffixed
printf '%s\n' '-session optional pam_elogind.so.disabled' >"$CASE_DIR/etc-pam.d/system-login"
assert_preflight_failure

make_case managed-file-collision
printf '%s\n' 'repository=https://attacker.invalid' >"$CASE_DIR/etc-xbps.d/10-voiders-community.conf"
assert_preflight_failure

make_case personal-repository-file-collision
printf '%s\n' 'repository=https://attacker.invalid' >"$CASE_DIR/etc-xbps.d/20-simple-sketch.conf"
assert_preflight_failure

make_case managed-directory-collision
mkdir "$CASE_DIR/etc-alsa/conf.d/50-pipewire.conf"
assert_preflight_failure

make_case managed-dangling-link-collision
mkdir -p "$CASE_DIR/home/.config/pipewire/pipewire.conf.d"
ln -s /missing/target "$CASE_DIR/home/.config/pipewire/pipewire.conf.d/10-wireplumber.conf"
assert_preflight_failure

make_case managed-parent-collision
printf '%s\n' 'not a directory' >"$CASE_DIR/home/.config"
assert_preflight_failure

make_case invalid-iwd-target
ln -s /etc/sv/dbus "$CASE_DIR/services/iwd"
assert_preflight_failure

make_case iwd-config-conflict
printf '%s\n' '[General]' 'EnableNetworkConfiguration=true' >"$CASE_DIR/iwd.conf"
assert_preflight_failure

make_case unexpected-dotfiles-origin
mkdir -p "$CASE_DIR/home/dotfiles-stow/.git"
cat >"$CASE_DIR/home/dotfiles-stow/.git/config" <<'EOF'
[remote "origin"]
  url = https://attacker.invalid/dotfiles
EOF
assert_preflight_failure

make_case fingerprint-mismatch
if run_case env VOIDERS_TEST_FINGERPRINT=00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00 >/dev/null 2>&1; then
  echo "FAIL: mismatched Voiders fingerprint was accepted" >&2
  exit 1
fi
assert_log_excludes "sv -w 15 start"

make_case fingerprint-ambiguous
if run_case env VOIDERS_AMBIGUOUS_FINGERPRINT=1 >/dev/null 2>&1; then
  echo "FAIL: ambiguous Voiders fingerprint output was accepted" >&2
  exit 1
fi
assert_log_excludes "sv -w 15 start"

make_case personal-fingerprint-mismatch
if run_case env SIMPLE_SKETCH_TEST_FINGERPRINT=00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00 >/dev/null 2>&1; then
  echo "FAIL: mismatched simple-sketch fingerprint was accepted" >&2
  exit 1
fi
assert_log_excludes "sv -w 15 start"

make_case personal-fingerprint-ambiguous
if run_case env SIMPLE_SKETCH_AMBIGUOUS_FINGERPRINT=1 >/dev/null 2>&1; then
  echo "FAIL: ambiguous simple-sketch fingerprint output was accepted" >&2
  exit 1
fi
assert_log_excludes "sv -w 15 start"

make_case stow-conflict
ln -s /etc/sv/wpa_supplicant "$CASE_DIR/services/wpa_supplicant"
if run_case env STOW_SIMULATE_FAIL=1 >/dev/null 2>&1; then
  echo "FAIL: Stow simulation conflict did not stop the installer" >&2
  exit 1
fi
assert_log_contains "stow --simulate"
assert_log_excludes "sv -w 15 start"
assert_log_excludes "sv down wpa_supplicant"
assert_link wpa_supplicant

make_case happy-path
ln -s /etc/sv/socklog-unix "$CASE_DIR/services/socklog-unix"
touch "$CASE_DIR/etc-sv/socklog-unix/down"
ln -s /etc/sv/wpa_supplicant "$CASE_DIR/services/wpa_supplicant"
printf '%s\n' '# original shell file' >"$CASE_DIR/home/.bashrc"
run_case env >/dev/null 2>&1
run_case env >/dev/null 2>&1

[ "$(find "$CASE_DIR/home/.dotfiles-backup" -name .bashrc | wc -l)" -eq 1 ] || {
  echo "FAIL: shell-file backup was not safe across a rerun" >&2
  exit 1
}

for service_name in socklog-unix nanoklogd dbus elogind polkitd tlp alsa \
  bluetoothd dhcpcd iwd; do
  assert_link "$service_name"
done
assert_absent wpa_supplicant
assert_log_contains "sv -w 15 start /var/service/socklog-unix"
assert_before "stow --simulate" "sv -w 15 start /var/service/socklog-unix"
assert_before "xbps-install -Sy iwd dhcpcd" "rm -f /var/service/wpa_supplicant"
assert_before "sv -w 15 start /var/service/dhcpcd" "rm -f /var/service/wpa_supplicant"
assert_log_contains "xbps-query -i --repository=https://repo.voiders.dev -vL"
assert_log_contains "xbps-query -i --repository=$SIMPLE_SKETCH_REPO -vL"
grep -F "repository=https://repo.voiders.dev" "$CASE_DIR/etc-xbps.d/10-voiders-community.conf" >/dev/null
grep -F "repository=$SIMPLE_SKETCH_REPO" "$CASE_DIR/etc-xbps.d/20-simple-sketch.conf" >/dev/null

make_case iwd-rollback
ln -s /etc/sv/wpa_supplicant "$CASE_DIR/services/wpa_supplicant"
if run_case env SV_FAIL_SERVICE=iwd >/dev/null 2>&1; then
  echo "FAIL: iwd startup failure was not reported" >&2
  exit 1
fi
assert_link dhcpcd
assert_absent iwd
assert_link wpa_supplicant
assert_before "sv -w 15 start /var/service/dhcpcd" "rm -f /var/service/wpa_supplicant"
assert_log_contains "sv up wpa_supplicant"

printf 'PASS: installer preflight, service ordering, fingerprints, and rollback (%s, %s)\n' \
  "$EXPECTED_VOIDERS_FINGERPRINT" "$EXPECTED_SIMPLE_SKETCH_FINGERPRINT"
