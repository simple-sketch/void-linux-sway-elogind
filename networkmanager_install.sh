#!/bin/sh

set -eu

# NetworkManager exposes both ethernet and Wi-Fi over one D-Bus API, which is
# the backend Noctalia's network widget uses for scanning and connecting.
# Standalone network managers and DHCP/Wi-Fi services must not run at the same
# time: NetworkManager starts its own Wi-Fi helper and handles DHCP.

SERVICE_START_TIMEOUT=15
DISABLED_SERVICES=
CREATED_INTERFACES=
NETWORKMANAGER_WAS_ENABLED=false
ROLLBACK_REQUIRED=false

if [ "$(id -u)" -eq 0 ]; then
  REAL_USER=${SUDO_USER:-}
  if [ -z "$REAL_USER" ] || [ "$REAL_USER" = root ]; then
    echo "run this script as your normal user, not directly as root" >&2
    exit 1
  fi
else
  REAL_USER=$(id -un)
fi

command -v sudo >/dev/null 2>&1 || {
  echo "sudo is required" >&2
  exit 1
}

sudo -v

service_is_enabled() {
  service_name=$1
  [ -e "/var/service/$service_name" ] || [ -L "/var/service/$service_name" ]
}

link_service() {
  service_name=$1
  service_source="/etc/sv/$service_name"
  service_target="/var/service/$service_name"

  if [ ! -d "$service_source" ]; then
    echo "service directory is missing: $service_source" >&2
    return 1
  fi

  if [ -e "$service_target" ] && [ ! -d "$service_target" ] && [ ! -L "$service_target" ]; then
    echo "cannot enable $service_name: $service_target is not a service directory or symlink" >&2
    return 1
  fi

  if [ ! -d "$service_target" ] || [ -L "$service_target" ]; then
    sudo ln -sfn "$service_source" "$service_target"
  fi
}

wait_for_service() {
  service_name=$1
  timeout=$2
  i=0

  while [ "$i" -lt "$timeout" ]; do
    if sudo sv check "$service_name" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done

  sudo sv status "$service_name" >&2 || true
  return 1
}

validate_removable_service() {
  service_name=$1
  service_target="/var/service/$service_name"

  if service_is_enabled "$service_name" && [ ! -L "$service_target" ]; then
    echo "cannot switch networking: $service_target is not a removable symlink" >&2
    return 1
  fi
}

disable_service() {
  service_name=$1
  service_target="/var/service/$service_name"

  service_is_enabled "$service_name" || return 0

  # Restore only links that currently resolve to an installed service. A stale
  # broken link is safe to remove, but should not be recreated on rollback.
  if [ -d "$service_target" ]; then
    DISABLED_SERVICES="${DISABLED_SERVICES}${DISABLED_SERVICES:+ }$service_name"
  fi

  echo "disabling conflicting service: $service_name"
  sudo sv down "$service_name" || true
  sudo rm -f "$service_target"
}

restore_previous_networking() {
  echo "NetworkManager setup failed; restoring the previous network services" >&2

  if [ "$NETWORKMANAGER_WAS_ENABLED" = false ]; then
    sudo sv down NetworkManager >/dev/null 2>&1 || true
    if [ -L /var/service/NetworkManager ]; then
      sudo rm -f /var/service/NetworkManager ||
        echo "warning: could not remove the NetworkManager service link" >&2
    fi
  fi

  for interface_name in $CREATED_INTERFACES; do
    sudo iw dev "$interface_name" del >/dev/null 2>&1 ||
      echo "warning: could not remove temporary interface $interface_name" >&2
  done

  for service_name in $DISABLED_SERVICES; do
    if ! sudo ln -sfn "/etc/sv/$service_name" "/var/service/$service_name"; then
      echo "warning: could not restore the $service_name service link" >&2
      continue
    fi
    sudo sv up "$service_name" >/dev/null 2>&1 ||
      echo "warning: restored $service_name but could not start it" >&2
  done

  return 0
}

rollback_on_exit() {
  exit_status=$?
  trap - EXIT

  if [ "$ROLLBACK_REQUIRED" = true ]; then
    restore_previous_networking
  fi

  exit "$exit_status"
}

# Install everything and prove that D-Bus and polkit work before stopping the
# current network services. NetworkManager requires D-Bus, and Void's packaged
# polkit rule authorizes members of the network group.
sudo xbps-install -Sy NetworkManager iw dbus polkit
link_service dbus
if ! wait_for_service dbus "$SERVICE_START_TIMEOUT"; then
  echo "error: D-Bus did not become ready; existing networking was left unchanged" >&2
  exit 1
fi

link_service polkitd
if ! wait_for_service polkitd "$SERVICE_START_TIMEOUT"; then
  echo "error: polkit did not become ready; existing networking was left unchanged" >&2
  exit 1
fi

# The new group membership applies at the user's next login.
sudo usermod -aG network "$REAL_USER"

for service_name in iwd wpa_supplicant dhcpcd connmand wicd; do
  validate_removable_service "$service_name"
done

# An existing directory is a valid runit service. Other non-symlink targets
# would be unsafe to replace.
if [ -e /var/service/NetworkManager ] &&
  [ ! -d /var/service/NetworkManager ] &&
  [ ! -L /var/service/NetworkManager ]; then
  echo "cannot enable NetworkManager: /var/service/NetworkManager is not a service directory or symlink" >&2
  exit 1
fi

[ -d /var/service/NetworkManager ] && NETWORKMANAGER_WAS_ENABLED=true
ROLLBACK_REQUIRED=true
trap rollback_on_exit EXIT

for service_name in iwd wpa_supplicant dhcpcd connmand wicd; do
  disable_service "$service_name"
done

# iwd can remove the managed interface when it exits. Normally the kernel
# recreates it at the next boot; create one now as well so this script works
# without a reboot. Existing managed interfaces are left untouched.
sudo rfkill unblock wifi || true

interface_index=0
for phy_path in /sys/class/ieee80211/phy*; do
  [ -d "$phy_path" ] || continue

  has_managed_interface=false
  for interface_path in "$phy_path"/device/net/*; do
    [ -e "$interface_path" ] || continue
    interface_name=${interface_path##*/}
    if iw dev "$interface_name" info 2>/dev/null | grep -q 'type managed'; then
      has_managed_interface=true
      break
    fi
  done

  [ "$has_managed_interface" = true ] && continue

  while ip link show "wlan$interface_index" >/dev/null 2>&1; do
    interface_index=$((interface_index + 1))
  done

  phy_name=${phy_path##*/}
  interface_name="wlan$interface_index"
  if sudo iw phy "$phy_name" interface add "$interface_name" type managed; then
    CREATED_INTERFACES="${CREATED_INTERFACES}${CREATED_INTERFACES:+ }$interface_name"
    echo "restored Wi-Fi interface $interface_name on $phy_name"
  else
    echo "warning: could not restore an interface on $phy_name; reboot once after this script" >&2
  fi
  interface_index=$((interface_index + 1))
done

link_service NetworkManager

i=0
while [ "$i" -lt "$SERVICE_START_TIMEOUT" ]; do
  if sudo sv check NetworkManager >/dev/null 2>&1 &&
    sudo nmcli general status >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

if ! sudo sv check NetworkManager >/dev/null 2>&1 ||
  ! sudo nmcli general status >/dev/null 2>&1; then
  sudo sv status NetworkManager >&2 || true
  echo "error: NetworkManager did not become available on D-Bus" >&2
  exit 1
fi

sudo nmcli networking on
sudo nmcli radio wifi on
sudo sv status NetworkManager

echo
sudo nmcli -f DEVICE,TYPE,STATE,CONNECTION device status
echo
echo "NetworkManager now provides ethernet and Wi-Fi to Noctalia."
echo "Log out and back in so the new network-group membership takes effect."
echo "Then open Noctalia's network widget to scan and connect."

ROLLBACK_REQUIRED=false
trap - EXIT
