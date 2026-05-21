# Tested

This repo is experimental and was created with AI assistance for a specific
homelab CX3 Pro setup. It is not a production driver source.

## pvs3

- Host: `pvs3`
- Kernel: `7.0.2-2-pve`
- Module install path: `/lib/modules/7.0.2-2-pve/updates/cx3pro-inbox-rocev2`
- Patch repo commit tested: `349b632`

Validated:

- `install-pve7.sh --build-only --no-apt` builds `mlx4_core.ko`, `mlx4_en.ko`,
  and `mlx4_ib.ko` with matching vermagic.
- `mlx4_ib.ko` symbol CRCs match the patched `mlx4_core.ko` exports.
- `install-pve7.sh --no-build` installs the modules, runs `depmod`, updates
  initramfs, and makes `modprobe --show-depends` resolve all three `mlx4`
  modules from `updates/cx3pro-inbox-rocev2`.
- After reboot, `mlx4_core.enable_mfunc_roce_v2=Y`.
- PF RDMA device `mlx4_0` exposes RoCEv2 GIDs for `enp23s0`,
  `enp23s0.10`, and `enp23s0.20`.
- Host-owned VF RDMA devices expose RoCEv2 GIDs for `enp23s0v0` through
  `enp23s0v7`. RDMA device names are not stable across boots; map them from
  `/sys/class/infiniband/*/ports/*/gid_attrs/ndevs/*` instead of hardcoding
  names in tests.
- `verify-pve7.sh` passes after reboot, including the kernel warning scan for
  `BUG`, `Oops`, `WARNING`, `Call Trace`, `Unknown symbol`, `disagrees`,
  `__warn`, and `vhcr command:0x3a`.
- Cross-host PF RoCEv2 `ib_write_bw` from `pvs1` to `pvs3` passes after
  setting the pvs3 PF/VLAN MTU back to 9000:

  ```sh
  # pvs3 server
  ib_write_bw -d rocep23s0 -i 1 -R -x 5 -F --report_gbits -s 65536

  # pvs1 client
  ib_write_bw -d mlx4_0 -i 1 -R -x 5 -F --report_gbits -s 65536 192.168.20.56
  ```

  Result: 65536-byte RDMA write, RoCEv2 IPv4-mapped GIDs
  `192.168.20.50 -> 192.168.20.56`, RDMA MTU 2048, 49.25 Gbit/sec average.
  A post-test pvs3 kernel warning scan returned no entries.
- Local host-owned VF RoCEv2 `ib_write_bw` passes on pvs3 after reboot.
  On this boot VF0 mapped to RDMA device `rocep23s0`, netdev `enp23s0v0`,
  with IPv4 RoCEv2 GID index `3` for `192.168.20.156`:

  ```sh
  ib_write_bw -d rocep23s0 -i 1 -R -x 3 -F --report_gbits -s 65536
  ib_write_bw -d rocep23s0 -i 1 -R -x 3 -F --report_gbits -s 65536 192.168.20.156
  ```

  Result: 65536-byte RDMA write, RoCEv2 IPv4-mapped GIDs
  `192.168.20.156 -> 192.168.20.156`, RDMA MTU 2048, 46.80 Gbit/sec average.
  A post-test pvs3 kernel warning scan returned no entries.
- Stock inbox `nvme-rdma` initiator on `pvs3` can discover and connect to the
  existing pvs1 NVMe/RDMA target over RoCEv2:

  ```sh
  nvme discover -t rdma -a 192.168.20.51 -s 4420
  nvme connect -t rdma -n schemesec:nvme:rg-pve0 -a 192.168.20.51 -s 4420
  nvme list
  nvme disconnect -n schemesec:nvme:rg-pve0
  ```

  Discovery returned `schemesec:nvme:rg-pve0`; connect created
  `/dev/nvme1n1` as a 3.76 TB Linux NVMe target using 12 I/O queues. A
  read-only identify/size check completed, the controller disconnected cleanly,
  and a pvs3 kernel warning scan returned no entries.

Not yet repeated after the latest clean inbox-patch boot:

- Cross-host VF `ib_write_bw` performance from a VM-assigned VF.

Note: an earlier PF run failed with completion status 12 while pvs3 was at
MTU 1500 and the test negotiated RDMA MTU 1024. Re-running after restoring
`enp23s0`, `enp23s0.10`, and `enp23s0.20` to MTU 9000 passed.

Previously observed and fixed:

- VF reprobe from `cx3pro-sriov-vfs.service` used to trigger `ib_core`
  `ib_free_cq` / `rdma_restrack_clean` WARNs through `mlx4_ib_remove`.
  Commit `8dea678` fixes this by destroying nested RoCEv2 GSI QPs for all SQP
  owners, including tunnel/proxy QPs, before CQ teardown.
