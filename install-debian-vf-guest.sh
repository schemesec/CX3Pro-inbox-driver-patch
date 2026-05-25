#!/usr/bin/env bash
set -euo pipefail

KVER="${KVER:-$(uname -r)}"
JOBS="${JOBS:-$(nproc)}"
BUILD_ROOT="${BUILD_ROOT:-/root/cx3pro-vf-build}"
INSTALL_DIR="${INSTALL_DIR:-/lib/modules/${KVER}/updates/cx3pro-vf-rocev2}"
NO_APT=0
BUILD_ONLY=0

usage() {
	cat <<EOF
Usage: $0 [--build-only] [--no-apt]

Build and install Debian guest mlx4 VF modules for RoCEv2 behind a host
running this repository's patched PF driver.

Environment:
  KVER=...        Guest kernel release. Default: uname -r.
  JOBS=...        Parallel build jobs. Default: nproc.
  BUILD_ROOT=...  Small extracted source/build tree.
  INSTALL_DIR=... Installed module override directory.

The guest must be rebooted after installation. The script does not configure
the guest interface address or modify host PF/VF VLAN/PFC policy.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--build-only) BUILD_ONLY=1 ;;
	--no-apt) NO_APT=1 ;;
	-h|--help) usage; exit 0 ;;
	*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERIES="$(printf '%s\n' "$KVER" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
SOURCE_PKG="linux-source-${SERIES}"
SOURCE_ARCHIVE="/usr/src/${SOURCE_PKG}.tar.xz"
IMAGE_PKG="linux-image-${KVER}"
LOG_DIR="${REPO_ROOT}/logs"
LOG="${LOG_DIR}/install-guest-vf-$(date +%Y%m%d-%H%M%S).log"
PATCHES=(
	"${REPO_ROOT}/patches/guest/0001-mlx4-vf-retain-rocev2-capability-with-patched-pf.patch"
	"${REPO_ROOT}/patches/guest/0002-mlx4-ib-vf-advertise-rocev2-without-pf-port-config.patch"
	"${REPO_ROOT}/patches/guest/0003-mlx4-en-vf-do-not-request-physical-flow-control.patch"
)

mkdir -p "$LOG_DIR"

log() {
	printf '%s\n' "$*" | tee -a "$LOG"
}

run() {
	log "+ $*"
	"$@" 2>&1 | tee -a "$LOG"
	local rc=${PIPESTATUS[0]}
	[ "$rc" -eq 0 ] || exit "$rc"
}

need_file() {
	[ -f "$1" ] || { log "error: missing required file: $1"; exit 1; }
}

if [ "$(id -u)" -ne 0 ]; then
	echo "error: run as root inside the Debian guest" >&2
	exit 1
fi

IMAGE_VERSION="$(dpkg-query -W -f='${Version}' "$IMAGE_PKG" 2>/dev/null || true)"
if [ -z "$IMAGE_VERSION" ]; then
	log "error: cannot determine installed package version for ${IMAGE_PKG}"
	exit 1
fi

log "=== CX3 Pro Debian VF RoCEv2 guest installer ==="
log "kernel=${KVER}"
log "kernel_package_version=${IMAGE_VERSION}"
log "source_package=${SOURCE_PKG}"
log "install_dir=${INSTALL_DIR}"

if [ "$NO_APT" -eq 0 ]; then
	run apt-get update
	run env DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
		build-essential bc flex bison libelf-dev libssl-dev dwarves \
		"linux-headers-${KVER}" nvme-cli "${SOURCE_PKG}=${IMAGE_VERSION}"
fi

need_file "/lib/modules/${KVER}/build/Makefile"
need_file "$SOURCE_ARCHIVE"
for patch_file in "${PATCHES[@]}"; do
	need_file "$patch_file"
done

SOURCE_VERSION="$(dpkg-query -W -f='${Version}' "$SOURCE_PKG" 2>/dev/null || true)"
if [ "$SOURCE_VERSION" != "$IMAGE_VERSION" ]; then
	log "error: ${SOURCE_PKG} version ${SOURCE_VERSION:-missing} does not match ${IMAGE_PKG} version ${IMAGE_VERSION}"
	log "install matching source with: apt-get install --allow-downgrades '${SOURCE_PKG}=${IMAGE_VERSION}'"
	exit 1
fi

run rm -rf "$BUILD_ROOT"
run mkdir -p "$BUILD_ROOT"
run tar -xJf "$SOURCE_ARCHIVE" -C "$BUILD_ROOT" --strip-components=1 \
	"linux-source-${SERIES}/drivers/net/ethernet/mellanox/mlx4" \
	"linux-source-${SERIES}/drivers/infiniband/hw/mlx4"

for patch_file in "${PATCHES[@]}"; do
	run patch -p1 -d "$BUILD_ROOT" -i "$patch_file"
done

run make -C "/lib/modules/${KVER}/build" \
	"M=${BUILD_ROOT}/drivers/net/ethernet/mellanox/mlx4" modules "-j${JOBS}"
run make -C "/lib/modules/${KVER}/build" \
	"M=${BUILD_ROOT}/drivers/infiniband/hw/mlx4" modules "-j${JOBS}"

for module in \
	"${BUILD_ROOT}/drivers/net/ethernet/mellanox/mlx4/mlx4_core.ko" \
	"${BUILD_ROOT}/drivers/net/ethernet/mellanox/mlx4/mlx4_en.ko" \
	"${BUILD_ROOT}/drivers/infiniband/hw/mlx4/mlx4_ib.ko"; do
	need_file "$module"
	case "$(modinfo -F vermagic "$module")" in
	"${KVER} "*) log "vermagic ok: $(basename "$module")" ;;
	*) log "error: vermagic mismatch: ${module}"; exit 1 ;;
	esac
done

if [ "$BUILD_ONLY" -eq 1 ]; then
	log "build-only complete; no modules installed"
	exit 0
fi

if [ -d "$INSTALL_DIR" ]; then
	BACKUP_DIR="${INSTALL_DIR}.backup-$(date +%Y%m%d-%H%M%S)"
	run mv "$INSTALL_DIR" "$BACKUP_DIR"
	log "previous override saved at ${BACKUP_DIR}"
fi

run mkdir -p "$INSTALL_DIR"
run cp "${BUILD_ROOT}/drivers/net/ethernet/mellanox/mlx4/mlx4_core.ko" "$INSTALL_DIR/"
run cp "${BUILD_ROOT}/drivers/net/ethernet/mellanox/mlx4/mlx4_en.ko" "$INSTALL_DIR/"
run cp "${BUILD_ROOT}/drivers/infiniband/hw/mlx4/mlx4_ib.ko" "$INSTALL_DIR/"
run depmod -a "$KVER"
if command -v update-initramfs >/dev/null 2>&1; then
	INITRAMFS_MODULES="/etc/initramfs-tools/modules"
	[ -f "$INITRAMFS_MODULES" ] || run touch "$INITRAMFS_MODULES"
	for module in mlx4_core mlx4_en mlx4_ib; do
		if ! grep -qxF "$module" "$INITRAMFS_MODULES"; then
			log "+ ensure initramfs includes patched ${module}"
			printf "%s\n" "$module" >> "$INITRAMFS_MODULES"
		fi
	done
	run update-initramfs -u -k "$KVER"
fi

log "install complete; reboot the Debian guest before validation"
log "expected guest result: passed-through VF publishes RoCE v2 GIDs"
