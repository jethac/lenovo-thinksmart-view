# USB-C port — ThinkSmart View CD-18781Y

## 1. Summary

The port is a plain high-speed USB 2.0 device port with **no working Type-C role negotiation**. It enumerated today at 480 Mbps as `18d1:4ee7` (Android debug gadget) through a powered hub, with `usb` reporting 5 V / 500 mA present while the PMI8950 Type-C block reported `type=Unknown`, `current_capability=0` and **zero** interrupts on any of its five `ufp`/`dfp`/`vrd` lines. Role is decided by two straps, not by CC: GPIO 12 (`ssusb_mode_sel`, pulled low) and GPIO 5 / connector B8 (USB ID, pull-up = device). That is why a hub works and a host port that waits for CC would not. Mainline's DTS has none of this: no `dr_mode`, no VBUS supply, no extcon, no gadget definition. Host mode is the open question, because it needs the PMI8950 OTG boost and this unit has no battery.

## 2. Identity

- Controller: DWC3 at `7000000.ssusb` / `7000000.dwc3`, HS/SS PHY at `7e000` (`qusb2phy`), plus the PMI8950 Type-C TR block at SPMI `0xbf00`.
- Live enumeration (host side): `/sys/bus/usb/devices/1-8.3`, `idVendor 18d1`, `idProduct 4ee7`, `speed 480`, `bcdUSB 2.00`, manufacturer/product `Android`.
- Live enumeration (device side, `dmesg`): `android_usb gadget: high-speed config #1: 86000c8.android_usb`, `msm-dwc3 7000000.ssusb: Avail curr from USB = 500`.
- Type-C block: `qcom,pm8953_typec@bf00`, `compatible = "qcom,qpnp-typec"`, interrupts `vrd-change`, `ufp-detect`, `ufp-detach`, `dfp-detect`, `dfp-detach`, `vbus-err`, `vconn-oc` (`../stock/stock-device-tree.dts:10424-10433`).
- Stock GPL has this enabled (`CONFIG_QPNP_TYPEC=y`, `CONFIG_DUAL_ROLE_USB_INTF=y`) and a driver at `drivers/power/qpnp-typec.c`.

## 3. Wiring

| Item | Stock | Mainline 7.3 | Agree? |
| --- | --- | --- | --- |
| HS PHY supplies | `vdd l3`, `vdda-pll l7`, `vdda-phy-dpdm l13` (GPL `hsusb_phy` via pmi8950 dtsi) | same three supplies on `&hsusb_phy` | yes |
| Controller | `ssusb@7000000` + `dwc3@7000000` | `usb3` node, `qcom,msm8953-dwc3` | node present |
| Role select strap | GPIO 12 `ssusb_mode_sel`, `input-enable`, `bias-disable`, live `in 0 2mA pull down` | **absent** | gap |
| USB ID on B8 | GPIO 5, `blsp_uart2`-shared, pull-up ⇒ device mode; grounded ⇒ host | **absent** (only removed in FelixKa's hack) | gap |
| CC1/CC2 (A5/B5) | to PMI8950 TR block | nothing | not modelled |
| SS mux | GPIO 139 `qcom,ssmux-gpio`, claimed by `qpnp-typec-9` live | absent | gap (only matters for USB3, which this unit does not use) |
| VBUS / OTG boost | PMI8950 charger + `vbus_dwc3-supply` | no `vbus-supply`, no OTG regulator | gap |
| CC termination | **none** — CC reads OPEN at boot | n/a | confirmed |
| `dr_mode` | n/a (vendor msm dwc3) | **not set** (defaults to OTG with no detector) | gap |

`ssusb_mode_sel` exists in the stock FDT but carries no `linux,phandle`, so nothing references it — the pad is simply left with its pull-down by the bootloader.

## 4. Stock behaviour

- Role comes from the ID strap, not CC. GPIO 5 sits on B8 with a pull-up: floating (normal cable) = device mode, shorted to GND (modified cable) = host. This is FelixKa's documented "USB-OTG hack", and it is also why the port cannot be both console and OTG.
- **Boot log settles the CC question**: `TYPEC: qpnp_typec_probe: TypeC successfully probed state=0 CC-line-state=2` (`../stock/stock-boot-dmesg-20261030.txt:197`). The driver probes fine; `state=0` is `TYPEC_DISCONNECTED` and `CC-line-state=2` is `OPEN` in `enum cc_line_state { CC_1, CC_2, OPEN }` — with the cable already attached, the CC lines read as open, i.e. **the board presents no Rd on CC**. That is why nothing ever negotiates role and why the `ufp-detect`/`dfp-detect` IRQ counts stay at 0.
- `msm-dwc3 7000000.ssusb: unable to get dbm device` at 0.8 s (`:49`): the DWC3 BAM/dbm sub-block is missing, unrelated to role but worth noting for mainline (`qcom,usb-dbm` in the stock DT).
- Consequence, now measured rather than inferred: with no CC termination, a host must supply VBUS unconditionally. A powered hub or a USB-A host port does; a Type-C port that waits for Rd on CC does not. The rickx README already specifies a USB-A to USB-C cable, which matches.
- The Android gadget composition is `adb` (`sys.usb.state=adb`), and `android_usb` bounced `USB_STATE` connected/disconnected twice about 30 s into the session — the port is not perfectly stable on stock either.
- `power_supply/usb` shows `real_type=USB`, `usb_otg=0`, `input_current_max=0`: it is being treated as a current source, not a role change.

## 5. Mainline state

`&usb3` is `okay` and `&hsusb_phy` has its three supplies, but:

- no `dr_mode`, so dwc3 sits in OTG with nothing that can detect a role;
- no VBUS/OTG regulator, so even if a role were chosen, host mode has no boost;
- no `extcon`/ID line, so the B8 strap is invisible;
- no gadget function definition (NCM, ACM), so nothing brings up `172.16.42.1`;
- GPIO 12's mode strap is not muxed or set.

## 6. Gap and plan

1. Set `dr_mode = "peripheral"` on `&usb3` for the default case. This is the safe, always-works half of the goal. Test: plug in, `dmesg` shows a gadget bind, `172.16.42.1` answers.
2. Add gadget functions: `usb_f_ncm` for the network interface plus `usb_f_acm` as a console fallback, wired through `configfs` at boot. Test: `usb0` up on the laptop, `ssh jethac@172.16.42.1`.
3. Add the ID input on GPIO 5 (`extcon-usb-gpio` in mainline 7.x is `extcon-gpio` or `usb-role-switch`), so a grounded B8 flips to host without a DT change. Test: modified cable → host mode, a keyboard enumerates.
4. Model the OTG boost: PMI8950 `vbus_dwc3`/OTG regulator on `&usb3`. **Unproven with no battery** — the charger is `qcom,charging-disabled` in stock and mainline disables it. Test: host mode with a USB stick, measure VBUS on a breakout.
5. Only if CC behaviour turns out to matter, consider the PMI8950 TR block. Cheapest correct answer may be to leave CC unmodelled and document "VBUS-providing host only".
6. Chase the `USB_STATE` flapping seen on stock once a gadget is up; if it persists on mainline it is a `dwc3` suspend/`Avail curr` bug, not the harness.

## 7. Risks

- **OTG with no battery**: the PMI8950 needs to boost VBUS from the barrel-jack rail. If it browns out, host mode can reset the SoC rather than just fail.
- **Pin 5 double duty**: enabling the console takes GPIO 5, which kills ID detection; the two cannot be active together.
- **Locked bootloader**: anything that leaves the unit wedged needs EDL, so the USB path must be validated read-only before it is trusted for the install.
- A `dr_mode = "otg"` without detection is the classic way to get a port that works for neither role.

## 8. Open questions

- Does the PMI8950 CC comparator work at all on this board? It reports OPEN, so the CC pins are either unconnected or unterminated; a 5.1 kΩ `Rd` to GND on CC1 would prove which.
- Is GPIO 12 a real strap (read at reset) or a runtime input? If a strap, host mode needs it driven before boot.
- Can the PMI8950 source VBUS with no battery present?
- Does the hub-only behaviour hold for every host, or was today's success specific to that hub?

## 9. Sources

- Live 2026-10-30: `/sys/bus/usb/devices/1-8.3/*`, `dmesg` (gadget, `dwc3`, `Avail curr`), `power_supply/{usb,typec}/*`, `/proc/interrupts`, `debugfs/gpio`, `debugfs/pinctrl`; `evidence/stock-typec-state-20261030.txt`.
- `../stock/stock-device-tree.dts:5049-5067,10424-10433,12002-12040,11605-11615`.
- GPL `drivers/power/qpnp-typec.c`, `drivers/power/qpnp-smbcharger.c:8427-8450`, `arch/arm64/configs/apq8053_IoE-perf_defconfig:320,444`.
- `../stock/stock-boot-dmesg-20261030.txt:49` (dbm), `:197` (typec CC OPEN); `../stock/README-measurement-toolkit-20261030.md`.
- Mainline `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts:237-244,709-721`; `msm8953.dtsi:2254-2320`.
- `../../ubuntu-thinksmart/README.md`, `sources/patches/apq8053-lenovo-cd-18781y-felix-mainline-to-current.patch:40-60,316-336`; `usb/BRIEF.md`.
