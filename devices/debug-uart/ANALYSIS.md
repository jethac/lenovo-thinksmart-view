# Serial console — ThinkSmart View CD-18781Y

## 1. Summary

The debug console is BLSP1 UART2 (`uart_0`, base `0x78af000`, IRQ 107), on TLMM GPIO 4 (RX) and GPIO 5 (TX), muxed `blsp_uart2`. It is **broken out on the USB-C connector**: RX on A5/B5 (CC1/CC2) and TX on A8/B8 (SBU1/SBU2). Three independent sources agree on that mapping, so no teardown is needed. The catch is that stock does not actually run a console: the kernel command line asks for `ttyHSL0` and `earlycon`, the DT node is `ok`, but nothing binds a driver — there is no `ttyHSL0`, `/proc/consoles` is empty and the pins are unclaimed. So a stock boot log over serial needs a kernel change, while lk2nd and a mainline kernel will use it as-is. Logic level is 1.8 V and must not be fed 3.3 V.

## 2. Identity

- UART: `serial@78af000`, `compatible = "qcom,msm-lsuart-v14"`, BLSP1 UART2, `uart_0` in mainline. Stock DT carries the node with `status = "ok"` and the same `uart_console_active` pinctrl.
- Pins: `gpio4`, `gpio5`, `function = "blsp_uart2"`, `bias-disable`, `drive-strength = <2>` — identical in stock DT (`pmx-uartconsole/uart_console_active`) and mainline (`msm8953.dtsi` `uart_console_active`).
- Wire positions, stated in the mainline DTS itself: *"RX (GPIO4) is pins A5/B5, TX (GPIO5) is pins A8/B8"*. The same sentence appears in FelixKa's removed OTG hack (`../../ubuntu-thinksmart/sources/patches/apq8053-lenovo-cd-18781y-felix-mainline-to-current.patch:325`), which also notes the conflict: GPIO 5 is the USB-OTG ID line when the console is not in use.
- Connector positions: A5/B5 are CC1/CC2; A8/B8 are SBU1/SBU2; ground is A1/A12/B1/B12.

## 3. Wiring

| Item | Stock | Mainline 7.3 | Agree? |
| --- | --- | --- | --- |
| Peripheral | BLSP1 UART2 @ `0x78af000` | `&uart_0`, same node | yes |
| RX | GPIO 4, `blsp_uart2` | GPIO 4, `blsp_uart2` | yes |
| TX | GPIO 5, `blsp_uart2` | GPIO 5, `blsp_uart2` | yes |
| Connector | A5/B5 (RX), A8/B8 (TX) | same, documented in DTS comment | yes |
| Drive strength | DT says 2 mA; live pads report 8 mA (see §4) | 2 mA | mismatch, unexplained |
| Node state | `ok` | enabled | yes |
| Driver actually bound | **no** | n/a until booted | see §4 |

## 4. Stock behaviour

- `/proc/cmdline` (live, and the captured FDT `chosen/bootargs`) contains `console=ttyHSL0,115200,n8`, `androidboot.console=ttyHSL0` and `earlycon=msm_hsl_uart,0x78af000`.
- The DT node exists and is enabled, and the platform device is present: `/sys/bus/platform/devices/78af000.serial`.
- Despite that, on the running LineageOS kernel there is no console: `/proc/consoles` is 0 bytes, no `/dev/ttyHSL0`, no `ttyHSL0` in `/sys/class/tty`, and pins 4/5 are `(MUX UNCLAIMED)` in `debugfs/pinctrl/*/pinmux-pins`. `debugfs/gpio` reports both pads as `out 2 8mA no pull` — leftover ball state, not an active UART.
- Conclusion: the LineageOS kernel in use almost certainly lacks the HSL serial driver, so the console hardware is idle and free for us. Interrupt 107 in stock belongs to `qpnp-int` `usbid-change`, not the UART, confirming the peripheral never registered its IRQ.
- Because the ring buffer has rolled (uptime ~2 h at capture), the original probe/registration failure is not in `dmesg`.

## 5. Mainline state

- `&uart_0` is enabled with `uart_console_active`, exactly as needed.
- The DTS documents the connector mapping and that `/usb3` is enabled alongside it.
- Nothing else is required in DT. The 1.8 V adaptation is external and belongs in the adapter, not the tree.
- lk2nd is expected to print on this UART, since the same pins and base are used by the bootloader path.

## 6. Gap and plan

1. **Adapter first.** Configure the CP2102N for **1.8 V VIO** before anything is connected, then verify the TX output is ~1.8 V with a meter. A CP2102N at 3.3 V into these pads is the single most likely way to damage the unit.
2. Build a breakout that only uses A1/B1/A12/B12 (GND), A5/B5 (device RX) and A8/B8 (device TX). Keep it a bare breakout — a hub or charger on the same port will fight over CC1/CC2.
3. Cross the lines: adapter TX → A5/B5, adapter RX → A8/B8, GND common. Leave VBUS out; the unit runs from the barrel jack.
4. Attach while the unit is idle and watch for anything at 115200 8N1. Stock may print nothing (see §4); that is expected, not a wiring fault. Confirm the harness by booting lk2nd/mainline and reading the boot log.
5. Capture lk2nd and kernel output to `evidence/` (an existing image on a spare boot partition is enough; the boot chain is untouched otherwise).
6. Once the log is in hand, re-check the 8 mA vs 2 mA pad-strength difference; if mainline also reports 8 mA, the DT value is not the one being applied.

## 7. Risks

- **1.8 V logic.** 3.3 V on GPIO 4 can damage the SoC pad. Verify the adapter's I/O rail with a meter first.
- **Pin 5 double duty.** GPIO 5 is the USB-OTG ID line when the console is not selected. Enabling the console silently changes OTG role detection — the OTG hack and the console cannot both be active.
- **CC1/CC2 carrying data.** Plugging a normal USB-C device (hub, charger, host) into the same port while the console is attached will disturb both. One or the other.
- Open-drain/idle state: with `bias-disable` on both pins, an unconnected RX floats. Do not rely on the console for anything while the harness is half-plugged.

## 8. Open questions

- Which of A5 and A8 is actually RX vs TX on this unit? The DTS says A5/B5 = RX, but the CC/SBU split is unusual enough to re-measure with a scope or by watching idle levels on both pads before trusting it.
- Why do the pads report 8 mA when the DT says 2 mA, and does it matter for signal integrity at 115200?
- Does lk2nd actually emit on this UART, or does it need an explicit console argument?
- Is there a second, easier tap (test pads under the rear cover) that avoids the CC/SBU conflict?

## 9. Sources

- Live device 2026-10-30: `/proc/cmdline`, `/proc/consoles`, `/sys/class/tty`, `/sys/bus/platform/devices/78af000.serial`, `debugfs/gpio`, `debugfs/pinctrl`.
- `../stock/stock-device-tree.dts:34` (bootargs), `:4029-4045` (uart_console_active); `../stock/stock-pinmux-20261030.txt`.
- Mainline `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts:709-717`; `arch/arm64/boot/dts/qcom/msm8953.dtsi:985-1000,2485-2490`.
- `../../ubuntu-thinksmart/sources/patches/apq8053-lenovo-cd-18781y-felix-mainline-to-current.patch:316-336`.
