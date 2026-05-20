# Applying

This patch is intended for the Proxmox `pve-kernel` packaging tree, under
`patches/kernel/`.

The current patch adds SR-IOV VF handling for `MLX4_SET_PORT_ROCE_ADDR` in the
inbox `mlx4` path, preserves per-GID RoCE version in the PF-managed VF GID
cache, and uses that cached type when `mlx4_ib` builds VF RoCE packets.

It is not an OFED replacement and does not patch NVMe/RDMA target code.

## Current validation

On `pvs3`, the patch was pulled from this repository, applied to a Proxmox
`pve-kernel` test checkout, and the two touched C objects were compile-tested:

```sh
make drivers/net/ethernet/mellanox/mlx4/port.o \
     drivers/infiniband/hw/mlx4/qp.o -j$(nproc)
```

Both objects built successfully. A full kernel package build has not been
completed yet.
