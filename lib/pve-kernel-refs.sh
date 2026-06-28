#!/usr/bin/env bash

CX3PRO_TESTED_KERNELS="7.0.2-2-pve 7.0.2-6-pve 7.0.12-1-pve"

pve_kernel_ref_for() {
	local kver="${1:-${KVER:-}}"

	case "$kver" in
	7.0.2-2-pve)
		printf '%s\n' 59dd19a1c4f66f932d222eac91f9f1454f9b10cc
		;;
	7.0.2-6-pve)
		printf '%s\n' 87f22e55de30d73b83722b86790394564036b33c
		;;
	7.0.12-1-pve)
		printf '%s\n' b8d87f8e97fa979f50d88673bd5be41de93ed2f3
		;;
	*)
		return 1
		;;
	esac
}

pve_kernel_is_tested() {
	local kver="${1:-${KVER:-}}"
	local tested="${2:-${TESTED_KERNELS:-$CX3PRO_TESTED_KERNELS}}"
	local item

	for item in $tested; do
		[ "$kver" = "$item" ] && return 0
	done
	return 1
}
