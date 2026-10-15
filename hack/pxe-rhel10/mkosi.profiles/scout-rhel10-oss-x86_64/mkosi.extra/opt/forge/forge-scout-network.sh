#!/usr/bin/env sh
#
# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# RHEL 10 Scout NIC isolation — NetworkManager (nmcli) variant.
#
# Identifies the boot NIC via the mac= kernel cmdline parameter and tells
# NetworkManager to stop managing all other NICs, so only the boot NIC
# participates in DHCP and routing during the NICo discovery phase.
#
# Replaces the upstream systemd-networkd variant (networkctl + .network drop-in)
# with NetworkManager equivalents. The upstream version is not used here because
# the RHEL 10 Scout OSS image installs NetworkManager, not systemd-networkd.
#
set -u
set -f

cmdline_file=${SCOUT_CMDLINE_FILE:-/proc/cmdline}
sys_class_net=${SCOUT_SYS_CLASS_NET:-/sys/class/net}
ip_command=${SCOUT_IP_COMMAND:-ip}
nmcli_command=${SCOUT_NMCLI_COMMAND:-nmcli}
network_wait_seconds=${SCOUT_NETWORK_WAIT_SECONDS:-60}
network_poll_interval=${SCOUT_NETWORK_POLL_INTERVAL:-1}

validate_positive_integer() {
	value=$1
	name=$2

	case "$value" in
		''|*[!0-9]*|0|0*)
			echo "Invalid Scout network timing value: variable=$name value=$value reason=positive_integer_required" >&2
			exit 1
			;;
	esac
}

validate_positive_integer "$network_wait_seconds" SCOUT_NETWORK_WAIT_SECONDS
validate_positive_integer "$network_poll_interval" SCOUT_NETWORK_POLL_INTERVAL

if ! cmdline=$(cat "$cmdline_file"); then
	echo "Skipping Scout network configuration: reason=cmdline_unreadable" >&2
	exit 0
fi

preferred_mac=
mac_parameter_count=0
for parameter in $cmdline
do
	case "$parameter" in
		mac=*)
			mac_parameter_count=$((mac_parameter_count + 1))
			preferred_mac=${parameter#mac=}
			;;
	esac
done
set +f

if [ "$mac_parameter_count" -ne 1 ]; then
	echo "Skipping Scout network configuration: reason=mac_parameter_count count=$mac_parameter_count" >&2
	exit 0
fi

case "$preferred_mac" in
	[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f])
		;;
	*)
		echo "Skipping Scout network configuration: reason=invalid_mac_parameter" >&2
		exit 0
		;;
esac
preferred_mac=$(printf '%s\n' "$preferred_mac" | tr '[:upper:]' '[:lower:]')

probe_attempts=0
probe_max_attempts=$((network_wait_seconds / network_poll_interval))
[ "$probe_max_attempts" -lt 1 ] && probe_max_attempts=1

# Wait for the preferred NIC to appear and have a carrier and a global IP address.
preferred_interface=
while :
do
	preferred_interface=
	preferred_interface_count=0
	for net_path in "$sys_class_net"/*
	do
		[ -e "$net_path" ] || continue
		[ -r "$net_path/address" ] || continue

		interface_mac=$(cat "$net_path/address") || continue
		interface_mac=$(printf '%s\n' "$interface_mac" | tr '[:upper:]' '[:lower:]')
		if [ "$interface_mac" = "$preferred_mac" ]; then
			preferred_interface=${net_path##*/}
			preferred_interface_count=$((preferred_interface_count + 1))
		fi
	done

	if [ "$preferred_interface_count" -gt 1 ]; then
		echo "Skipping Scout network configuration: reason=preferred_interface_count count=$preferred_interface_count" >&2
		exit 0
	fi

	not_ready=
	if [ "$preferred_interface_count" -ne 1 ]; then
		not_ready=no_interface
	else
		carrier_file="$sys_class_net/$preferred_interface/carrier"
		if [ ! -r "$carrier_file" ] || [ "$(cat "$carrier_file" 2>/dev/null)" != 1 ]; then
			not_ready=no_carrier
		elif ! global_addresses=$("$ip_command" -o address show dev "$preferred_interface" scope global); then
			not_ready=address_inspection_failed
		elif [ -z "$global_addresses" ]; then
			not_ready=no_global_address
		fi
	fi

	[ -z "$not_ready" ] && break

	probe_attempts=$((probe_attempts + 1))
	if [ "$probe_attempts" -ge "$probe_max_attempts" ]; then
		echo "Scout network configuration timed out: interface=${preferred_interface:-<none>} mac=$preferred_mac reason=$not_ready waited=${network_wait_seconds}s" >&2
		exit 1
	fi
	sleep "$network_poll_interval"
done

echo "Selected preferred network interface: interface=$preferred_interface mac=$preferred_mac"

# Tell NetworkManager to stop managing all other Ethernet interfaces so they
# cannot acquire DHCP leases or routes that would interfere with discovery.
# nmcli device set <iface> managed no takes effect immediately; NM drops any
# active connection on that device and stops DHCP/RA on it.
failed=false
for net_path in "$sys_class_net"/*
do
	[ -e "$net_path" ] || continue

	interface=${net_path##*/}
	[ "$interface" = "$preferred_interface" ] && continue

	# Skip loopback and virtual/bridge interfaces (no carrier file or type != ether).
	type_file="$sys_class_net/$interface/type"
	[ -r "$type_file" ] || continue
	# type=1 is ARPHRD_ETHER (real Ethernet); skip everything else (lo=772, etc.)
	[ "$(cat "$type_file" 2>/dev/null)" = 1 ] || continue

	if ! "$nmcli_command" device set "$interface" managed no 2>/dev/null; then
		echo "Failed to unmanage interface: interface=$interface" >&2
		failed=true
		continue
	fi

	# Wait briefly for NM to release addresses on this interface.
	wait_attempts=10
	while [ "$wait_attempts" -gt 0 ]
	do
		global_addresses=$("$ip_command" -o address show dev "$interface" scope global 2>/dev/null)
		[ -z "$global_addresses" ] && break
		wait_attempts=$((wait_attempts - 1))
		sleep 1
	done

	if [ -n "$global_addresses" ]; then
		echo "Interface still has global addresses after unmanage: interface=$interface addresses=$global_addresses" >&2
		# Best-effort: flush remaining addresses manually.
		"$ip_command" address flush dev "$interface" scope global 2>/dev/null || true
	fi

	echo "Isolated non-preferred interface: interface=$interface"
done

[ "$failed" = false ]
