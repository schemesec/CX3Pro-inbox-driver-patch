#!/usr/bin/env bash
set -euo pipefail

TESTED_KERNELS="${TESTED_KERNELS:-7.0.2-2-pve 7.0.2-6-pve}"
KVER="${KVER:-$(uname -r)}"
INSTALL_DIR="${INSTALL_DIR:-/lib/modules/${KVER}/updates/cx3pro-inbox-rocev2}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${1:-}"

usage() {
	cat <<EOF
Usage: $0 [backup-dir]

Restore a previous CX3 Pro inbox-patch module install backup and refresh initramfs.

If backup-dir is omitted, the newest repo backup matching:
  module-backups/${KVER}/cx3pro-inbox-rocev2.backup-*
is used.

Environment:
  KVER=...           Kernel release. Default: uname -r.
  INSTALL_DIR=...    Installed module directory. Default:
                     /lib/modules/$KVER/updates/cx3pro-inbox-rocev2
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	usage
	exit 0
fi

case " $TESTED_KERNELS " in
*" $KVER "*) ;;
*) echo "error: this rollback script is validated for: $TESTED_KERNELS; current target is $KVER" >&2; exit 1 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
	echo "error: rollback requires root" >&2
	exit 1
fi

if [ -z "$BACKUP_DIR" ]; then
	BACKUP_DIR="$(find "${REPO_ROOT}/module-backups/${KVER}" -maxdepth 1 -type d \
		-name "cx3pro-inbox-rocev2.backup-*" -printf '%T@ %p\n' 2>/dev/null |
		sort -nr | awk 'NR == 1 {print $2}')"
fi

if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
	echo "error: backup directory not found: ${BACKUP_DIR:-<none>}" >&2
	exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
FAILED_DIR="${INSTALL_DIR}.failed-${TS}"

echo "restore_from=${BACKUP_DIR}"
echo "install_dir=${INSTALL_DIR}"
if [ -d "$INSTALL_DIR" ]; then
	echo "saving_current=${FAILED_DIR}"
	mv "$INSTALL_DIR" "$FAILED_DIR"
fi

cp -a "$BACKUP_DIR" "$INSTALL_DIR"
depmod "$KVER"
update-initramfs -u -k "$KVER"

echo "rollback complete; reboot is required to activate restored modules"
echo "current install restored from ${BACKUP_DIR}"
