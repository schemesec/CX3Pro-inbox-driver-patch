#!/usr/bin/env bash
set -euo pipefail

PF="${PF:-enp23s0}"
NUM_VFS="${NUM_VFS:-8}"
VF_VLAN="${VF_VLAN:-20}"
INSTALL_DIR="${INSTALL_DIR:-/lib/modules/$(uname -r)/updates/cx3pro-inbox-rocev2}"
VLAN10_IF="${VLAN10_IF:-${PF}.10}"
VLAN20_IF="${VLAN20_IF:-${PF}.20}"
VLAN10_IP="${VLAN10_IP:-}"
VLAN20_IP="${VLAN20_IP:-}"
CHECK_VLAN_IPS="${CHECK_VLAN_IPS:-1}"

failures=0

section() { printf '\n=== %s ===\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

need_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		fail "missing command: $1"
	fi
}

vf_mac_from_pf() {
	local pf="$1" idx="$2" pf_mac o1 o2 o3 o4 o5 o6
	pf_mac="$(cat "/sys/class/net/${pf}/address")"
	IFS=: read -r o1 o2 o3 o4 o5 o6 <<EOF_MAC
${pf_mac}
EOF_MAC
	printf '02:%s:%s:%s:%s:%02x\n' "$o3" "$o4" "$o5" "$o6" "$idx"
}

vf_bdf() {
	local idx="$1" vf_link
	vf_link="/sys/class/net/${PF}/device/virtfn${idx}"
	[ -e "$vf_link" ] || return 1
	basename "$(readlink -f "$vf_link")"
}

vf_netdev() {
	local idx="$1" bdf
	bdf="$(vf_bdf "$idx")" || return 1
	ls "/sys/bus/pci/devices/${bdf}/net" 2>/dev/null | head -1
}

pci_driver() {
	local bdf="$1" driver_link
	driver_link="/sys/bus/pci/devices/${bdf}/driver"
	[ -e "$driver_link" ] || return 1
	basename "$(readlink -f "$driver_link")"
}

rdma_dev_for_netdev() {
	local netdev="$1" dev ndev_file
	for dev in /sys/class/infiniband/*; do
		[ -d "$dev" ] || continue
		for ndev_file in "$dev"/ports/*/gid_attrs/ndevs/*; do
			[ -f "$ndev_file" ] || continue
			[ "$(cat "$ndev_file" 2>/dev/null || true)" = "$netdev" ] || continue
			basename "$dev"
			return 0
		done
	done
	return 1
}

check_module_path() {
	local module="$1"
	if modprobe --show-depends "$module" | grep -q "$INSTALL_DIR"; then
		pass "$module resolves to $INSTALL_DIR"
	else
		fail "$module does not resolve to $INSTALL_DIR"
		modprobe --show-depends "$module" || true
	fi
}

check_module_param() {
	local param="$1" expected="$2" path actual
	path="/sys/module/mlx4_core/parameters/${param}"
	if [ ! -f "$path" ]; then
		fail "mlx4_core parameter missing: $param"
		return
	fi
	actual="$(cat "$path")"
	[ "$actual" = "$expected" ] && pass "mlx4_core $param=$expected" || fail "mlx4_core $param mismatch: expected $expected, got $actual"
}

check_roce_v2_gid_for_netdev() {
	local netdev="$1" type_file idx base type ndev gid
	for type_file in /sys/class/infiniband/*/ports/*/gid_attrs/types/*; do
		[ -f "$type_file" ] || continue
		idx="$(basename "$type_file")"
		base="${type_file%/gid_attrs/types/*}"
		type="$(cat "$type_file" 2>/dev/null || true)"
		[ "$type" = "RoCE v2" ] || continue
		ndev="$(cat "${base}/gid_attrs/ndevs/${idx}" 2>/dev/null || true)"
		[ "$ndev" = "$netdev" ] || continue
		gid="$(cat "${base}/gids/${idx}" 2>/dev/null || true)"
		[ -n "$gid" ] && [ "$gid" != "0000:0000:0000:0000:0000:0000:0000:0000" ] || continue
		pass "$netdev has a nonzero RoCE v2 GID"
		return
	done
	fail "$netdev does not have a nonzero RoCE v2 GID"
}

section "host"
hostname
uname -r
uptime -s || true

section "commands"
for cmd in ip modprobe journalctl systemctl rdma ibv_devices ibv_devinfo; do
	need_cmd "$cmd"
done

section "proxmox services"
for service in pveproxy pvedaemon pvestatd pve-cluster pve-firewall; do
	systemctl is-active --quiet "$service" && pass "$service active" || fail "$service not active"
done

section "module resolution"
for module in mlx4_core mlx4_en mlx4_ib; do
	check_module_path "$module"
done

section "module parameters"
check_module_param enable_mfunc_roce_v2 Y

section "PF RoCEv2 GIDs"
for netdev in "$PF" "$VLAN10_IF" "$VLAN20_IF"; do
	ip link show "$netdev" >/dev/null 2>&1 && check_roce_v2_gid_for_netdev "$netdev" || warn "$netdev missing; skipping GID check"
done

section "RDMA devices"
ibv_devices || true
rdma link show || true

section "SR-IOV VFs"
if ! ip link show "$PF" >/dev/null 2>&1; then
	fail "PF netdev missing: $PF"
else
	pass "PF netdev present: $PF"
	ip -d link show "$PF"
fi

host_vfs=0
passthrough_vfs=0
for i in $(seq 0 $((NUM_VFS - 1))); do
	bdf="$(vf_bdf "$i" || true)"
	vf="$(vf_netdev "$i" || true)"
	driver=""
	expected_mac="$(vf_mac_from_pf "$PF" "$i")"
	[ -n "$bdf" ] || { fail "vf $i PCI function missing"; continue; }
	driver="$(pci_driver "$bdf" || true)"

	ip -d link show "$PF" | grep -q "vf $i .*vlan $VF_VLAN" && pass "vf $i is assigned VLAN $VF_VLAN" || fail "vf $i is not assigned VLAN $VF_VLAN"
	ip -d link show "$PF" | grep -q "vf $i .*link/ether $expected_mac" && pass "vf $i PF policy MAC is stable: $expected_mac" || fail "vf $i PF policy MAC mismatch: expected $expected_mac"

	if [ "$driver" = "vfio-pci" ]; then
		passthrough_vfs=$((passthrough_vfs + 1))
		pass "vf $i $bdf is assigned to vfio-pci passthrough"
		continue
	fi
	[ "$driver" = "mlx4_core" ] || { fail "vf $i $bdf unexpected driver: ${driver:-none}"; continue; }
	host_vfs=$((host_vfs + 1))
	[ -n "$vf" ] || { fail "vf $i netdev missing"; continue; }
	[ "$(cat "/sys/class/net/${vf}/address")" = "$expected_mac" ] && pass "$vf MAC is stable" || fail "$vf MAC mismatch"
	check_roce_v2_gid_for_netdev "$vf"
done

if [ $((host_vfs + passthrough_vfs)) -eq "$NUM_VFS" ]; then
	pass "$NUM_VFS VFs accounted for: $host_vfs host-owned, $passthrough_vfs passthrough"
else
	fail "VF accounting mismatch: expected $NUM_VFS, got $host_vfs host-owned and $passthrough_vfs passthrough"
fi

section "PF VLAN interfaces"
for netdev in "$PF" "$VLAN10_IF" "$VLAN20_IF"; do
	ip -br addr show "$netdev" 2>/dev/null || true
done
for vlan_if in "$VLAN10_IF" "$VLAN20_IF"; do
	ip link show "$vlan_if" >/dev/null 2>&1 && pass "$vlan_if exists" || fail "$vlan_if missing"
done
if [ "$CHECK_VLAN_IPS" = "1" ]; then
	if [ -n "$VLAN10_IP" ]; then
		ip -br addr show "$VLAN10_IF" | grep -q "$VLAN10_IP" && pass "$VLAN10_IF has $VLAN10_IP" || fail "$VLAN10_IF missing $VLAN10_IP"
	fi
	if [ -n "$VLAN20_IP" ]; then
		ip -br addr show "$VLAN20_IF" | grep -q "$VLAN20_IP" && pass "$VLAN20_IF has $VLAN20_IP" || fail "$VLAN20_IF missing $VLAN20_IP"
	fi
fi

section "kernel warning scan"
if journalctl -k -b -g 'BUG|Oops|WARNING|Call Trace|Unknown symbol|disagrees|__warn|fortify|objtool|vhcr command:0x3a' --no-pager | grep -v '^-- No entries --'; then
	fail "kernel warning scan found entries"
else
	pass "kernel warning scan has no matching entries"
fi

section "summary"
if [ "$failures" -eq 0 ]; then
	echo "verify-pve7: PASS"
	exit 0
fi
echo "verify-pve7: FAIL ($failures failures)"
exit 1
