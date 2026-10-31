# settings-auth: settings, ai& sign-in and replies, Wi-Fi, sound, charms

The Straylight screen gets a settings overlay and the assistant gets real
replies from ai&. Code: straylight-voice (`github.com/jethac/straylight-voice`,
commit `34dcb31`). Its README has the design and the protocol; `aiand/README.md`
and `wifi/README.md` cover the two new services; `listen/README.md` covers the
responder and the sound settings. This file has the findings, the tests, the
device state and what is left.

## Status (2026-10-31)

Done and running on the tablet: the settings overlay (account, Wi-Fi, Sound,
Microphone, Model, About; Voice and Wake word reserved), the sign-in screen
with its QR code, the Wi-Fi picker with a password keyboard and WPS, the
speaker and microphone settings, charms for the volume keys and the camera
cover, and the ai& responder in the listener.

Tested on the laptop against the real api.aiand.com up to a pending sign-in
code. Tested on the tablet everything that needs no internet and no user.
Left for the user: approving a sign-in, joining Wi-Fi (password or WPS
button), and pressing the side keys and sliding the camera cover. Then a
real reply on the tablet.

## Processes

| Process | Holds | Network |
| --- | --- | --- |
| `straylight-voice` (root: panel, input) | the screen; reads the side keys and the camera cover (view-hal) | not used |
| `straylight-listen` (root: ALSA) | wake word, ASR, the reply on screen; speaker volume and microphone settings (`/var/lib/straylight-listen/audio.json`) | none, `PrivateNetwork=yes` kept |
| `straylight-aiand` (root, no capabilities) | the ai& key (`/var/lib/straylight-aiand/credentials.json`, 0600, dir 0700) | the only one |
| `straylight-wifi` (user `straylight-wifi`) | nothing secret; NetworkManager through polkit (3 actions), wpa_supplicant for WPS through a D-Bus policy (4 calls) | none, `PrivateNetwork=yes` |

**Why a new service for ai&, not the listener.** The listener is a 1 GiB root
process with ALSA access that runs C++ on whatever the microphones hear. Giving
it a credential and an internet socket would widen that a lot. The new daemon
is 2.4 MB with `MemoryMax=64M`, no devices, no capabilities, `@system-service`
system calls and a read-only system. The listener reaches it over a
filesystem socket, which works across network namespaces, so the listener
keeps `PrivateNetwork=yes`. The screen never sees a token, only the
organisation name and the expiry.

**Why the keys and cover are read by the screen.** It already runs as root
with view-hal, a charm has to appear at once, and libinput reports neither
`SW_CAMERA_LENS_COVER` nor the volume keys in a way the app can use. The
volume change itself goes to the listener as the same `audio` event the
Sound slider sends, so there is one volume, saved in one place and capped at
207 (0 dB). view-hal needed no change: it has no `audio` module, and STATE.md
only reserves the names.

**Wi-Fi boundary.** A dedicated unprivileged user, a polkit rule for
`wifi.scan`, `network-control` and `settings.modify.system`, and a D-Bus
policy allowing only `GetInterface`, `FlushBSS`, `WPS.Start` and
`WPS.Cancel` on wpa_supplicant (not `Properties`, not `NetworkAdded`).
`GetSecrets` is never called. The typed password exists in the screen only
while the keyboard is up. It is sent in one event line to the connection
with role `wifi` only, and the buffers are overwritten. It is never logged.

## Findings

- **client_id.** `POST https://api.aiand.com/auth/device/code` with
  `{"client_id":"straylight-voice","key_name":"straylight@probe"}` answered
  200 with a user code (`verification_uri` `/auth/device`, relative,
  `expires_in` 900, `interval` 5). One poll of that code answered
  `authorization_pending`, not a client error. So `straylight-voice` is used,
  not `aiand-cli`. Worth asking ai& whether client ids are registered at all
  (a server that accepts any would answer the same).
- **Key name** on the tablet: `straylight@thinksmart-HUA0BMNX` (`/etc/hostname`
  and `/proc/device-tree/serial-number`).
- **Model.** `/v1/models` is public. aiand-cli's fast preference
  (`deepseek-ai/deepseek-v4.1-flash`, then `google/gemma-4-31b-it`) is the
  default; it lists `reasoning_effort` `none`, which is sent.
- **Speaker cap.** `Speaker Amp Digital Playback Volume` 0..207, 0.5 dB
  steps, 207 = 0 dB (`streams/speaker/NOTES.md`). There is no mute switch, so
  mute is volume 0. The screen refuses more than 207 at the protocol, the
  listener clamps as well, and the slider runs -60..0 dB.
- **Mic gain.** `TX1/TX2 Digital Volume` 0..124, 84 = 0 dB; the screen offers
  -12..+40 dB, default +24 as before.
- **Seccomp.** `SystemCallFilter=~@privileged` killed straylight-aiand
  (SIGSYS) on the socket `chown`. Both new units now have
  `SystemCallErrorNumber=EPERM`, so a filtered call fails instead.
- **WPS on this stack** (from the Wi-Fi work): wpa_supplicant's D-Bus API is
  root-only, hence the narrow policy file. NetworkManager need not release
  the device. A session turns device autoconnect off and puts it back on
  every exit path; a marker in `/run/straylight-wifi` restores it if the
  process dies.

## Tests

### Laptop, against the real api.aiand.com (`work/e2e/`, `work/laptop/`)

The laptop builds of the screen (`--live`), straylight-aiand and the
listener's `--ask` were all run together.

- `models`: 12 models, `deepseek-ai/deepseek-v4.1-flash` chosen.
- Sign-in reached real pending codes (`QX6B-2BZF` and others). The
  verification URL passed the origin check. The QR code drawn by the screen
  decodes (zbarimg) to `https://api.aiand.com/auth/device?user_code=QX6B-2BZF`.
  The countdown ran, and cancel returned the screen to the account page.
- Signed out, `--ask "What's the weather like tomorrow?"` and
  `--ask "明日の天気は？"` gave the spoken sign-in prompt in English and in
  Japanese at once, without a request.
- A made-up key against the real server got a 401. Rotation was refused, the
  credentials were deleted, and the reply was `signed_out`.
- An unreachable gateway gave `offline` (chat) and an `error` phase (sign-in).
- **Not tested:** a real approval, so there was no real reply, no real
  rotation and no real sign-out revoke. To do it,
  `streams/settings-auth/scripts/laptop-signin.sh` runs the whole flow and
  waits for the approval on a phone.

### Tablet (`work/device-shots/`, `work/device-shots2/`, `work/device-test.log`)

`scripts/device-settings-test.sh` ran under the lock: real taps (straylight-voice
`tools/tap.c`), `straylight-voicectl`, and `--grab`.

- The settings button opens Home. Sound shows the real −31 dB (145). The
  Microphone page shows +24 dB and the live level dots. Wi-Fi lists the real
  networks from NetworkManager, including the WPS markers. Model and About
  open. The keyboard took 8 typed letters (dots, "8 characters · ready to
  join"); the eye button showed them, and Join was not pressed.
- Sign-in with no internet gave "Can’t reach ai&. Can’t reach api.aiand.com
  (name not resolved)".
- Offline shows the settings button and the real Wi-Fi line from the Wi-Fi
  service.
- **The whole pipeline**, with the listener service stopped and the test
  set's "Hey Straylight, what's the weather tomorrow?" played as a file
  (`--input --realtime`):
  - Signed out: Speaking showed "I’m not signed in yet. Tap the settings
    button at the top right of the screen and choose Sign in."
  - With straylight-aiand stopped: Offline.
  - With settings open: "wake at 2.96 s ignored: settings are open".
- **Speaker slider by tap:** 145 → 115 (amixer `115,115`, saved to
  `audio.json`), then back to 145.
- **CPU:** settings open and still, 0 % of a core over 5 s; Idle 5 %.
- **WPS sessions run on the tablet near the user's network** (all times JST):
  - 19:33:04 push-button; a mis-aimed tap left it running its full 2 min, and
    it timed out cleanly with autoconnect restored;
  - 19:39:55–19:39:58 push-button, cancelled by leaving the page. That
    exposed a bug (leaving the WPS page did not cancel), now fixed and
    verified.
  - Earlier, from the Wi-Fi work (UTC): 10:15:12 a cancelled push-button
    session and a cancelled PIN session; 10:15:43 one killed after 15 s;
    10:16:25–10:18:27 a full 2-min timeout.
- Charms: the readers start (`keys: reading gpio-keys, pm8941_resin`,
  `cover: open`). A charm sent over the socket was grabbed, and About shows
  "Camera cover: Open: camera on". No key has been pressed and the cover has
  not moved.

Screenshots: `work/shots/*.png` (headless, every page,
`tools/settings-screens.txt`), `work/e2e/frames/` (laptop `--live` with the
real server), `work/device-shots/*.png` and `work/device-shots2/*.png` (the
panel).

## Left on the device

- straylight-voice, -voicectl, -listen at `34dcb31` (units unchanged).
- New: `/usr/local/bin/straylight-aiand`,
  `/etc/systemd/system/straylight-aiand.service` (enabled, running),
  `/etc/straylight-aiand.conf`, `/var/lib/straylight-aiand/` (empty: not
  signed in).
- New: `/usr/local/bin/straylight-wifi`,
  `/etc/systemd/system/straylight-wifi.service` (enabled, running),
  `/etc/sysusers.d/straylight-wifi.conf` (user `straylight-wifi` 964, groups
  `straylight-wifi` 964 and `straylight` 965),
  `/etc/polkit-1/rules.d/50-straylight-wifi.rules`,
  `/etc/dbus-1/system.d/straylight-wifi-wpas.conf`, `/run/straylight-wifi/`.
- `/run/straylight-voice.sock` is now `root:straylight 0660`.
- `/var/lib/straylight-listen/audio.json` (speaker 145, gain +24 dB,
  nothing muted): the same values as before the tests.
- No NetworkManager connection profiles. wlan0 is disconnected, autoconnect
  on. Test files in `/var/tmp` were removed.

## What the device needs to reach the internet (open item)

Joining Wi-Fi is the whole of it, and it can now be done on the tablet:
Settings › Wi-Fi › the network › Connect, then type the password, or Connect
with WPS and press the router's button. NetworkManager, systemd-resolved
(DNS) and systemd-timesyncd (the clock) are already set up for wlan0.

The clock matters too: TLS checks certificates against it, the RTC is not
kept (it reads 1970), and the Wi-Fi notes say the clock restarts at a fixed
unsynced time after a boot. The first NTP sync after joining fixes it. The
ai& client reports a certificate failure as "is the clock right?".

Over USB only, the laptop would have to route for the tablet: NAT plus IP
forwarding, a default route via 172.16.42.x, and DNS. Or it could run a
proxy for `straylight-aiand --proxy http://…|socks5://…`. An
`ssh -R` SOCKS forward from the laptop would also work without changing the
laptop's network settings. None of these is set up, by instruction.

## For the image (`rootfs/scripts/`, not changed here)

straylight-voice README, "What the image build must add for settings, ai&
and Wi-Fi":

- the two new binaries, units, conf, sysusers file, polkit rule and D-Bus
  policy;
- `systemd-sysusers`, then `systemctl enable straylight-aiand
  straylight-wifi`;
- no new packages;
- the new screen and listener builds.

## Still to do (needs the user)

1. **Sign-in approval, on the laptop.** Run
   `streams/settings-auth/scripts/laptop-signin.sh`, scan the QR code or open
   the URL on a phone, and approve. It then asks two questions (a real
   reply) and signs out (revoking the key); `--keep` keeps the key.
2. **Wi-Fi on the tablet.** The user joins their network from Settings ›
   Wi-Fi, typing the password on the tablet or using WPS. Then on the tablet:
   Settings › ai& account › Sign in, approve on the phone, and say "Hey
   Straylight, …" for a real reply.
3. **Keys and cover.** Watch with
   `adb shell journalctl -fu straylight-voice -u straylight-listen` while the
   user:
   - presses Volume up and Volume down: a pill at the top shows "Volume −28 dB"
     and so on with a red bar; at the bottom of the range "Muted";
     "Volume (max)" at 0 dB; holding repeats; it fades 1.5 s after the last
     press; the listener logs `audio: speaker ...`;
   - slides the camera cover closed and open: "Camera off" / "Camera on" with
     the lens icon; About › Camera cover follows.

   No hold of Volume down for anything near 10 s: it is the PMIC's reset
   gesture on stock.
