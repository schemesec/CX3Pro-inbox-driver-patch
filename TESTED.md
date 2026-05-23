# Tested

This repo is experimental and was created with AI assistance for a specific
homelab CX3 Pro setup. It is not a production driver source.

## pvs3

- Host: `pvs3`
- Kernel: `7.0.2-2-pve`
- Module install path: `/lib/modules/7.0.2-2-pve/updates/cx3pro-inbox-rocev2`
- Driver patch commit tested: `009a0ad`

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
- Cross-host host-owned VF RoCEv2 `ib_write_bw` from `pvs1` to all eight
  pvs3 host-owned VFs passes after reboot with IPv4 RoCEv2 GID index `3` on
  each VF. The test used pvs1 only as the `ib_write_bw` client and restored
  the pvs3 route to `enp23s0.20` after testing:

  ```text
  VF0 enp23s0v0 192.168.20.156 mlx4_1    49.40 Gbit/sec
  VF1 enp23s0v1 192.168.20.157 mlx4_2    49.48 Gbit/sec
  VF2 enp23s0v2 192.168.20.158 mlx4_3    49.30 Gbit/sec
  VF3 enp23s0v3 192.168.20.159 mlx4_4    50.50 Gbit/sec
  VF4 enp23s0v4 192.168.20.160 mlx4_5    49.96 Gbit/sec
  VF5 enp23s0v5 192.168.20.161 mlx4_6    49.48 Gbit/sec
  VF6 enp23s0v6 192.168.20.162 rocep23s0 50.18 Gbit/sec
  VF7 enp23s0v7 192.168.20.163 mlx4_7    50.52 Gbit/sec
  ```

  Result: 65536-byte RDMA write, RoCEv2 IPv4-mapped GIDs
  `192.168.20.50 -> 192.168.20.156-163`, RDMA MTU 2048. A post-test pvs3
  kernel warning scan returned no entries.
- Concurrent cross-host host-owned VF RoCEv2 `ib_write_bw` passes across all
  eight pvs3 VFs. Each VF used a distinct RDMA CM port and temporary
  source-based routing on pvs3 so replies used the matching VF netdev:

  ```text
  VF0 enp23s0v0 192.168.20.156 port 18515 6.70 Gbit/sec
  VF1 enp23s0v1 192.168.20.157 port 18516 6.65 Gbit/sec
  VF2 enp23s0v2 192.168.20.158 port 18517 6.76 Gbit/sec
  VF3 enp23s0v3 192.168.20.159 port 18518 6.65 Gbit/sec
  VF4 enp23s0v4 192.168.20.160 port 18519 6.74 Gbit/sec
  VF5 enp23s0v5 192.168.20.161 port 18520 6.64 Gbit/sec
  VF6 enp23s0v6 192.168.20.162 port 18521 6.64 Gbit/sec
  VF7 enp23s0v7 192.168.20.163 port 18522 6.80 Gbit/sec
  ```

  A post-test pvs3 kernel warning scan returned no entries. A prior local
  all-VF concurrency attempt without unique RDMA CM ports was invalid because
  multiple `ib_write_bw` servers tried to bind the same listen port.
- Twelve-VF SR-IOV mode is validated after changing `NUM_VFS=12` and
  rebooting. The card reported `sriov_totalvfs=32`, `sriov_numvfs=12`, and all
  twelve host-owned VF netdevs exposed IPv4 RoCEv2 GID index `3`. Sequential
  cross-host RoCEv2 `ib_write_bw` from `pvs1` to all twelve pvs3 VFs passed:

  ```text
  VF0  enp23s0v0  192.168.20.156 mlx4_1    49.66 Gbit/sec
  VF1  enp23s0v1  192.168.20.157 mlx4_2    50.55 Gbit/sec
  VF2  enp23s0v2  192.168.20.158 mlx4_3    49.50 Gbit/sec
  VF3  enp23s0v3  192.168.20.159 mlx4_4    50.65 Gbit/sec
  VF4  enp23s0v4  192.168.20.160 rocep23s0 49.79 Gbit/sec
  VF5  enp23s0v5  192.168.20.161 mlx4_5    50.54 Gbit/sec
  VF6  enp23s0v6  192.168.20.162 mlx4_6    49.51 Gbit/sec
  VF7  enp23s0v7  192.168.20.163 mlx4_7    49.69 Gbit/sec
  VF8  enp23s0v8  192.168.20.164 mlx4_8    49.94 Gbit/sec
  VF9  enp23s0v9  192.168.20.165 mlx4_9    50.58 Gbit/sec
  VF10 enp23s0v10 192.168.20.166 mlx4_10   49.54 Gbit/sec
  VF11 enp23s0v11 192.168.20.167 mlx4_11   49.68 Gbit/sec
  ```

  A post-test pvs3 kernel warning scan returned no entries. This is the largest
  VF count currently expected to preserve one IPv4 RoCEv2 GID for every VF with
  the patch's below-64 source GID index limit.
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

- After reboot into kernel `7.0.2-6-pve`, the compact VF RoCEv2 GID layout was validated with `NUM_VFS=12`, `MLX4_ROCE_PF_GIDS=8`, and two RoCEv2 GIDs per host-owned VF. `verify-pve7.sh` passed with stable VF MACs, VLAN 20 on all twelve VFs, PF VLAN IPs `192.168.10.56/24` and `192.168.20.56/24`, module resolution from `updates/cx3pro-inbox-rocev2`, and no bounded kernel warning matches. Sequential cross-host RDMA-CM RoCEv2 `ib_write_bw` from pvs1 `192.168.20.50` to pvs3 VF IPs `192.168.20.160-171` passed for all twelve VFs using local VF GID index `1`; results were 49.41-50.61 Gbit/sec average with IPv4-mapped RoCEv2 GIDs. The test used coupled listener/client orchestration with a three-second listener warm-up so approval delay could not invalidate the RDMA-CM run. A post-test pvs3 kernel scan for `BUG`, `Oops`, `WARNING`, `Call Trace`, `Unknown symbol`, `disagrees`, `__warn`, `Bad wc`, `Completion with error`, `Failed status`, and `vhcr command:0x3a` returned no entries.

## Fresh rollback validation, 2026-05-23

Validated from `rpool/ROOT/pve-1@fresh-install` booting kernel `7.0.2-6-pve` with repository commit `7e22b3a`:

- `cx3pro-install` confirmed ConnectX-3 Pro firmware `2.42.5000` without flashing, and the full-install dependency path was updated so the documented later `install-pve7.sh --no-apt` build has `flex`, `bison`, and related kernel build tools available.
- `install-pve7.sh` rebuilt and installed patched inbox `mlx4_core`, `mlx4_en`, and `mlx4_ib` modules with matching vermagic and symbol CRC checks; after reboot all resolve from `updates/cx3pro-inbox-rocev2`.
- `rocesetup` now persists PF MTU 9000, VLAN20 source routing, and disables IPv6 only on its managed VLAN subinterfaces by default. This prevents duplicate unused VLAN link-local GID registration that previously produced `MLX4_CMD_SET_PORT` (`vhcr command:0xc`) status `-22` and `add_roce_gid` errors at boot.
- After the corrected reboot, `verify-pve7.sh` passes with active PF/VF RDMA links, stable MACs and VLAN 20 on all 12 VFs, persistent PF VLAN addresses, firmware `2.42.5000`, and no `vhcr`, GID-add, mlx4 warning, symbol, or call-trace matches.
- PF inbound RoCEv2 RDMA-CM `ib_write_bw` from pvs1 to `192.168.20.56` passed at `49.63 Gbit/sec`. VF0 passed individually in both listener forms at `49.57-49.61 Gbit/sec`; a longer inbound run to VF4 passed at `50.09 Gbit/sec`.
- All twelve pvs3 VFs successfully initiated reverse-direction RDMA-CM connections to pvs1 after reboot, and the post-traffic pvs3 Mellanox/GID/VHCR scan returned no entries.

Unresolved in this validation run:

- A sequential pvs1-initiated sweep succeeded for VF0, then later VF targets reported an RDMA-CM client event failure; individual retry of VF1 passed. This requires additional isolation on pvs1 before claiming repeatable inbound multi-VF coverage for the corrected boot.
- Reverse-direction bandwidth was inconsistent across PF/VFs: long runs observed `16.51 Gbit/sec` on the PF, `18.93 Gbit/sec` on VF4, and `50.31 Gbit/sec` on VF3, while inbound VF4 reached `50.09 Gbit/sec`. Determine whether switching/lossless Ethernet configuration or host-side behavior explains this before accepting bidirectional performance.
- The host logs recurring corrected APEI PCIe errors for NVMe endpoint vendor `15b7`, device `5002`, separate from the Mellanox `15b3:1007` adapter.

Not yet repeated after the latest clean inbox-patch boot:

- Cross-host VF `ib_write_bw` from a VM-assigned passthrough VF.

Note: an earlier PF run failed with completion status 12 while pvs3 was at
MTU 1500 and the test negotiated RDMA MTU 1024. Re-running after restoring
`enp23s0`, `enp23s0.10`, and `enp23s0.20` to MTU 9000 passed.

Previously observed and fixed:

- VF reprobe from `cx3pro-sriov-vfs.service` used to trigger `ib_core`
  `ib_free_cq` / `rdma_restrack_clean` WARNs through `mlx4_ib_remove`.
  Commit `8dea678` fixes this by destroying nested RoCEv2 GSI QPs for all SQP
  owners, including tunnel/proxy QPs, before CQ teardown.
