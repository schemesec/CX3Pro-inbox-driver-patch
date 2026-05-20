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

The script fetches a Proxmox `pve-kernel` checkout, applies the patch, builds
only `mlx4_core.ko`, `mlx4_en.ko`, and `mlx4_ib.ko` for the current kernel, and
installs them below `/lib/modules/<kernel>/updates/cx3pro-inbox-rocev2`.
It does not install a replacement RDMA core or NVMe/RDMA stack.

`mlx4_core` and `mlx4_ib` are the modules with source-level RoCEv2/SR-IOV
changes. `mlx4_en` is still built and installed from the same patched source
tree so the Ethernet, core, and IB parts of mlx4 are kept from one build and
one kernel source revision.

If stale OFED override modules/config are present from previous testing, the
script backs them up and removes them from the active module path before
running `depmod`. The dependency check must resolve `mlx4_core`, `mlx4_en`, and
`mlx4_ib` to `updates/cx3pro-inbox-rocev2`.

## Current validation

On `pvs3`, the installer has been tested against Proxmox kernel
`7.0.2-2-pve`. The full mlx4 module build completed for:

- `drivers/net/ethernet/mellanox/mlx4/mlx4_core.ko`
- `drivers/net/ethernet/mellanox/mlx4/mlx4_en.ko`
- `drivers/infiniband/hw/mlx4/mlx4_ib.ko`

The installer verifies vermagic, verifies that `mlx4_ib.ko` symbol CRCs match
the patched `mlx4_core.ko` exports it consumes, installs the modules under
`/lib/modules/7.0.2-2-pve/updates/cx3pro-inbox-rocev2`, runs `depmod`, updates
initramfs, and checks that all three active mlx4 modules resolve to that update
directory.

After reboot and SR-IOV setup, `verify-pve7.sh` passed on `pvs3`: PF and
host-owned VF RDMA devices exposed RoCEv2 GIDs, VF VLAN and stable MAC policy
matched the requested configuration, and the bounded kernel warning scan found
no `BUG`, `Oops`, `WARNING`, `Call Trace`, `Unknown symbol`, `disagrees`,
`__warn`, or `vhcr command:0x3a` entries.

This workflow has not been converted into a full Proxmox kernel package build.
It is an out-of-tree module install flow for testing the inbox-driver patch.
