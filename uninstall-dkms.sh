#!/bin/bash
# Revert everything install-dkms-signed.sh did.
# Run this if the speakers still do not work, or if anything else regresses.
set -uo pipefail

PKG=aw88399-hda-dkms
VER=1.0
KVER="$(uname -r)"

if [ "$EUID" -ne 0 ]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

echo "=== Removing DKMS modules ==="
dkms remove -m "$PKG" -v "$VER" --all || true
rm -rf "/usr/src/${PKG}-${VER}"

echo "=== Removing config ==="
for f in /etc/modprobe.d/aw88399-hda.conf \
         /usr/share/wireplumber/wireplumber.conf.d/50-aw88399-sof-fix.conf \
         /etc/default/grub.d/99-aw88399-hda.cfg; do
    if [ -e "$f" ]; then
        rm -f "$f"
        echo "  removed $f"
    fi
done

echo "=== Removing any stray hand-copied modules ==="
for m in snd-hda-codec-alc269 snd-soc-aw88399 snd-hda-scodec-aw88399 \
         snd-hda-scodec-aw88399-i2c serial-multi-instantiate aw88399-setup; do
    rm -f "/lib/modules/$KVER/updates/dkms/$m.ko" \
          "/lib/modules/$KVER/updates/dkms/$m.ko.zst"
done

# The firmware blob is left in place on purpose. It is inert without the driver, it is
# what stock kernel 7.3+ will want anyway, and removing it would break a later in-tree
# driver that someone installs after rolling this back. Delete it by hand if you really
# want a pristine system:
#   sudo rm -f /lib/firmware/aw88399_acf.bin
echo "=== Leaving /lib/firmware/aw88399_acf.bin in place (inert without the driver) ==="

depmod -a "$KVER"
update-grub
update-initramfs -u -k "$KVER"

echo
echo "=== Reverted. Reboot to return to the stock audio stack. ==="
