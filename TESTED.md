# Tested

This repo is experimental and was created with AI assistance for a specific
homelab CX3 Pro setup. It is not a production driver source.

## pvs3

- Host: `pvs3`
- Kernel: `7.0.2-2-pve`
- Module install path: `/lib/modules/7.0.2-2-pve/updates/cx3pro-inbox-rocev2`
- Patch repo commit tested: `8dea678`

Validated:

- `install-pve7.sh --build-only --no-apt` builds `mlx4_core.ko`, `mlx4_en.ko`,
  and `mlx4_ib.ko` with matching vermagic.
- `mlx4_ib.ko` symbol CRCs match the patched `mlx4_core.ko` exports.
- `install-pve7.sh --no-build` installs the modules, runs `depmod`, updates
  initramfs, and makes `modprobe --show-depends` resolve all three `mlx4`
  modules from `updates/cx3pro-inbox-rocev2`.
- After reboot, `mlx4_core.enable_mfunc_roce_v2=Y`.
- PF RDMA device `rocep23s0` exposes RoCEv2 GIDs for `enp23s0`,
  `enp23s0.10`, and `enp23s0.20`.
- Host-owned VF RDMA devices `mlx4_0` through `mlx4_7` expose RoCEv2 GIDs for
  `enp23s0v0` through `enp23s0v7`.
- `verify-pve7.sh` passes after reboot, including the kernel warning scan for
  `BUG`, `Oops`, `WARNING`, `Call Trace`, `Unknown symbol`, `disagrees`,
  `__warn`, and `vhcr command:0x3a`.

Previously observed and fixed:

- VF reprobe from `cx3pro-sriov-vfs.service` used to trigger `ib_core`
  `ib_free_cq` / `rdma_restrack_clean` WARNs through `mlx4_ib_remove`.
  Commit `8dea678` fixes this by destroying nested RoCEv2 GSI QPs for all SQP
  owners, including tunnel/proxy QPs, before CQ teardown.
