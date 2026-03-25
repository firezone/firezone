#!/bin/bash
set -euo pipefail

OUT_BASE="$HOME/Desktop/firezone-diag-$(hostname)-$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$OUT_BASE"
PCAP_SECONDS="${PCAP_SECONDS:-20}"
LOG_MINUTES="${LOG_MINUTES:-15}"
DO_PCAP="${DO_PCAP:-0}"

mkdir -p "$OUT_DIR"

run() {
	local name="$1"
	shift
	{
		echo "### COMMAND: $*"
		echo "### DATE: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		echo
		"$@"
	} >"$OUT_DIR/$name.txt" 2>&1 || true
}

run_shell() {
	local name="$1"
	local cmd="$2"
	{
		echo "### COMMAND: $cmd"
		echo "### DATE: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		echo
		/bin/bash -lc "$cmd"
	} >"$OUT_DIR/$name.txt" 2>&1 || true
}

echo "Collecting diagnostics into: $OUT_DIR"

# Basic host info
run "00_date" date
run "01_sw_vers" sw_vers
run "02_uname" uname -a
run "03_uptime" uptime
run "04_whoami" whoami
run "05_scutil_computername" scutil --get ComputerName
run "06_scutil_localhostname" scutil --get LocalHostName
run "07_scutil_hostname" scutil --get HostName

# Network inventory
run "10_ifconfig_all" ifconfig -a
run "11_networksetup_hardwareports" networksetup -listallhardwareports
run "12_networksetup_services" networksetup -listallnetworkservices
run "13_networksetup_serviceorder" networksetup -listnetworkserviceorder
run "14_scutil_nwi" scutil --nwi
run "15_scutil_dns" scutil --dns
run "16_scutil_proxy" scutil --proxy
run "17_routes_ipv4" netstat -rn -f inet
run "18_routes_ipv6" netstat -rn -f inet6
run "19_netstat_interfaces" netstat -i
run "20_netstat_summary" netstat -s
run "21_arp" arp -a
run "22_ndp" ndp -an

# Active services details
run_shell "30_networksetup_details" '
services=$(networksetup -listallnetworkservices | tail -n +2 | sed "/^An asterisk/d")
while IFS= read -r svc; do
  echo "===== SERVICE: $svc ====="
  networksetup -getinfo "$svc" || true
  networksetup -getdnsservers "$svc" || true
  networksetup -getsearchdomains "$svc" || true
  networksetup -getwebproxy "$svc" || true
  networksetup -getsecurewebproxy "$svc" || true
  networksetup -getsocksfirewallproxy "$svc" || true
  echo
done <<< "$services"
'

# VPN / Network Extension state
run "40_scutil_nc_list" scutil --nc list
run_shell "41_scutil_nc_show_all" '
scutil --nc list | sed "s/^[* ]*//" | awk -F"\"" "/\\\"/ {print \$2}" | while IFS= read -r svc; do
  echo "===== VPN SERVICE: $svc ====="
  scutil --nc show "$svc" || true
  echo
done
'
run "42_systemextensions_list" systemextensionsctl list
run_shell "43_utun_interfaces" 'ifconfig -a | awk "/^utun[0-9]+:/{print \$1}" | tr -d ":" | while read -r i; do echo "===== $i ====="; ifconfig "$i"; echo; done'
run_shell "44_ps_network_related" 'ps aux | egrep "WireGuard|OpenVPN|Tunnelblick|networkextension|nesessionmanager|mDNSResponder|configd|neagent|nehelper|nesm" | egrep -v "egrep"'
run_shell "45_launchctl_network_related" 'launchctl list | egrep "network|dns|mdns|neagent|nehelper|nesessionmanager"'

# Optional: app/system extension receipts if present
run_shell "46_pkgutil_network" 'pkgutil --pkgs | egrep -i "vpn|wireguard|tunnel|network|extension"'

# Reachability / path checks
run_shell "50_route_default" 'route -n get default'
run_shell "51_route_default_v6" 'route -n get -inet6 default'
run_shell "52_ping_gateway" '
gw=$(route -n get default 2>/dev/null | awk "/gateway:/{print \$2}" | head -n1)
if [ -n "${gw:-}" ]; then
  echo "Gateway: $gw"
  ping -c 5 "$gw"
else
  echo "No default gateway found"
fi
'
run_shell "53_ping_dns" 'ping -c 5 1.1.1.1'
run_shell "54_dns_lookup_apple" 'dscacheutil -q host -a name apple.com'
run_shell "55_dns_lookup_example" 'dscacheutil -q host -a name example.com'
run_shell "56_networkquality" '
if command -v networkQuality >/dev/null 2>&1; then
  networkQuality -v
else
  echo "networkQuality not available on this macOS version"
fi
'

# Recent logs relevant to networking / VPN / DNS / system extensions
run_shell "60_log_show_relevant" "
log show --style syslog --last ${LOG_MINUTES}m --info --debug --predicate '
process == \"nesessionmanager\" OR
process == \"neagent\" OR
process == \"nehelper\" OR
process == \"mDNSResponder\" OR
process == \"configd\" OR
process == \"SystemExtension\" OR
subsystem BEGINSWITH \"com.apple.network\" OR
subsystem BEGINSWITH \"com.apple.NetworkExtension\" OR
subsystem CONTAINS[c] \"networkextension\" OR
eventMessage CONTAINS[c] \"utun\" OR
eventMessage CONTAINS[c] \"tunnel\" OR
eventMessage CONTAINS[c] \"dns\" OR
eventMessage CONTAINS[c] \"resolver\" OR
eventMessage CONTAINS[c] \"system extension\"
'
"

# Optional packet capture
if [ "$DO_PCAP" = "1" ]; then
	CAP_DIR="$OUT_DIR/pcap"
	mkdir -p "$CAP_DIR"

	DEFAULT_IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' | head -n1 || true)"
	UTUN_IFS="$(ifconfig -a | awk '/^utun[0-9]+:/{gsub(":","",$1); print $1}' || true)"

	if [ -n "${DEFAULT_IF:-}" ]; then
		echo "Capturing $PCAP_SECONDS seconds on default interface: $DEFAULT_IF"
		timeout_cmd=""
		if command -v gtimeout >/dev/null 2>&1; then
			timeout_cmd="gtimeout ${PCAP_SECONDS}"
		elif command -v timeout >/dev/null 2>&1; then
			timeout_cmd="timeout ${PCAP_SECONDS}"
		fi

		if [ -n "$timeout_cmd" ]; then
			sudo /bin/bash -lc "$timeout_cmd tcpdump -i '$DEFAULT_IF' -n -s 0 -w '$CAP_DIR/default-$DEFAULT_IF.pcap'" || true
		else
			sudo tcpdump -i "$DEFAULT_IF" -n -s 0 -w "$CAP_DIR/default-$DEFAULT_IF.pcap" &
			TCPDUMP_PID=$!
			sleep "$PCAP_SECONDS"
			sudo kill -INT "$TCPDUMP_PID" || true
			wait "$TCPDUMP_PID" || true
		fi
	fi

	for ui in $UTUN_IFS; do
		echo "Capturing $PCAP_SECONDS seconds on tunnel interface: $ui"
		timeout_cmd=""
		if command -v gtimeout >/dev/null 2>&1; then
			timeout_cmd="gtimeout ${PCAP_SECONDS}"
		elif command -v timeout >/dev/null 2>&1; then
			timeout_cmd="timeout ${PCAP_SECONDS}"
		fi

		if [ -n "$timeout_cmd" ]; then
			sudo /bin/bash -lc "$timeout_cmd tcpdump -i '$ui' -n -s 0 -w '$CAP_DIR/$ui.pcap'" || true
		else
			sudo tcpdump -i "$ui" -n -s 0 -w "$CAP_DIR/$ui.pcap" &
			TCPDUMP_PID=$!
			sleep "$PCAP_SECONDS"
			sudo kill -INT "$TCPDUMP_PID" || true
			wait "$TCPDUMP_PID" || true
		fi
	done
fi

# Redaction helper copy
cat >"$OUT_DIR/README.txt" <<EOF
Collected:
- interface state
- routes
- DNS / proxy / network service info
- VPN service state from scutil
- system extension list
- recent network/VPN/system-extension logs
- optional packet captures if DO_PCAP=1

Notes:
- Some commands may return partial output without sudo.
- Packet capture requires sudo.
- Review logs before sharing if you are concerned about hostnames, IPs, or service names.
EOF

ARCHIVE="${OUT_DIR}.tar.gz"
tar -czf "$ARCHIVE" -C "$(dirname "$OUT_DIR")" "$(basename "$OUT_DIR")"

echo
echo "Done."
echo "Archive: $ARCHIVE"
