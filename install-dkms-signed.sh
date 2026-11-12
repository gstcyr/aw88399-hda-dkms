#!/bin/bash
# Install the AW88399 HDA sound fix via DKMS.
#
# Unlike the upstream install.sh, this registers the modules with DKMS instead of
# copying raw .ko files into /lib/modules. Hand-copied modules are unsigned, and with
# Secure Boot on the kernel refuses them at load -- you reboot to still-broken speakers
# with no diagnostic. Going through DKMS means Ubuntu signs them with the enrolled MOK.
#
# dkms.conf sets AUTOINSTALL="no" on purpose. Automatic rebuilds would silently produce
# modules for a kernel whose struct layouts nobody has verified; see
# preflight-abi-check.sh. After a kernel update, boot it, run the preflight, then re-run
# this script.
#
# The original in-tree modules are left untouched; these install into /updates/dkms,
# which depmod prefers. Removing the DKMS package reverts everything.
# See uninstall-dkms.sh.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG=aw88399-hda-dkms
VER=1.0
DEST="/usr/src/${PKG}-${VER}"
KVER="$(uname -r)"

if [ "$EUID" -ne 0 ]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

MODULES=(
    snd-hda-codec-alc269
    snd-soc-aw88399
    snd-hda-scodec-aw88399
    snd-hda-scodec-aw88399-i2c
    serial-multi-instantiate
    aw88399-setup
)

# Pre-7.4 firmware path. The driver asks for a bare filename (AW88399_ACF_FILE in
# soc-codecs/aw88399.h), so it lands directly in /lib/firmware. Kernel 7.4-rc1 moved
# upstream to /lib/firmware/awinic/aw88399_acf_<SSID>.bin, but this tree predates that
# and hardcodes the old name -- do not "modernise" this without changing the #define.
FW_SRC="$SRC_DIR/firmware/aw88399_acf.bin"
FW_DEST="/lib/firmware/aw88399_acf.bin"

echo "=== [1/9] ABI preflight ==="
# Hard gate. The vendored headers must match the running kernel's struct layouts or the
# modules build cleanly and then corrupt memory at boot. See preflight-abi-check.sh for
# the full explanation. Nothing below this point runs if the check fails.
if [ ! -x "$SRC_DIR/preflight-abi-check.sh" ]; then
    echo "!! preflight-abi-check.sh missing or not executable. Refusing to install" >&2
    echo "!! blind -- that check is the only thing standing between a clean build" >&2
    echo "!! and a kernel oops that kills the analog audio card." >&2
    exit 1
fi
if ! "$SRC_DIR/preflight-abi-check.sh"; then
    echo >&2
    echo "!! Preflight FAILED. Nothing has been modified. Do not install until the" >&2
    echo "!! reported struct layouts match this kernel." >&2
    exit 1
fi
echo

echo "=== [2/9] Staging source into $DEST ==="
rm -rf "$DEST"
mkdir -p "$DEST"
tar -C "$SRC_DIR" \
    --exclude=.git --exclude='*.ko' --exclude='*.o' --exclude='.*.cmd' \
    --exclude='*.mod' --exclude='*.mod.c' --exclude=Module.symvers \
    --exclude=modules.order --exclude='.tmp_versions' \
    -cf - . | tar -C "$DEST" -xf -
echo "  staged $(find "$DEST" -name '*.c' | wc -l) C sources"

echo "=== [3/9] Registering with DKMS ==="
dkms remove -m "$PKG" -v "$VER" --all >/dev/null 2>&1 || true
dkms add -m "$PKG" -v "$VER"

echo "=== [4/9] Building against $KVER ==="
dkms build -m "$PKG" -v "$VER" -k "$KVER"

echo "=== [5/9] Installing (DKMS signs with the enrolled MOK) ==="
dkms install -m "$PKG" -v "$VER" -k "$KVER" --force

echo "=== [6/9] Verifying Secure Boot signatures ==="
unsigned=0
for m in "${MODULES[@]}"; do
    ko="/lib/modules/$KVER/updates/dkms/$m.ko"
    [ -f "$ko.zst" ] && ko="$ko.zst"
    if [ ! -f "$ko" ]; then
        printf "  %-32s MISSING\n" "$m"
        unsigned=1
        continue
    fi
    signer="$(modinfo -F signer "$ko" 2>/dev/null || true)"
    printf "  %-32s %s\n" "$m" "${signer:-UNSIGNED}"
    [ -z "$signer" ] && unsigned=1
done

if [ "$unsigned" -ne 0 ]; then
    echo
    echo "!! At least one module is unsigned or missing. With Secure Boot on it" >&2
    echo "!! will be refused at load. Stopping BEFORE touching boot config so" >&2
    echo "!! nothing about this boot changes. Nothing else has been modified." >&2
    exit 1
fi

echo "=== [7/9] Module load ordering ==="
cat > /etc/modprobe.d/aw88399-hda.conf <<'EOF'
# AW88399 HDA sound fix for Lenovo Legion.
# The setup helper must load before the HDA I2C driver, which must in turn
# load before the patched Realtek codec.
softdep snd-hda-scodec-aw88399-i2c pre: aw88399-setup
softdep snd-hda-codec-alc269 pre: snd-hda-scodec-aw88399-i2c
EOF
echo "  wrote /etc/modprobe.d/aw88399-hda.conf"

WP_DIR=/usr/share/wireplumber/wireplumber.conf.d
if [ -d "$(dirname "$WP_DIR")" ]; then
    mkdir -p "$WP_DIR"
    cat > "$WP_DIR/50-aw88399-sof-fix.conf" <<'EOF'
# Avoid XRUN / broken pipe on the SOF HDA DSP speaker output with AW88399 amps.
monitor.alsa.rules = [
  {
    matches = [ { node.name = "~alsa_output.pci-*-platform-skl_hda_dsp_generic.*" } ]
    actions = { update-props = { api.alsa.period-size = 2048, api.alsa.headroom = 8192 } }
  }
]
EOF
    echo "  wrote $WP_DIR/50-aw88399-sof-fix.conf"
fi

echo "=== [8/9] Firmware ==="
# The amps need their ACF calibration/config blob or they register fine and stay
# silent, with nothing obviously wrong in dmesg. The upstream install.sh never
# installs it, which makes this an easy step to lose on a fresh machine.
if [ ! -f "$FW_SRC" ]; then
    echo "!! $FW_SRC is missing. The modules will load but the speakers will" >&2
    echo "!! stay silent. Restore the firmware/ directory from the archive." >&2
    exit 1
fi
if [ -f "$FW_DEST" ] && cmp -s "$FW_SRC" "$FW_DEST"; then
    echo "  $FW_DEST already present and identical"
else
    [ -f "$FW_DEST" ] && cp -a "$FW_DEST" "$FW_DEST.bak-$(date +%Y%m%d%H%M%S)" \
        && echo "  backed up existing firmware"
    install -D -m 0644 "$FW_SRC" "$FW_DEST"
    echo "  installed $FW_DEST ($(stat -c%s "$FW_DEST") bytes, md5 $(md5sum "$FW_DEST" | cut -c1-12))"
fi

echo "=== [9/9] Initramfs ==="
# Deliberately NOT setting snd_intel_dspcfg.dsp_driver=3.
#
# The upstream README calls that parameter "Required", claiming the amps need an
# I2S clock from the Intel DSP to lock their PLL. That is not true of the code
# this repo actually ships: there is no PLL check anywhere in side-codecs/ or
# aw88399_setup.c. The claim is a leftover from an older patch generation.
#
# Setting it actively breaks this machine. It loads snd_soc_skl_hda_dsp, which
# probes the codec via hdac_hda instead of legacy snd_hda_intel, and the patched
# alc269 fixup then page-faults in try_assign_dacs, taking the whole Intel analog
# card down:
#   BUG: unable to handle page fault for address: 0000000000010000
#   RIP: try_assign_dacs+0x8b/0x6a0 [snd_hda_codec_generic]
#   Call Trace: ... alc269_probe -> hdac_hda_codec_probe -> skl_hda_audio_probe
#
# Staying on the legacy HDA path also keeps the internal mic working, since
# alsa-ucm-conf 1.2.10 has no sof-hda-dsp profile.
if [ -e /etc/default/grub.d/99-aw88399-hda.cfg ]; then
    rm -f /etc/default/grub.d/99-aw88399-hda.cfg
    echo "  removed stale /etc/default/grub.d/99-aw88399-hda.cfg"
    update-grub
fi
update-initramfs -u -k "$KVER"

echo
echo "=== Done. Reboot to pick up the new modules. ==="
echo "After rebooting, check:"
echo "  lsmod | grep aw88399"
echo "  sudo dmesg | grep -i aw88399"
echo "  wpctl status"
