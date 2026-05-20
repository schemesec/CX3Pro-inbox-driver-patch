# Applying

This patch is intended for the Proxmox `pve-kernel` packaging tree, under
`patches/kernel/`.

The current patch adds SR-IOV VF handling for `MLX4_SET_PORT_ROCE_ADDR` in the
inbox `mlx4` path, preserves per-GID RoCE version in the PF-managed VF GID
cache, and uses that cached type when `mlx4_ib` builds VF RoCE packets.

It is not an OFED replacement and does not patch NVMe/RDMA target code.
