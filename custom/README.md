# Custom NSS build for Linksys MX5300 and MX4200v1

This branch is OpenWrt 25.12.6 with the NSS patches of
[qosmio/openwrt-ipq](https://github.com/qosmio/openwrt-ipq) `25.12-nss` and a
few fixes, built for two devices: the Linksys MX5300 and the MX4200v1.

- Base: OpenWrt tag `v25.12.6` (kernel 6.12.112, mac80211 backports 6.18.55).
- NSS: the commits of qosmio/openwrt-ipq `25.12-nss` (`d6848fa2ea`), rebased
  onto `v25.12.6`. That branch was based on an earlier 25.12 snapshot (kernel
  6.12.91, backports 6.18.26).
- Feeds: the commits pinned by `v25.12.6`, plus qosmio/nss-packages
  `NSS-12.5-K6.x` (NSS firmware 11.4 is selected in the configs, as needed for
  NSS mesh). All pinned in `custom/feeds.conf`.
- Images: see the Releases page of this repository.

The previous build of these devices was based on AgustinLorenzo/openwrt
(release `ipq807x-nsswifi-unified-2026-07-13-2054`, a main-branch snapshot) and
is kept at [nanotech17/openwrt](https://github.com/nanotech17/openwrt).

## Changes from qosmio `25.12-nss`

| Commit | Change |
|---|---|
| `qualcommax: NSS: rebase patches for 6.12.112` | Three patches taken from AgustinLorenzo/openwrt `0c375ad6fc` (6.12.95 rebase); the bonding LAG patch adapted to 6.12.112 |
| `ath11k_nss: rebase patches for backports 6.18.55` | Five patches adapted by hand (details in the commit message), the rest refreshed |
| `ath11k_nss: fix AP_VLAN ext_vdev cleanup and open error path`, `ath11k_nss: drop memcpy workaround for mcast_rate` | Ported from qosmio/openwrt-ipq `main-nss` (not in `25.12-nss`) |
| `qualcommax: switch to wpad-openssl, libustream-openssl and apk-openssl` | Ported from AgustinLorenzo/openwrt `a9fd5032a7`, as in the previous build |

## Fixes and settings of this build

| # | Change | Where | Devices |
|---|---|---|---|
| 1 | ath11k NSS mesh: drop "mpath not found" exception packets | commit on this branch (`package/kernel/mac80211/patches/nss/ath11k/999-990-...`) | both |
| 2 | Disable tx checksum offload on ath10k mesh interfaces too | commit on this branch (`disable_mesh_chksum_ath11k.hotplug`) | both (only matters with ath10k radios, i.e. the MX5300's QCA9984) |
| 3 | qca-nss-clients tunipip6: release the route in the encap exception path | `custom/patches/nss_packages/` (applied to the nss_packages feed) | both |
| 4 | Set ECM `accel_delay_pkts` to 24 at boot | `custom/files/mx5300/` | MX5300 only |
| 5 | One device per config, package selection | `custom/configs/<device>.config` | per device |

### 1. ath11k NSS mesh "mpath not found" exceptions

With 802.11s mesh offloaded to NSS, NSS returns a packet to the host when it has
no mesh path for the destination. The driver re-sent the packet after
`eth_type_trans()` had removed the Ethernet header. mac80211 then read the start
of the IP header as the destination MAC address and created bogus mesh paths
(`60:xx:...` for IPv6). These paths fill the NSS mesh path table. Once the table
is full, adding real paths fails too, and the log fills with
`failed to add an entry to mpath table`.

The fix drops these packets. They were never delivered before either. Path
discovery does not depend on them, because NSS reports a separate
`PATH_NOT_FOUND` event for that.

An alternative fix was tested first: keep the Ethernet header and re-send the
packet. Under load it made an MX5300 reset without any kernel message, so it is
not used.

Without this fix, restarting `wpad` (`/etc/init.d/wpad restart`) clears both
tables for a while, and so does a reboot.

### 2. ath10k mesh checksum offload

The NSS patches already turn off `tx-checksumming` on ath11k mesh interfaces.
ath10k mesh interfaces need the same workaround. With checksum offload on, TCP
over the mesh link fails or crawls while ping works.

### 3. tunipip6 (DS-Lite) dst leak

`nss_tunipip6_encap_exception()` did not release the route it looked up when it
passed a packet up to the stack. Every such packet leaked a dst entry, and
`ip_dst_cache` (SUnreclaim) grew without bound. The leak was large with
`accel_delay_pkts=24` on DS-Lite. The fix adds the missing `ip_rt_put()`.

### 4. `accel_delay_pkts=24` (MX5300 only)

The `qca-nss-ecm` init script writes `1` to
`/sys/kernel/debug/ecm/ecm_classifier_default/accel_delay_pkts` every time it
loads ECM. With `1`, ECM never accelerates non-TCP connections until it has seen
packets in both directions. DS-Lite traffic and one-way UDP therefore stay on
the CPU.

With `24`, ECM handles the first 24 packets of each connection on the CPU and
then accelerates the connection, even if traffic flows in one direction only.
`/etc/init.d/ecm-accel-delay` (START=27, after ECM) writes the value at boot. A
uci-defaults script enables it on the first boot, so the value is 24 after a
`sysupgrade` with or without kept settings.

Notes:

- Any value other than `1` applies the DSCP and mark seen in one direction to
  both directions. This can affect QoS classification and mwan3 or policy
  routing marks.
- On MAP-E, values other than `1` were seen to stall upstream UDP when a
  translated port was reused. Check this before using such a value on MAP-E.
- Restarting ECM (`/etc/init.d/qca-nss-ecm restart`) writes `1` again. Run
  `/etc/init.d/ecm-accel-delay start` afterwards.

### 5. Configs

Each config selects one device only, without `ALL_KMODS`. The package selection
is the same as in the previous build (AgustinLorenzo-based), converted to 25.12
with `make defconfig`; 25.12 adds `kmod-nf-conntrack6`.

- `mx5300.config`: AgustinLorenzo's release package set plus a few extras
  (`tcpdump-mini`, `conntrack`, `ipip`, ...).
- `mx4200v1.config`: adds statistics and steering packages (`collectd` with
  `luci-app-statistics`, `lm-sensors`, `dawn`, `usteer`, `umdns`, `iperf3`).
  Leaves out `adblock`, `tailscale` and `tcpdump`.

Both configs set `CONFIG_KERNEL_BUILD_USER="builder"` and
`CONFIG_KERNEL_BUILD_DOMAIN="buildhost"`, and leave the `nss_packages` and
`sqm_scripts_nss` feeds out of `distfeeds.conf`.

### Known issue: dynamic MU-EDCA

The NSS patch `203-mac80211-ath11k-fw-dynamic-muedca` adds
`NL80211_CMD_UPDATE_HE_MUEDCA_PARAMS` and `NL80211_ATTR_HE_MUEDCA_PARAMS` at the
end of the kernel's nl80211 enums, and the hostapd patch `900` adds them at the
end of hostapd's copy of `nl80211.h`. The two copies have different numbers of
entries, so the numbers do not match and hostapd does not see the driver's
MU-EDCA updates. This is the same in qosmio `25.12-nss`. Wi-Fi works otherwise.

## Building

On a host that can build OpenWrt (see the OpenWrt build system documentation):

```sh
git clone -b custom/v25.12.6-nss https://github.com/<this repository>.git openwrt
cd openwrt
custom/build.sh mx5300 -j$(nproc)      # or: custom/build.sh mx4200v1 -j$(nproc)
```

`custom/build.sh` does the following:

1. Writes `feeds.conf` from `custom/feeds.conf`.
2. Updates and installs the feeds.
3. Copies the nss-packages patch into the feed.
4. Puts `custom/files/<device>` in place as `files/`.
5. Copies the device config to `.config`.
6. Runs `make defconfig`, `make download` and `make`.

When switching devices in the same tree, just run it again with the other
device. The images are in `bin/targets/qualcommax/ipq807x/`.

## Installing

- From a running OpenWrt: use the `*-squashfs-sysupgrade.bin`
  (`sysupgrade <file>`, or LuCI). These Linksys devices have two firmware
  partitions. `sysupgrade` writes the inactive one, and
  `fw_setenv boot_part <1|2>` followed by `reboot` switches back to the other
  one.
- From the Linksys stock firmware: use the `*-squashfs-factory.bin`.
- Check the sha256 against `sha256sums` in the release.

These images are tested on one MX5300 and one MX4200v1 only. Use them at your
own risk.

## License

Same as OpenWrt and the respective packages (mostly GPL-2.0). The patches in this
branch are under the license of the files they modify.
