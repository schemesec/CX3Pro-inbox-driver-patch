# Applying

This patch is intended for the Proxmox `pve-kernel` packaging tree, under
`patches/kernel/`.

The current patch adds SR-IOV VF handling for `MLX4_SET_PORT_ROCE_ADDR` in the
inbox `mlx4` path, preserves per-GID RoCE version in the PF-managed VF GID
cache, and uses that cached type when `mlx4_ib` builds VF RoCE packets. It
also keeps the RoCE v1/v2 device capability visible in multifunction mode by
default through `mlx4_core.enable_mfunc_roce_v2=1`.

It is not an OFED replacement and does not patch NVMe/RDMA target code.

For the install-script workflow, use:

```sh
./install-pve7.sh
```

For a kernel upgrade, first check whether the patch still applies to the source
for the running kernel:

```sh
./find-pve-kernel-ref "$(uname -r)"
./install-pve7.sh --apply-check-only --no-apt
```

For tested kernels with a known mapping, `install-pve7.sh` auto-selects the
validated Proxmox packaging ref. For any unlisted kernel, use the ref printed
by `find-pve-kernel-ref` and set `PVE_KERNEL_REF` explicitly. Do not rely on
the current repository default branch for a host that is running an older
kernel.

A clean apply check means the source-level patch applied and passed
`git diff --check`; it does not prove the modules build, boot, or pass RDMA
traffic. Run the full installer and verifier before treating a new kernel as
supported. `--strict-kernel` restores the old refuse-unlisted-kernels behavior.

For this project, "supported" requires lifecycle testing:

1. Rebuild/install the override modules for the target kernel.
2. Reboot.
3. Run `./port-validation --stage post-reboot` with `CLIENT_SSH` pointed at the
   peer RDMA host.
4. After a Proxmox package upgrade, rebuild/install again if the kernel changed,
   reboot, then run `./port-validation --stage post-upgrade`.

Both validation gates must include the VF RDMA-CM traffic test unless the skip
is explicitly documented for a non-traffic-only investigation.

The script fetches a Proxmox `pve-kernel` checkout, applies the patch, builds
only `mlx4_core.ko`, `mlx4_en.ko`, and `mlx4_ib.ko` for the current kernel, and
installs them below `/lib/modules/<kernel>/updates/cx3pro-inbox-rocev2`.
It does not install a replacement RDMA core or NVMe/RDMA stack.

When preparing a kernel upgrade, confirm the matching
`proxmox-headers-<kernel>` package is installed or available before the module
build. The `7.0.12-1-pve` upgrade required installing
`proxmox-headers-7.0.12-1-pve` explicitly; the full-upgrade simulation did not
pull that package by itself.

`mlx4_core` and `mlx4_ib` are the modules with source-level RoCEv2/SR-IOV
changes. `mlx4_en` is still built and installed from the same patched source
tree so the Ethernet, core, and IB parts of mlx4 are kept from one build and
one kernel source revision.

If stale OFED override modules/config are present from previous testing, the
script backs them up and removes them from the active module path before
running `depmod`. The dependency check must resolve `mlx4_core`, `mlx4_en`, and
`mlx4_ib` to `updates/cx3pro-inbox-rocev2`.

## Current validation

On `pvs3`, the installer and runtime tests have been validated against Proxmox
kernels `7.0.2-2-pve`, `7.0.2-6-pve`, and `7.0.12-1-pve`. Other kernels are
allowed by the installer as unvalidated targets and must pass the same checks
before being added to `TESTED_KERNELS`.

Known Proxmox packaging refs:

- `7.0.2-2-pve`: `59dd19a1c4f66f932d222eac91f9f1454f9b10cc`
- `7.0.2-6-pve`: `87f22e55de30d73b83722b86790394564036b33c`
- `7.0.12-1-pve`: `b8d87f8e97fa979f50d88673bd5be41de93ed2f3`

The full mlx4 module build completed for:

- `drivers/net/ethernet/mellanox/mlx4/mlx4_core.ko`
- `drivers/net/ethernet/mellanox/mlx4/mlx4_en.ko`
- `drivers/infiniband/hw/mlx4/mlx4_ib.ko`

The installer verifies vermagic, verifies that `mlx4_ib.ko` symbol CRCs match
the patched `mlx4_core.ko` exports it consumes, installs the modules under
`/lib/modules/<kernel>/updates/cx3pro-inbox-rocev2`, runs `depmod`, updates
initramfs, and checks that all three active mlx4 modules resolve to that update
directory.

After reboot and SR-IOV setup, `verify-pve7.sh` passed on `pvs3`: PF and
host-owned VF RDMA devices exposed RoCEv2 GIDs, VF VLAN and stable MAC policy
matched the requested configuration, and the bounded kernel warning scan found
no `BUG`, `Oops`, `WARNING`, `Call Trace`, `Unknown symbol`, `disagrees`,
`__warn`, or `vhcr command:0x3a` entries.

The `7.0.12-1-pve` dist-upgrade path was validated from a clean pre-upgrade
snapshot through post-upgrade reboot. `port-validation --stage post-upgrade`
passed with VF0-VF10 RDMA-CM traffic at `49.28-50.57 Gbit/sec`; VF11 was
skipped because it is bound to `vfio-pci`.

This workflow has not been converted into a full Proxmox kernel package build.
It is an out-of-tree module install flow for testing the inbox-driver patch.
