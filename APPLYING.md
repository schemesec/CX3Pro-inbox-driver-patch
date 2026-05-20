# Applying

This patch is intended for the Proxmox `pve-kernel` packaging tree, under
`patches/kernel/`.

The current patch adds SR-IOV VF handling for `MLX4_SET_PORT_ROCE_ADDR` in the
inbox `mlx4` path, preserves per-GID RoCE version in the PF-managed VF GID
cache, and uses that cached type when `mlx4_ib` builds VF RoCE packets.

It is not an OFED replacement and does not patch NVMe/RDMA target code.

For the install-script workflow, use:

```sh
./install-pve7.sh
```

The script fetches a Proxmox `pve-kernel` checkout, applies the patch, builds
only `mlx4_core.ko`, `mlx4_en.ko`, and `mlx4_ib.ko` for the current kernel, and
installs them below `/lib/modules/<kernel>/updates/cx3pro-inbox-rocev2`.
It does not install a replacement RDMA core or NVMe/RDMA stack.

The patch keeps the firmware RoCE v1/v2 capability visible in multifunction
mode by default using the `mlx4_core.enable_mfunc_roce_v2` module parameter.
This is needed for the inbox RDMA core to register RoCEv2 GIDs for PFs and VFs.

If stale OFED override modules/config are present from previous testing, the
script backs them up and removes them from the active module path before
running `depmod`. The dependency check must resolve `mlx4_core`, `mlx4_en`, and
`mlx4_ib` to `updates/cx3pro-inbox-rocev2`.

## Current validation

On `pvs3`, the patch was pulled from this repository, applied to a Proxmox
`pve-kernel` test checkout, and the two touched C objects were compile-tested:

```sh
make drivers/net/ethernet/mellanox/mlx4/port.o \
     drivers/infiniband/hw/mlx4/qp.o -j$(nproc)
```

Both objects built successfully. A full kernel package build has not been
completed yet.

The installer was then tested on `pvs3` with `--build-only`, followed by
`--no-build` installation. After `depmod`, all three mlx4 modules resolved to
`/lib/modules/7.0.2-2-pve/updates/cx3pro-inbox-rocev2`, and `mlx4_ib` resolved
against the stock inbox `ib_core`/`ib_uverbs`.
