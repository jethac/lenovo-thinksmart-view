# Serial console

## What this is

The debug serial console. Stock kernel command line has `console=ttyHSL0,115200,n8` and `earlycon=msm_hsl_uart,0x78af000`. Mainline enables `&uart_0` with `uart_console_active` pins. A working console makes kernel bring-up much easier, because it shows boot failures that never reach the network.

## Done when

The physical location of TX, RX and GND is known, the logic voltage is measured or documented, and a boot log from lk2nd and the kernel has been captured over serial.

## Known so far

- **The console is probably on the USB-C connector's SBU pins.** `uart_console_active` is GPIO 4 and 5 (`blsp_uart2`, `msm8953.dtsi`). FelixKa's removed USB-OTG hack says GPIO 5 is connector pin B8 (SBU2) and "conflicts with use of pins as UART". So TX/RX are likely SBU1 (A8) and SBU2 (B8). Confirm which is TX, with a USB-C breakout and a 1.8 V-capable adapter, without opening the case.

- UART base `0x78af000` (BLSP1 UART2, `uart_0` in mainline).
- The user has a Silicon Labs CP2102N USB to UART adapter.

## Stock capture

- Which GPIOs `uart_console_active` uses (mainline `tlmm` pinctrl in `arch/arm64/boot/dts/qcom/apq8053-lenovo-cd-18781y.dts` and `msm8953.dtsi`), cross-checked with stock `/sys/kernel/debug/pinctrl/*/pinmux-pins`.

## Questions

- Are TX/RX on test pads, a connector, or only on SoC balls? Search teardown photos, FCC internal photos (FCC ID on the label), the HA forum thread, and postmarketOS notes.
- Is the console also routed through the USB-C port (some Qualcomm boards expose UART on SBU pins or through a debug accessory)?
- Does lk2nd print to this UART?

## Hazards

- **Logic level is almost certainly 1.8 V.** Many CP2102 boards drive 3.3 V on TX. Do not connect without confirming the adapter's I/O voltage, or use a level shifter. 3.3 V into a 1.8 V SoC pin can damage it.
- Opening the case is the user's decision. Do not plan a teardown step without flagging it.

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
