#!/usr/bin/env bash
set -euo pipefail

KVER="${KVER:-$(uname -r)}"
INSTALL_DIR="${INSTALL_DIR:-/lib/modules/${KVER}/updates/cx3pro-inbox-rocev2}"
PATCH_FILE="${PATCH_FILE:-patches/kernel/0066-mlx4-preserve-rocev2-gid-type-for-sriov-vfs.patch}"
STRICT=0

usage() {
	cat <<EOF
Usage: $0 [--strict]

Report whether this host is ready to rebuild the CX3 Pro inbox mlx4 patch for
the selected Proxmox kernel. This does not build or install modules.

Environment:
  KVER=...         Kernel release to check. Default: uname -r.
  INSTALL_DIR=... Expected module override directory.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--strict) STRICT=1 ;;
	-h|--help) usage; exit 0 ;;
	*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

failures=0
warnings=0

section() { printf '\n=== %s ===\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; warnings=$((warnings + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

pkg_status() {
	local pkg="$1"
	dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' "$pkg" 2>/dev/null |
		awk '$1 == "ii" { $1=""; sub(/^ /, ""); print }' || true
}

check_file() {
	local path="$1"
	[ -e "$path" ] && pass "$path exists" || fail "$path missing"
}

check_module_resolution() {
	local module="$1" expected="$2" resolved
	resolved="$(modinfo -k "$KVER" -n "$module" 2>/dev/null || true)"
	if [ -z "$resolved" ]; then
		fail "cannot resolve $module for $KVER"
		return
	fi
	printf '%s -> %s\n' "$module" "$resolved"
	case "$expected:$resolved" in
	patched:"$INSTALL_DIR"/*) pass "$module resolves to patch override" ;;
	patched:*) fail "$module does not resolve to $INSTALL_DIR" ;;
	stock:*/kernel/*) pass "$module remains stock inbox" ;;
	stock:*) warn "$module resolves outside stock kernel tree: $resolved" ;;
	*) fail "internal error: unknown expected state $expected for $module" ;;
	esac
}

section "host"
hostname
printf 'kernel=%s\n' "$KVER"
printf 'install_dir=%s\n' "$INSTALL_DIR"

section "kernel packages"
for pkg in \
	"proxmox-kernel-${KVER}" \
	"proxmox-headers-${KVER}" \
	"pve-kernel-${KVER}" \
	"pve-headers-${KVER}"; do
	result="$(pkg_status "$pkg")"
	if [ -n "$result" ]; then
		pass "$result"
	else
		apt-cache policy "$pkg" 2>/dev/null | sed -n '1,6p'
	fi
done

section "build inputs"
check_file "/boot/config-${KVER}"
check_file "/lib/modules/${KVER}/build/Makefile"
check_file "/lib/modules/${KVER}/build/Module.symvers"
check_file "$PATCH_FILE"

section "module override resolution"
check_module_resolution mlx4_core patched
check_module_resolution mlx4_en patched
check_module_resolution mlx4_ib patched
check_module_resolution rdma_cm stock
check_module_resolution nvme_rdma stock
check_module_resolution nvmet_rdma stock

section "loaded module state"
for module in mlx4_core mlx4_en mlx4_ib; do
	if [ -d "/sys/module/${module}" ]; then
		printf '%s loaded from: %s\n' "$module" "$(modinfo -n "$module" 2>/dev/null || true)"
	else
		warn "$module is not loaded"
	fi
done

section "recommended next commands"
cat <<EOF
./install-pve7.sh --apply-check-only --no-apt
./install-pve7.sh --build-only --no-apt
./install-pve7.sh --no-apt
reboot
PF=enp23s0 NUM_VFS=12 VF_VLAN=20 VLAN10_IP=192.168.10.56/24 VLAN20_IP=192.168.20.56/24 ./verify-pve7.sh
EOF

section "summary"
printf 'warnings=%d failures=%d\n' "$warnings" "$failures"
if [ "$failures" -ne 0 ]; then
	exit 1
fi
if [ "$STRICT" -eq 1 ] && [ "$warnings" -ne 0 ]; then
	exit 2
fi
