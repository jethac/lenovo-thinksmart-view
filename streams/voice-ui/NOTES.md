# voice-ui: Straylight voice assistant screen

The app is its own repository, `/home/jethac/Projects/straylight-voice`
(local, not published): a Slint app on DRM/KMS (linuxkms backend, software
renderer, libinput) with the six designed states, driven over
`/run/straylight-voice.sock`. Its README has the protocol, build, the
measurements and the exact image changes ("What the image build must add").

## Status (2026-10-31)

- Installed and enabled on the tablet; it boots into Idle in place of the
  idle screen (unit started 9.5 s, first frame 10.2 s, splash quit 10.7 s
  after kernel start). sshd, adbd, the USB gadget, DHCP and both gettys
  unaffected, checked after `systemctl reboot` (boot_id
  `5df68c6b-5d8a-4c67-a382-65f2b214f854`).
- CPU with the software renderer, steady: Idle 4.7 %, Listening 10.2 %,
  Captions 10.8 %, Thinking 4.7 %, Speaking 19.7 %, Offline 0 % of one core;
  60 frames/s except Speaking (53). This needs two patches to the Slint fork's
  linuxkms software path (kept in the app repo, `patches/slint/`); without
  them every frame was a full repaint and Idle alone took a whole core.

## Left on the device

Installed with `pacman -U` (packages from the Arch Linux ARM mirror, verified
on the laptop and with `LocalFileSigLevel = Required` on the tablet):

- `libinput 1.32.0-1`, `mtdev 1.1.7-1`, `libwacom 2.20.0-1`,
  `libgudev 238-4`, `lua54 5.4.9-1` (before stage B; +7.9 MiB used)
- `noto-fonts 1:2026.10.01-1`, `noto-fonts-cjk 20240730-1` (after stage B;
  +411 MiB with `strace`, fontconfig caches)
- `strace 7.2-1`, `libunwind 1.8.3-1`: measuring only, can be removed

Files (by `packaging/install.sh` in the app repo; `packaging/uninstall.sh`
reverses them and starts the idle screen):

- `/usr/local/bin/straylight-voice`, `/usr/local/bin/straylight-voicectl`
- `/etc/systemd/system/straylight-voice.service`, enabled (symlinks
  `graphical.target.wants/straylight-voice.service` and
  `display-manager.service`)
- `/etc/straylight-voice.conf` (`STRAYLIGHT_ARGS=`, socket only, no demo)
- `/etc/udev/rules.d/91-straylight-voice.rules`: clears the idle screen's
  `SYSTEMD_WANTS` on fb0, so `tsv-idle-screen` is not started

## Needs from the image (for the integrator)

See the app README, "What the image build must add": the packages above
(without strace), the four files, `systemctl enable straylight-voice` in the
chroot. Note for `tsv-idle-screen`: its udev-queued start job is ordered
`Before=display-manager.service` and `After=plymouth-quit-wait.service`, so
with only the alias a display manager waits for the 60 s splash timeout; the
91 rule avoids that, or the idle screen's rule could skip queueing when
`display-manager.service` exists. Its README also says
`systemctl mask tsv-idle-screen` works, but the unit is in
`/etc/systemd/system`, where `mask` cannot place its symlink (not tried here).
