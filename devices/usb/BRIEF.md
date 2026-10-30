# USB-C port

## What this is

The USB-C port behind the plug on the right side (portrait, camera top left). Mainline enables `&usb3` (DWC3 at `7000000`) and `&hsusb_phy`. Power comes from the barrel jack, not USB.

## Done when

Plugging the port into the laptop always brings up a USB network interface with SSH at `172.16.42.1`, from first boot, regardless of Wi-Fi. Host mode (OTG) works for a USB stick or keyboard, or the reason it cannot is documented.

## Known so far

- **Evidence from rickx's unit (stock):** `../../ubuntu-thinksmart/research/root/dmesg-2026-05-29.txt` lines 1395-1398 show a host connection working in device mode: `DWC3 exited from low power mode`, `USB_STATE=CONNECTED`, `high-speed config #1`, `Avail curr from USB = 500`. That unit appears in `adb devices` (`research/root/adb-devices-2026-05-29.txt`). rickx's README specifies a USB-A to USB-C cable.
- **No CC role detection.** FelixKa's earlier DTS (removed in `../../ubuntu-thinksmart/sources/patches/apq8053-lenovo-cd-18781y-felix-mainline-to-current.patch`) had a `linux,extcon-usb-gpio` "USB-OTG hack": pull connector pin B8 to GND for USB ID, `id-gpios = <&tlmm 5 ...>`, ACTIVE_HIGH = device mode, "Conflicts with use of pins as UART". So role comes from an ID line on GPIO 5, defaulting to device mode; host mode needs a modified cable.
- Working inference, not yet verified: the port does not present Rd on CC, so a USB-C host (laptop Type-C port) never enables VBUS. Use a USB-A host port. Check CC wiring (multimeter on a breakout, or stock DT/GPL source) to confirm.

- On stock, with a cable reportedly plugged in, the laptop saw no USB device and no Type-C partner, and the device reported `/sys/class/android_usb/android0/state` = `DISCONNECTED` and `/sys/class/power_supply/usb/online` = 0. Unresolved: cable, wrong port, or port mode.
- Stock exposes a `typec` power supply, which suggests a Type-C controller or PMIC Type-C logic.
- The rickx DTS patch removed a `linux,extcon-usb-gpio` node (VBUS/ID detection by GPIO). Find out why, and what that GPIO is.
- One forum user said the port "doesn't run in the right mode by default".

## Stock capture

- `/sys/class/power_supply/typec/*` and `/sys/class/dual_role_usb/*`, `getprop sys.usb.*`, the USB nodes in `/proc/device-tree` (`qcom,dwc3`, `qcom,qusb2phy`, extcon, Type-C controller), and the claimed GPIOs for VBUS, ID and Type-C.
- With the cable in the side port and the laptop running `udevadm monitor`, toggle `sys.usb.config` between `mtp,adb` and `none` and record what the laptop sees.

## Questions

- Is there a Type-C controller chip (I2C), and is CC handled at all? Without CC detection, does the port default to peripheral?
- What decides host versus peripheral role on stock? Can it supply VBUS in host mode (PMI8950 OTG boost), given no battery?
- Which gadget functions should mainline expose: NCM or RNDIS for networking, plus ACM serial as a fallback console?

## Output

Write `ANALYSIS.md` and `evidence/` in this directory, following `../README.md`. Follow the rules there (read only, one user of the device at a time, no reboot, no flashing).
