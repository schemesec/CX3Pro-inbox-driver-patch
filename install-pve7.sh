#!/usr/bin/env bash
set -euo pipefail

TESTED_KERNELS="${TESTED_KERNELS:-7.0.2-2-pve}"
KVER="${KVER:-$(uname -r)}"
JOBS="${JOBS:-$(nproc)}"
INSTALL_DIR="${INSTALL_DIR:-/lib/modules/${KVER}/updates/cx3pro-inbox-rocev2}"
BUILD_ROOT="${BUILD_ROOT:-/root/cx3pro-inbox-build}"
PVE_KERNEL_REPO="${PVE_KERNEL_REPO:-https://github.com/proxmox/pve-kernel.git}"
PVE_KERNEL_REF="${PVE_KERNEL_REF:-}"
UBUNTU_KERNEL_REPO="${UBUNTU_KERNEL_REPO:-https://git.proxmox.com/git/mirror_ubuntu-kernels.git}"
ZFSONLINUX_REPO="${ZFSONLINUX_REPO:-https://git.proxmox.com/git/zfsonlinux.git}"
BACKUP_DIR="${BACKUP_DIR:-}"
NUM_VFS="${NUM_VFS:-8}"
PORT_TYPE_ARRAY="${PORT_TYPE_ARRAY:-2,2}"
LOG_NUM_MGM_ENTRY_SIZE="${LOG_NUM_MGM_ENTRY_SIZE:--7}"
BUILD_ONLY=0
NO_BUILD=0
NO_BACKUP=0
FORCE_KERNEL=0
STRICT_KERNEL=0
APPLY_CHECK_ONLY=0
NO_APT=0
KEEP_CONFLICTS=0

usage() {
	cat <<EOF
Usage: $0 [options]

Build and install patched inbox mlx4 modules for CX3 Pro RoCEv2 VF testing.

Options:
  --build-only       Build modules but do not install into /lib/modules.
  --no-build         Install previously built modules from BUILD_ROOT.
  --no-backup        Do not back up the current installed module directory.
  --strict-kernel    Refuse kernels not listed in TESTED_KERNELS.
  --force-kernel     Compatibility alias for the default non-strict behavior.
  --apply-check-only Prepare source and verify the patch applies; do not build.
  --no-apt           Do not install build dependencies with apt.
  --keep-conflicts   Do not move old OFED override modules/config out of the way.
  -h, --help         Show this help.

Environment:
  KVER=...           Kernel release to build/install for. Default: uname -r.
  JOBS=...           Parallel build jobs. Default: nproc.
  BUILD_ROOT=...     Build checkout directory. Default: /root/cx3pro-inbox-build.
  PVE_KERNEL_REF=... Optional pve-kernel git ref to check out before building.
  TESTED_KERNELS=... Space-separated kernels known to have passed validation.
  INSTALL_DIR=...    Module install directory. Default:
                     /lib/modules/\$KVER/updates/cx3pro-inbox-rocev2
  BACKUP_DIR=...     Backup directory for previous installed modules.
  NUM_VFS=...        mlx4 PF0 VF count for modprobe/initramfs config. Default: 8.
  PORT_TYPE_ARRAY=... mlx4 port type array. Default: 2,2.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--build-only)
		BUILD_ONLY=1
		;;
	--no-build)
		NO_BUILD=1
		;;
	--no-backup)
		NO_BACKUP=1
		;;
	--force-kernel)
		FORCE_KERNEL=1
		;;
	--strict-kernel)
		STRICT_KERNEL=1
		;;
	--apply-check-only)
		APPLY_CHECK_ONLY=1
		BUILD_ONLY=1
		;;
	--no-apt)
		NO_APT=1
		;;
	--keep-conflicts)
		KEEP_CONFLICTS=1
		;;
	-h|--help)
		usage
		exit 0
		;;
	*)
		echo "error: unknown option: $1" >&2
		usage >&2
		exit 2
		;;
	esac
	shift
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${REPO_ROOT}/logs"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="${LOG_DIR}/install-${TS}.log"
PVE_TREE="${BUILD_ROOT}/pve-kernel"
KERNEL_TREE="${PVE_TREE}/submodules/ubuntu-kernel"
PATCH_FILE="${REPO_ROOT}/patches/kernel/0066-mlx4-preserve-rocev2-gid-type-for-sriov-vfs.patch"

log() {
	printf '%s\n' "$*" | tee -a "$LOG"
}

run() {
	log "+ $*"
	"$@" 2>&1 | tee -a "$LOG"
	local rc=${PIPESTATUS[0]}
	if [ "$rc" -ne 0 ]; then
		log "error: command failed with rc=${rc}"
		exit "$rc"
	fi
}

need_file() {
	if [ ! -f "$1" ]; then
		log "error: missing required file: $1"
		exit 1
	fi
}

kernel_base_version() {
	printf '%s\n' "$KVER" | sed 's/-.*//'
}

kernel_localversion() {
	local base
	base="$(kernel_base_version)"
	printf '%s\n' "${KVER#${base}}"
}

kernel_is_tested() {
	local tested

	for tested in $TESTED_KERNELS; do
		[ "$KVER" = "$tested" ] && return 0
	done
	return 1
}

ensure_build_deps() {
	if [ "$NO_APT" -eq 1 ]; then
		return
	fi

	if ! command -v apt-get >/dev/null 2>&1; then
		log "apt-get not found; skipping dependency install"
		return
	fi

	run apt-get update
	run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
		git build-essential bc flex bison libelf-dev libssl-dev \
		libdw-dev dwarves rsync
}

prepare_source() {
	run mkdir -p "$BUILD_ROOT"
	if [ -d "${PVE_TREE}/.git" ]; then
		run git -C "$PVE_TREE" fetch --depth 1 origin
		run git -C "$PVE_TREE" reset --hard FETCH_HEAD
	else
		run git clone --depth 1 "$PVE_KERNEL_REPO" "$PVE_TREE"
	fi
	if [ -n "$PVE_KERNEL_REF" ]; then
		run git -C "$PVE_TREE" fetch --depth 1 origin "$PVE_KERNEL_REF"
		run git -C "$PVE_TREE" reset --hard FETCH_HEAD
	fi

	run git -C "$PVE_TREE" submodule set-url submodules/ubuntu-kernel "$UBUNTU_KERNEL_REPO"
	run git -C "$PVE_TREE" submodule set-url submodules/zfsonlinux "$ZFSONLINUX_REPO"
	run git -C "$PVE_TREE" submodule update --init submodules/ubuntu-kernel
	run cp "$PATCH_FILE" "${PVE_TREE}/patches/kernel/"

	run git -C "$KERNEL_TREE" reset --hard HEAD
	run git -C "$KERNEL_TREE" clean -fdx
	local src_version
	src_version="$(make -s -C "$KERNEL_TREE" kernelversion)"
	if [ "$src_version" != "$(kernel_base_version)" ]; then
		log "error: source kernel version ${src_version} does not match target $(kernel_base_version)"
		log "set PVE_KERNEL_REF to a pve-kernel ref with the matching source version"
		exit 1
	fi
	run git -C "$KERNEL_TREE" apply --check "$PATCH_FILE"
	run git -C "$KERNEL_TREE" apply "$PATCH_FILE"
	run git -C "$KERNEL_TREE" diff --check
}

build_modules() {
	local localversion
	localversion="$(kernel_localversion)"

	run cp "/boot/config-${KVER}" "${KERNEL_TREE}/.config"
	run make -C "$KERNEL_TREE" olddefconfig
	run make -C "$KERNEL_TREE" prepare modules_prepare "LOCALVERSION=${localversion}" "-j${JOBS}"
	run cp "/lib/modules/${KVER}/build/Module.symvers" "${KERNEL_TREE}/Module.symvers"
	run make -C "$KERNEL_TREE" "M=drivers/net/ethernet/mellanox/mlx4" clean
	run make -C "$KERNEL_TREE" "M=drivers/infiniband/hw/mlx4" clean
	run cp "/lib/modules/${KVER}/build/Module.symvers" "${KERNEL_TREE}/Module.symvers"
	run make -C "$KERNEL_TREE" "M=drivers/net/ethernet/mellanox/mlx4" modules "LOCALVERSION=${localversion}" "-j${JOBS}"
	run make -C "$KERNEL_TREE" "M=drivers/infiniband/hw/mlx4" modules \
		"LOCALVERSION=${localversion}" \
		"KBUILD_EXTRA_SYMBOLS=${KERNEL_TREE}/drivers/net/ethernet/mellanox/mlx4/Module.symvers" \
		"-j${JOBS}"
}

verify_module() {
	local module="$1"
	local vermagic

	need_file "$module"
	vermagic="$(modinfo -F vermagic "$module")"
	case "$vermagic" in
	"${KVER} "*)
		log "vermagic ok: $(basename "$module"): ${vermagic}"
		;;
	*)
		log "error: bad vermagic for ${module}: ${vermagic}"
		log "expected prefix: ${KVER}"
		exit 1
		;;
	esac
}

verify_mlx4_ib_symbol_versions() {
	local core_symvers="${KERNEL_TREE}/drivers/net/ethernet/mellanox/mlx4/Module.symvers"
	local ib_module="${KERNEL_TREE}/drivers/infiniband/hw/mlx4/mlx4_ib.ko"
	local symbols=(
		mlx4_register_vlan
		mlx4_get_roce_gid_from_slave
		mlx4_get_base_gid_ix
		mlx4_get_slave_from_roce_gid
	)
	local symbol expected actual

	need_file "$core_symvers"
	need_file "$ib_module"

	for symbol in "${symbols[@]}"; do
		expected="$(awk -v sym="$symbol" '$2 == sym { print $1; exit }' "$core_symvers")"
		actual="$(modprobe --dump-modversions "$ib_module" | awk -v sym="$symbol" '$2 == sym { print $1; exit }')"
		if [ -z "$expected" ] || [ -z "$actual" ] || [ "$expected" != "$actual" ]; then
			log "error: mlx4_ib symbol CRC mismatch for ${symbol}: expected=${expected:-missing} actual=${actual:-missing}"
			exit 1
		fi
	done
	log "mlx4_ib symbol CRCs match patched mlx4_core exports"
}

install_module() {
	local src="$1"
	local dst="${INSTALL_DIR}/$(basename "$src")"

	verify_module "$src"
	run install -m 0644 "$src" "$dst"
}

backup_path() {
	local path="$1"
	local rel="${path#/}"
	local dst="${BACKUP_DIR}/${rel}"

	run mkdir -p "$(dirname "$dst")"
	run mv "$path" "$dst"
	log "moved ${path} to ${dst}"
}

remove_legacy_initramfs_block() {
	local modules_file="/etc/initramfs-tools/modules"

	if [ -f "$modules_file" ] && grep -q "^# mlx-research begin$" "$modules_file"; then
		run mkdir -p "$BACKUP_DIR"
		run cp -a "$modules_file" "${BACKUP_DIR}/etc-initramfs-tools-modules.before-cx3pro-inbox"
		run sed -i "/^# mlx-research begin$/,/^# mlx-research end$/d" "$modules_file"
		log "removed legacy mlx-research initramfs module block"
	fi
}

disable_conflicting_overrides() {
	local updates_dir="/lib/modules/${KVER}/updates"
	local ofed_dir="${updates_dir}/mlnx-ofed-cx3"

	if [ "$KEEP_CONFLICTS" -eq 1 ]; then
		log "keeping existing conflicting module/config overrides by request"
		return
	fi

	if [ -d "$ofed_dir" ]; then
		log "disabling old OFED override tree: ${ofed_dir}"
		backup_path "$ofed_dir"
	fi

	if [ -f /etc/modprobe.d/mlx4.conf ] &&
	    grep -Eq 'roce_mode|ud_gid_type|enable_sys_tune' /etc/modprobe.d/mlx4.conf; then
		log "disabling legacy OFED mlx4 module options"
		backup_path /etc/modprobe.d/mlx4.conf
	fi

	if [ -f /etc/modprobe.d/mlx-research-cx3.conf ]; then
		log "disabling legacy mlx-research blacklist/config file"
		backup_path /etc/modprobe.d/mlx-research-cx3.conf
	fi

	remove_legacy_initramfs_block
}

write_module_config() {
	local modprobe_file="/etc/modprobe.d/cx3pro-inbox-rocev2.conf"
	local modules_file="/etc/initramfs-tools/modules"
	local begin="# cx3pro-inbox-rocev2 begin"
	local end="# cx3pro-inbox-rocev2 end"

cat >"$modprobe_file" <<EOF
# CX3 Pro inbox mlx4 RoCEv2/SR-IOV test modules
options mlx4_core num_vfs=${NUM_VFS},0,0 probe_vf=${NUM_VFS},0,0 port_type_array=${PORT_TYPE_ARRAY} log_num_mgm_entry_size=${LOG_NUM_MGM_ENTRY_SIZE} enable_mfunc_roce_v2=1
EOF
	log "module options written to ${modprobe_file}"

	if [ ! -f "$modules_file" ]; then
		run touch "$modules_file"
	fi
	if grep -q "^${begin}$" "$modules_file"; then
		run sed -i "/^${begin}$/,/^${end}$/d" "$modules_file"
	fi
	{
		printf '%s\n' "$begin"
		printf '%s\n' mlx4_core
		printf '%s\n' mlx4_en
		printf '%s\n' mlx4_ib
		printf '%s\n' "$end"
	} >>"$modules_file"
	log "initramfs modules pinned in ${modules_file}"
}

mkdir -p "$LOG_DIR"
cd "$REPO_ROOT"

log "=== CX3 Pro inbox RoCEv2 VF patch installer ==="
log "repo=${REPO_ROOT}"
log "kernel=${KVER}"
log "jobs=${JOBS}"
log "build_root=${BUILD_ROOT}"
log "install_dir=${INSTALL_DIR}"
log "tested_kernels=${TESTED_KERNELS}"
log "log=${LOG}"
log

if ! kernel_is_tested; then
	if [ "$STRICT_KERNEL" -eq 1 ] && [ "$FORCE_KERNEL" -ne 1 ]; then
		log "error: ${KVER} is not in TESTED_KERNELS: ${TESTED_KERNELS}"
		log "rerun without --strict-kernel, or with --force-kernel if intentionally testing this kernel"
		exit 1
	fi
	log "warning: ${KVER} is not in TESTED_KERNELS: ${TESTED_KERNELS}"
	log "warning: continuing as an unvalidated kernel; build and runtime tests must pass before treating it as supported"
fi

if [ "$(id -u)" -ne 0 ]; then
	log "error: this installer must run as root"
	exit 1
fi

need_file "$PATCH_FILE"
need_file "/boot/config-${KVER}"
need_file "/lib/modules/${KVER}/build/Module.symvers"

if [ "$NO_BUILD" -eq 0 ]; then
	ensure_build_deps
	prepare_source
	if [ "$APPLY_CHECK_ONLY" -eq 1 ]; then
		log "apply-check-only complete"
		log "patch applied cleanly to source version $(kernel_base_version)"
		log "log=${LOG}"
		exit 0
	fi
	build_modules
else
	log "=== skipping build by request ==="
fi

MODULES=(
	"${KERNEL_TREE}/drivers/net/ethernet/mellanox/mlx4/mlx4_core.ko"
	"${KERNEL_TREE}/drivers/net/ethernet/mellanox/mlx4/mlx4_en.ko"
	"${KERNEL_TREE}/drivers/infiniband/hw/mlx4/mlx4_ib.ko"
)

for module in "${MODULES[@]}"; do
	verify_module "$module"
done
verify_mlx4_ib_symbol_versions

if [ "$BUILD_ONLY" -eq 1 ]; then
	log "build-only complete"
	log "log=${LOG}"
	exit 0
fi

if [ -z "$BACKUP_DIR" ]; then
	BACKUP_DIR="${REPO_ROOT}/module-backups/${KVER}/cx3pro-inbox-rocev2.backup-${TS}"
fi

if [ "$NO_BACKUP" -eq 0 ] && [ -d "$INSTALL_DIR" ]; then
	log "=== backup current installed modules ==="
	run mkdir -p "$(dirname "$BACKUP_DIR")"
	run cp -a "$INSTALL_DIR" "$BACKUP_DIR"
	log "backup_dir=${BACKUP_DIR}"
	log
fi

log "=== install modules ==="
run mkdir -p "$INSTALL_DIR"
for module in "${MODULES[@]}"; do
	install_module "$module"
done
log

log "=== update module config and dependency database ==="
disable_conflicting_overrides
write_module_config
run depmod "$KVER"
run update-initramfs -u -k "$KVER"
log

log "=== dependency check ==="
run modprobe --show-depends -S "$KVER" mlx4_core
run modprobe --show-depends -S "$KVER" mlx4_en
run modprobe --show-depends -S "$KVER" mlx4_ib
for module in mlx4_core mlx4_en mlx4_ib; do
	resolved="$(modinfo -k "$KVER" -n "$module")"
	case "$resolved" in
	"${INSTALL_DIR}/"*)
		log "resolved ${module} to ${resolved}"
		;;
	*)
		log "error: ${module} resolves to ${resolved}, not ${INSTALL_DIR}"
		exit 1
		;;
	esac
done
log

log "install complete"
if [ "$NO_BACKUP" -eq 0 ] && [ -d "$BACKUP_DIR" ]; then
	log "rollback backup directory:"
	log "  ${BACKUP_DIR}"
fi
log "reboot into ${KVER}, then verify with:"
log "  modinfo -n mlx4_core mlx4_en mlx4_ib"
log "  journalctl -k -b -g 'BUG|Oops|WARNING|Call Trace|mlx4|Unknown symbol|disagrees' --no-pager"
log "log=${LOG}"
