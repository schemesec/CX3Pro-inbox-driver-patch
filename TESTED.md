# Tested

This repo is experimental and was created with AI assistance for a specific
homelab CX3 Pro setup. It is not a production driver source.

## pvs3

- Host: `pvs3`
- Kernel: `7.0.2-2-pve`
- Module install path: `/lib/modules/7.0.2-2-pve/updates/cx3pro-inbox-rocev2`
- Patch repo commit tested: `4c224e9`

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

Current open item:

- Boot still logs `ib_core` WARN/Call Trace entries during VF RDMA probe
  cleanup. The VF RDMA devices come up and expose RoCEv2 GIDs, but this is not
  considered clean yet.
