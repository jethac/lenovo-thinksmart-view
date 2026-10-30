#!/bin/bash
# Omarchy on the ThinkSmart View, after stage B has grown root.
# Run on the tablet as jethac (sudo prompts), from a copy of streams/stage-b/omarchy/
# next to a checkout of omarchy-arm (579f15c6 or later) at ./omarchy-arm.
#
#   ./install-omarchy.sh preflight     read-only checks
#   ./install-omarchy.sh dry-run       preflight + omarchy-arm ./install.sh --dry-run (changes nothing)
#   ./install-omarchy.sh install       packages, omarchy-arm, then the board fixes below
#   ./install-omarchy.sh fixup         only the board fixes (safe to rerun)
#
# What it keeps from the base image: the ai& Plymouth theme and plymouthd.conf,
# /etc/mkinitcpio.conf.d/zz-tsv-hooks.conf (last in its directory), the USB
# gadget/adb/DHCP/sshd services, and the boot idle screen handing over to SDDM.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OA=${OA:-$HERE/omarchy-arm}
say() { printf '\n== %s\n' "$*"; }
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }

preflight() {
    say "preflight"
    [ "$(uname -m)" = aarch64 ] || die "not aarch64"
    [ "$(id -un)" = jethac ] || die "run as jethac"
    local size_k avail_k
    size_k=$(df -k --output=size / | tail -1); avail_k=$(df -k --output=avail / | tail -1)
    echo "root: $((size_k / 1024)) MiB, $((avail_k / 1024)) MiB free"
    [ "$size_k" -gt $((6000 * 1024)) ] || die "root is not grown (stage B first)"
    [ "$avail_k" -gt $((3000 * 1024)) ] || die "less than 3 GiB free"
    # pacman rejects signatures made in its future; the tablet has no RTC battery backup
    [ "$(date +%Y%m%d)" -ge 20261030 ] || die "clock is $(date); sync time first (timedatectl)"
    ping -c1 -W5 archlinux.org >/dev/null || die "no internet"
    [ -f /etc/mkinitcpio.conf.d/zz-tsv-hooks.conf ] || die "zz-tsv-hooks.conf missing"
    [ "$(plymouth-set-default-theme)" = aiand ] || echo "note: plymouth theme is $(plymouth-set-default-theme)"
    [ -x "$OA/install.sh" ] || die "omarchy-arm checkout not at $OA"
    for u in tsv-usb-gadget tsv-usb-dhcp tsv-adbd sshd; do
        systemctl is-enabled --quiet "$u" || die "$u not enabled"
    done
    free -m | sed -n 1,2p
}

patch_fork() {
    if git -C "$OA" apply --check "$HERE/omarchy-arm-thinksmart.patch" 2>/dev/null; then
        git -C "$OA" apply "$HERE/omarchy-arm-thinksmart.patch"
        echo "omarchy-arm: ThinkSmart patch applied"
    elif git -C "$OA" apply -R --check "$HERE/omarchy-arm-thinksmart.patch" 2>/dev/null; then
        echo "omarchy-arm: ThinkSmart patch already applied"
    else
        die "omarchy-arm-thinksmart.patch does not apply to $OA"
    fi
}

add_omarchy_repo() {
    say "[omarchy] aarch64 repository"
    if ! grep -q '^\[omarchy\]' /etc/pacman.conf; then
        # Same settings as Omarchy's own pacman.conf. After the [alarm]/[aur]
        # sections, so Arch Linux ARM's builds win where both have a package
        # (notably hyprland: [omarchy]'s 0.56.2 needs soname provides that
        # Arch Linux ARM packages do not declare).
        printf '\n[omarchy]\nSigLevel = Optional TrustAll\nServer = https://pkgs.omarchy.org/stable/$arch\n' |
            sudo tee -a /etc/pacman.conf >/dev/null
    fi
    sudo pacman -Sy
    sudo pacman -S --needed --noconfirm omarchy-keyring
    sudo pacman-key --populate omarchy || true
}

install_packages() {
    say "packages ($(grep -vc '^#' "$HERE/tablet.packages") targets)"
    mapfile -t pkgs < <(grep -v '^#' "$HERE/tablet.packages")
    sudo pacman -S --needed --noconfirm "${pkgs[@]}"
    sudo paccache -rk0 2>/dev/null || sudo pacman -Scc --noconfirm
    df -h /
}

fixup() {
    say "board fixes"
    # 1. Splash: our plymouthd.conf (the patch keeps it; restore if anything replaced it)
    if ! grep -q '^Theme=aiand' /etc/plymouth/plymouthd.conf || ! grep -q '^DeviceTimeout=8' /etc/plymouth/plymouthd.conf; then
        printf '[Daemon]\nTheme=aiand\nDeviceScale=1\nDeviceTimeout=8\nShowDelay=0\n' |
            sudo tee /etc/plymouth/plymouthd.conf >/dev/null
        echo "plymouthd.conf restored"
    fi
    # 2. initramfs hooks: ours must be the last drop-in
    last=$(ls /etc/mkinitcpio.conf.d/ | sort | tail -1)
    [ "$last" = zz-tsv-hooks.conf ] || die "last mkinitcpio drop-in is $last, not zz-tsv-hooks.conf"
    sudo plymouth-set-default-theme -R aiand
    lsinitcpio /boot/initramfs-tsv.img | grep -qE 'hooks/tsv-subpart' || die "initramfs lacks tsv-subpart"
    lsinitcpio /boot/initramfs-tsv.img | grep -qE 'themes/aiand' || die "initramfs lacks the aiand theme"
    echo "initramfs: tsv-subpart and aiand present"
    # 3. Firewall: everything over the USB cable (DHCP for the laptop, ssh, adb is not IP)
    if command -v ufw >/dev/null; then
        sudo ufw allow in on usb0 comment 'tsv usb gadget' || true
        grep -q 'usb0' /etc/ufw/user.rules || die "ufw rule for usb0 not written"
    fi
    # 4. No Vulkan ICDs (Adreno 506 has no Vulkan driver; lavapipe would take GTK4)
    for p in vulkan-virtio vulkan-swrast; do
        pacman -Q "$p" >/dev/null 2>&1 && sudo pacman -Rns --noconfirm "$p"
    done
    # 5. Display manager: autologin into Omarchy; enabling it retires tsv-idle-screen
    sudo install -Dm644 "$HERE/etc/sddm.conf.d/20-tsv-autologin.conf" /etc/sddm.conf.d/20-tsv-autologin.conf
    sudo systemctl enable sddm.service
    [ -L /etc/systemd/system/display-manager.service ] || die "display-manager.service not linked"
    # 6. Our services must still be enabled
    for u in tsv-usb-gadget tsv-usb-dhcp tsv-adbd sshd NetworkManager; do
        systemctl is-enabled --quiet "$u" || die "$u was disabled"
    done
    # 7. Per-user touch settings (old files kept as *.pre-tsv)
    for f in hypr/monitors.lua hypr/input.lua hypr/looknfeel.lua hypr/autostart.lua; do
        [ -f ~/.config/$f ] && [ ! -f ~/.config/$f.pre-tsv ] && cp ~/.config/$f ~/.config/$f.pre-tsv
        install -Dm644 "$HERE/home/.config/$f" ~/.config/$f
    done
    if [ -f ~/.config/omarchy/shell.json ]; then
        jq -s '.[0] * .[1]' ~/.config/omarchy/shell.json "$HERE/home/.config/omarchy/shell-idle.json" > ~/.config/omarchy/shell.json.new
        mv ~/.config/omarchy/shell.json.new ~/.config/omarchy/shell.json
    fi
    touch ~/.config/chromium-flags.conf
    while read -r flag; do grep -qxF -- "$flag" ~/.config/chromium-flags.conf || echo "$flag" >> ~/.config/chromium-flags.conf; done \
        < "$HERE/home/.config/chromium-flags.append"
    say "done; reboot to start the session"
}

case "${1:-}" in
    preflight) preflight ;;
    dry-run) preflight; (cd "$OA" && ./install.sh --dry-run --skip-packages) ;;
    install)
        preflight
        add_omarchy_repo
        install_packages
        patch_fork
        (cd "$OA" && ./install.sh --skip-packages --yes)
        fixup ;;
    fixup) fixup ;;
    *) sed -n '2,15p' "$0"; exit 2 ;;
esac
