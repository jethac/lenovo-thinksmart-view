# lk2nd for the Lenovo ThinkSmart View (CD-18781Y)

This directory builds lk2nd for the `boot` partition. Lenovo's locked `aboot` loads it, and it then
boots Linux from `/extlinux/extlinux.conf`, as described in `../rootfs/README.md`.

**Nothing here has been run on the tablet.**

| | |
| --- | --- |
| Image | `out/lk2nd.img`, 359 735 bytes |
| SHA-256 | `1f03a9f38a07a88a8875b2b444367fd9b3986609e6c10cd5e7b927cee39c6965` (also in `out/lk2nd.img.sha256`) |
| Source | `msm8916-mainline/lk2nd` `main` at `fd380ac637d1af38598e3f3c5321d4c962b96315` (2026-10-20, "dts: msm8909: Add Panasonic Toughbook FZ-T1"). The version string is `23.1-next-fd380ac6-20261020` |
| Target | `lk2nd-msm8953` |
| Build flags | `TOOLCHAIN_PREFIX=arm-none-eabi- SIGN_BOOTIMG=1 LK2ND_QCDTBS=""`, the flags that the device DTS asks for |
| Toolchain | Arch `arm-none-eabi-gcc` 16.2.0, `arm-none-eabi-binutils` 2.47, `arm-none-eabi-newlib` 4.6.0, `dtc` 1.8.1, Python 3.14. This is the Arch toolchain named in `Documentation/building.md`. It was already installed, so no tarball was needed |
| Signing deps | `pyasn1==0.6.1`, `pyasn1-modules==0.4.2`, `pycryptodome==3.23.0`, installed with `uv` into `downloads/venv`. They are not installed system-wide |
| Reproducible | Yes. Two separate clean clones gave the same SHA-256 |

## Rebuild

```sh
./build.sh          # clones over SSH into work/lk2nd-<commit>, builds, checks, copies to out/
```

`build.sh` stops with an error in any of these cases:

- the image is larger than the boot partition
- the header carries a QCDT (`dt_size` ≠ 0)
- the `SEANDROIDENFORCE` trailer is missing

`tools/inspect-bootimg.py` prints the header and the trailing data of a boot image.

## How lk2nd recognises this board

1. **Choosing lk2nd's own DTB.** The image holds 28 DTBs appended after `lk.bin` (`ADTBS` in
   `lk2nd/device/dts/msm8953/rules.mk`). lk2nd selects one with the usual Qualcomm SMEM matching
   (`platform/msm_shared/dev_tree.c`): SoC id, hardware platform and subtype.
   `apq8053-lenovo-cd-18781y.dtb` is the first DTB in the image, and it is the only one with
   `qcom,msm-id = <0x130 0>` (304, `QCOM_ID_APQ8053`) and `qcom,board-id = <0x1010520 0>`. The
   stock device tree has the same two values (`../stock/stock-device-tree.dts`, lines 9–10). I
   extracted that DTB from `out/lk2nd.img` and checked its contents.
2. **Device node.** `/lk2nd` has `compatible = "lenovo,cd-18781y"` and
   `model = "Lenovo ThinkSmart View"`. Because the root `/lk2nd` node carries a compatible, it
   always matches (`find_device_node()` in `lk2nd/device/device.c`). `lk2nd,dtb-files =
   "apq8053-lenovo-cd-18781y"` is the name used for `fdtdir` lookups in extlinux. The menu keys
   are Volume Down to move and Volume Up to select: Volume Up is remapped to `KEY_POWER`, because
   the device has no power button.
3. **Choosing the panel.** lk2nd does not probe the panel. It reads `mdss_mdp.panel=` from the
   command line that `aboot` passes to it (`lk2nd/device/2nd/parse-cmdline.c`, `parse_panel()`).
   On this unit that is
   `mdss_mdp.panel=1:dsi:0:qcom,mdss_dsi_boyift8201_800p_video:1:none:cfg:single_dsi`
   (`../backup-20261029/cmdline.txt`), so the panel name is
   `qcom,mdss_dsi_boyift8201_800p_video`. `lk2nd_panel_detect()` (`lk2nd/device/panel.c`) looks
   for a subnode with that name under the `lk2nd,panel` node. Before booting, it then edits the
   **kernel's** DTB:
   - The node with `compatible = "lenovo,cd-18781y-panel"` is given `"lenovo,cd-18781y-ft8201"`.
     Our 7.3 DTS has this node (`panel@0`), and the driver
     `panel-lenovo-cd-18781y-ft8201.c` binds to that compatible.
   - On the `focaltech,ft8201` touchscreen node, the `status` property is NOPed. In our DTS that
     node is `touchscreen@38` and has `status = "disabled"`, so this enables it.

   The three panel variants are handled differently:

   | Stock panel node | What lk2nd does |
   | --- | --- |
   | `qcom,mdss_dsi_boyift8201_800p_video` (this unit) | Sets compatible `lenovo,cd-18781y-ft8201` and enables `focaltech,ft8201` |
   | `qcom,mdss_dsi_hx83100a_800p_video` | Sets compatible `lenovo,cd-18781y-hx83100a` and enables `himax,hx83100a` |
   | `qcom,mdss_dsi_starry_800p_video` (JD9365) | **Not supported.** lk2nd prints `Unsupported panel` and leaves the DTB unchanged, so no panel driver binds. The kernel does have `panel-lenovo-cd-18781y-jd9365.c` |

   This unit uses the FT8201 path.

   > **Correction for GOAL.md.** Its hardware table lists the touchscreen as Himax HX83100A.
   > The stock inventory shows otherwise: `i2c 3-0038 fts` and the input device `fts_ts`, with
   > `[FTS_TS]` lines in `../stock/stock-dmesg-20261030.txt`. That is FocalTech, which is the
   > touchscreen lk2nd enables for the FT8201 panel. `3-0048 hxcommon` is also probed, but stock
   > uses `fts_ts`.

## Signing for this aboot

**Findings.**

- **lk2nd's build.** `SIGN_BOOTIMG=1` runs `lk2nd/scripts/bootsignature.py -s -t /boot` after
  mkbootimg. By default it uses the AOSP 13 verity test key `lk2nd/certs/verity.{pk8,x509.pem}`
  (`lk2nd/device/2nd/rules.mk` and `lk2nd/project/lk2nd.mk`). The step appends an AVB1
  (`BootSignature`) DER blob after the page-aligned payload, then `SEANDROIDENFORCE`.
  - Without the flag, lk2nd images are **not** signed.
  - There is no `SIGNED_KERNEL` and no AVB2/vbmeta step for msm8953.
  - The option was added for this device by Felix Kaechele in
    [PR #381](https://github.com/msm8916-mainline/lk2nd/pull/381) ("Tested and working on Lenovo
    ThinkSmart View").
- **What the device DTS says.** `lk2nd/device/dts/msm8953/apq8053-lenovo-cd-18781y.dts`:
  - Secure Boot cannot be disabled, because unlocking makes the stock lk crash.
  - "the device will happily boot any AVB1 signed image".
  - Build with `SIGN_BOOTIMG=1 LK2ND_QCDTBS=""`.
  - Flash with `edl w boot …`.
- **Forum.** In the [Home Assistant thread](https://community.home-assistant.io/t/lenovo-thinksmart-view-rom-os-development/676324):
  - mattmon, [post #5](https://community.home-assistant.io/t/lenovo-thinksmart-view-rom-os-development/676324/5)
    (2024-01-20): "the boot loader would attempt loading any boot.img with a signature …
    Literally any signature, it's just needs to be signed."
  - Before PR #381, people signed images with `magiskboot sign`
    ([#208](https://community.home-assistant.io/t/lenovo-thinksmart-view-rom-os-development/676324/208),
    [#210](https://community.home-assistant.io/t/lenovo-thinksmart-view-rom-os-development/676324/210)).
  - FelixKa, [#414](https://community.home-assistant.io/t/lenovo-thinksmart-view-rom-os-development/676324/414)
    (2024-08-14): the lk2nd build can now "output correctly signed binaries without needing to use
    magiskboot sign".
- **Why any signature works (from the stock `aboot` in the backup).** I read the strings in
  `backup-20261029/partitions/aboot.img.zst`. It is CAF LK with
  `platform/msm_shared/boot_verifier.c`, and includes the strings "RSA is null from the embedded
  certificate", "Keystore verification failed! Continuing anyways…", "verification failure due to
  target name mismatch" and "image length is different". From these strings I infer the
  following; I have not disassembled `aboot`:
  - `aboot` checks the signature against the certificate **embedded in the signature**.
  - The OEM keystore check that follows fails, and `aboot` carries on anyway.
  - The checks that remain:
    - the signature is a well-formed AVB1 `BootSignature`
    - its target is `/boot`
    - its signed length equals the image payload
    - it verifies against its own certificate
- **More evidence from this unit.** The stock LineageOS `boot.img` in the backup carries an AVB1
  signature from the **same AOSP test certificate**. The SHA-256 fingerprint is
  `8A:D1:27:AB:…:3B:86`, the same as `lk2nd/certs/verity.x509.pem`. The stock command line also
  reports `androidboot.verifiedbootstate=green`. So this `aboot` already boots an image signed with
  that key.
- **postmarketOS wiki** (`wiki.postmarketos.org/wiki/Lenovo_ThinkSmart_View_(lenovo-cd-18781y)`,
  now redirecting to `wiki.nura.eco`). I could not read it: an Anubis bot-check blocks
  non-browser fetches. Forum posts
  [#505](https://community.home-assistant.io/t/lenovo-thinksmart-view-rom-os-development/676324/505)
  and [#614](https://community.home-assistant.io/t/lenovo-thinksmart-view-rom-os-development/676324/614)
  say that the wiki's instructions build lk2nd from main with the flags above.

**What `out/lk2nd.img` has.**

| | |
| --- | --- |
| Header | Android boot image v0 |
| Trailer | Payload of 358 400 bytes, then a 1 319-byte AVB1 `BootSignature`, then `SEANDROIDENFORCE` |
| Signature | Target `/boot`, signed length `0x57800` = 358 400, which matches the payload. I verified the RSA-2048/SHA-256 signature over `image[0:358400] ‖ DER(authattrs)` with `openssl dgst -verify` against the embedded certificate: `Verified OK` |
| Embedded certificate | The AOSP test certificate |
| QCDT | None (`dt_size` = 0) |

## The commit that broke booting, and whether main is affected

- FelixKa, forum [#503](https://community.home-assistant.io/t/lenovo-thinksmart-view-rom-os-development/676324/503)
  (2025-01-26): "There was a commit 3 weeks ago that broke lk2nd booting on the ThinkSmart View …
  ever since then you need to build it with … `SIGN_BOOTIMG=1 LK2ND_QCDTBS=""`."
- That commit is **`72e9abacf8812298851ac4c9137fceb0af56bfa4`** ("dts: msm8953: motorola-potter:
  change to QCDTB", committed 2025-01-03). It added the first `QCDTBS` for msm8953. Since then,
  `lk2nd-msm8953` images by default carry a QCDT, and the header field `dt_size` is non-zero.
  The CD-18781Y `aboot` refuses those images. The DTS note was updated in
  [PR #477](https://github.com/msm8916-mainline/lk2nd/pull/477), commit `e10dc424`.
- **Current main is still affected when built with the default flags.** msm8953 `QCDTBS` now
  lists potter, mtp and samsung-r04. **Our build is not affected**, because `LK2ND_QCDTBS=""`
  leaves `QCDTBS` empty and `dt_size` = 0. `build.sh` checks this.
- **Changes after the prebuilt's commit that touch this device's boot path:**
  - `2c81fe6c` (2025-02): a 1-byte fake ramdisk.
  - `4bec0d72` and `d6381ce3` (2026-06): extlinux boot-memory sizing.
  - `b55f4d49` (2026-07): the default `PANIC_REBOOT_MODE` becomes fastboot.
  - The extlinux fixes from 2025-03 and 2025-04.
- **Evidence that main has booted on this device since then.** Forum
  [#614](https://community.home-assistant.io/t/lenovo-thinksmart-view-rom-os-development/676324/614)
  (2026-02-13) reports a self-built lk2nd that "has worked fabulously". That build would include
  the fake ramdisk, but not the 2026-06/07 changes. I found no report that the 2026-06/07 changes
  are bad for this device. I also found no lk2nd GitHub issue about the CD-18781Y.

## Comparison with the known-working prebuilt

The prebuilt is `../ubuntu-thinksmart/prebuilt/lk2nd.img`. It was used only for comparison, not
as a build input.

| | prebuilt | `out/lk2nd.img` |
| --- | --- | --- |
| lk2nd version | `20.0-next-b9c007bb5492-20250123` | `23.1-next-fd380ac6-20261020` (281 commits later) |
| Size | 335 159 | 359 735 |
| SHA-256 | `c81b036c…6f5209b` | `1f03a9f3…e39c6965` |
| Header | v0, page 2048, base 0x80000000 | same |
| kernel addr / size | 0x80008000 / 331 156 | 0x80008000 / 352 564 |
| ramdisk addr / size | 0x81000000 / **0** | 0x81000000 / **1** (fake ramdisk, commit `2c81fe6c`) |
| second / tags | 0 @ 0x80f00000 / 0x80000100 | same |
| `dt_size` (QCDT) | 0 | 0 |
| cmdline | `lk2nd` | `lk2nd` |
| Appended DTBs | 22 | 28 |
| CD-18781Y DTB | present, with the FT8201 and HX83100A panels | present, identical panel and touchscreen mapping |
| AVB1 signature | yes, target `/boot`, length 0x51800, AOSP test certificate, `Verified OK` | yes, target `/boot`, length 0x57800, the same certificate, `Verified OK` |
| Trailer | `SEANDROIDENFORCE` | `SEANDROIDENFORCE` |

The packaging is the same in every respect except one: our image has a 1-byte ramdisk where the
prebuilt has none.

## Fit in `boot`

| | |
| --- | --- |
| `boot` partition | 65 536 sectors = 33 554 432 bytes. The stock `boot.img` dump is exactly that size |
| Image | 359 735 bytes = 703 sectors (1.07 %) |

The rest of the partition still holds the old stock kernel after the write. That does no harm:

- `aboot` only reads the payload and the signature that follows it.
- lk2nd will try to mount `boot` as ext2 (the label starts with `boot`). The mount fails, and lk2nd
  moves on to the next partition.

## Flashing — NOT YET RUN

Run this from `/home/jethac/Projects/lenovo-8`, with the device in EDL (9008) mode:

```sh
edl w boot lk2nd/out/lk2nd.img
```

If edl cannot pick the loader by itself, add `--memory=emmc
--loader=prog_emmc_firehose_8953_ddr.mbn` (forum
[#70](https://community.home-assistant.io/t/lenovo-thinksmart-view-rom-os-development/676324/70)).

To recover, write back the stock boot partition from the backup:

```sh
zstd -d boot.img.zst
edl w boot boot.img
```

The `-d` step decompresses `boot.img.zst`. `edl` writes `boot.img` back to `boot`. `aboot` and
`abootbak` are never written.

## Files

| Path | What it is |
| --- | --- |
| `build.sh` | Reproducible build, with checks |
| `tools/inspect-bootimg.py` | Header and trailer parser |
| `out/lk2nd.img`, `out/lk2nd.img.sha256` | The deliverable |
| `work/lk2nd-<commit>/` | The clean checkout, and the build tree (`build-lk2nd-msm8953/`) |
| `downloads/venv/` | Signing deps |
| `downloads/web/` | Cached JSON of the forum thread (`thread.json`, `posts.json`), fetched through the public Discourse API |
| `build.log` | Log of the last `build.sh` run |
