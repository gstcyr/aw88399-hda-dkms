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
# Keep in step with PACKAGE_VERSION in dkms.conf. Checked explicitly rather than left
# to `set -e`, which would otherwise abort here with a bare sed error and exit 2.
if [ ! -r "$SRC_DIR/dkms.conf" ]; then
    echo "No readable dkms.conf in $SRC_DIR -- run this from the source tree." >&2
    exit 1
fi
VER="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' "$SRC_DIR/dkms.conf")"
DEST="/usr/src/${PKG}-${VER}"
KVER="$(uname -r)"

# Codec SSIDs the quirk table in realtek/alc269.c actually matches. These are *codec*
# SSIDs, not the HDA controller's PCI subsystem ID -- on a 16IAX10H the controller is
# 17aa:3d6c while the codec is 17aa:3907. See fix 5 in README.md.
SUPPORTED_SSIDS="0x17aa3906 0x17aa3907 0x17aa3938"

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

if [ -z "$VER" ]; then
    echo "Could not read PACKAGE_VERSION from $SRC_DIR/dkms.conf" >&2
    exit 1
fi

echo "=== [1/10] Hardware check ==="
# Installing this on the wrong machine is NOT a harmless no-op. The patched
# snd-hda-codec-alc269 lands in /updates/dkms, which depmod prefers over the in-tree
# module, so it replaces the stock Realtek codec driver on *any* machine with a
# Realtek codec -- swapping working in-tree code for out-of-tree code built against
# vendored headers, for no benefit. Gate on the hardware before we get that far.
#
# Set ALLOW_UNVERIFIED_HW=1 to force past the two fatal checks below.
HW_OVERRIDE="${ALLOW_UNVERIFIED_HW:-0}"

hw_fail() {
    if [ "$HW_OVERRIDE" = 1 ]; then
        echo "  !! $1 -- continuing anyway, ALLOW_UNVERIFIED_HW=1"
        return 0
    fi
    echo >&2
    echo "!! $1" >&2
    shift
    for line in "$@"; do echo "!! $line" >&2; done
    echo "!! Nothing has been modified. Set ALLOW_UNVERIFIED_HW=1 to override." >&2
    exit 1
}

# 1. The amps themselves. ACPI is readable regardless of whether the audio card
#    managed to register, which makes this the one check we can insist on.
if ls /sys/bus/acpi/devices/ 2>/dev/null | grep -qi 'AWDZ8399'; then
    echo "  AW88399 amps       present (ACPI AWDZ8399)"
else
    hw_fail "No ACPI AWDZ8399 device: this machine has no AW88399 amplifiers." \
            "This fix cannot help it, and installing anyway would replace the" \
            "working in-tree Realtek codec driver with an out-of-tree one."
fi

# 2. Kernel version. The driver is in-tree from 7.3, so installing this on top is a
#    strict downgrade: same functionality, built from stale vendored headers.
k_maj="${KVER%%.*}"; k_rest="${KVER#*.}"; k_min="${k_rest%%.*}"
case "$k_maj.$k_min" in
    [0-9]*.[0-9]*) k_num=$(( k_maj * 1000 + k_min )) ;;
    *)             k_num=0 ;;   # unparseable: do not claim it is 7.3+
esac
if [ "$k_num" -ge 7003 ]; then
    hw_fail "Kernel $KVER already has AW88399 support in-tree (landed in 7.3)." \
            "Installing this out-of-tree copy would shadow the in-tree driver" \
            "with older code built against vendored headers. Use the stock" \
            "driver; you may only need the firmware blob (see README.md)."
else
    echo "  Kernel             $KVER (pre-7.3, in-tree driver absent)"
fi

# 3. Codec SSID. Advisory only, in both directions: an unsupported SSID is a
#    legitimate state for someone adding a HDA_CODEC_QUIRK line, and an *unreadable*
#    one usually means the analog card failed to register -- which is precisely the
#    broken state you reinstall from, so refusing here would lock you out.
ssid="$(awk '/^Codec: Realtek/{f=1} f&&/Subsystem Id/{print $3; exit}' \
        /proc/asound/*/codec#* 2>/dev/null || true)"
if [ -z "$ssid" ]; then
    echo "  Codec SSID         UNREADABLE (/proc/asound/*/codec#* absent)"
    echo "                     Usually means the analog card did not register -- a"
    echo "                     previous bad install or an ABI mismatch. Proceeding."
    echo "                     DMI product: $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
elif case " $SUPPORTED_SSIDS " in *" $ssid "*) true ;; *) false ;; esac; then
    echo "  Codec SSID         $ssid (in the quirk table)"
else
    echo "  Codec SSID         $ssid -- NOT in the quirk table"
    echo "                     Matched SSIDs: $SUPPORTED_SSIDS"
    echo "                     The fixup will not fire and the speakers will stay"
    echo "                     silent. Add a HDA_CODEC_QUIRK line in"
    echo "                     realtek/alc269.c first. Proceeding anyway."
fi
echo

echo "=== [2/10] ABI preflight ==="
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

echo "=== [3/10] Removing any previously registered versions ==="
# Every version, not just ours. A tree left behind by upstream ("1.0"), by another
# fork ("1.0.2"), or by an earlier build of this one would keep its modules in
# /updates/dkms, where depmod would happily load them instead of what we build below.
#
# This runs BEFORE staging on purpose: `dkms remove` deletes /usr/src/<pkg>-<ver> for
# trees it did not get from a package, so doing it afterwards can delete the source we
# just staged whenever the version string has not changed.
found_old=0
while read -r v; do
    [ -z "$v" ] && continue
    found_old=1
    echo "  removing $PKG/$v"
    dkms remove -m "$PKG" -v "$v" --all >/dev/null 2>&1 || true
    rm -rf "/usr/src/${PKG}-${v}"
done < <(dkms status -m "$PKG" 2>/dev/null \
         | sed -E "s|^${PKG}[/,] *||; s|[,:].*||" | awk 'NF' | sort -u)
[ "$found_old" -eq 0 ] && echo "  none registered"

echo "=== [4/10] Staging source into $DEST ==="
rm -rf "$DEST"
mkdir -p "$DEST"
tar -C "$SRC_DIR" \
    --exclude=.git --exclude='*.ko' --exclude='*.o' --exclude='.*.cmd' \
    --exclude='*.mod' --exclude='*.mod.c' --exclude=Module.symvers \
    --exclude=modules.order --exclude='.tmp_versions' \
    -cf - . | tar -C "$DEST" -xf -
echo "  staged $(find "$DEST" -name '*.c' | wc -l) C sources"
dkms add -m "$PKG" -v "$VER"

echo "=== [5/10] Building against $KVER ==="
dkms build -m "$PKG" -v "$VER" -k "$KVER"

echo "=== [6/10] Installing (DKMS signs with the enrolled MOK) ==="
dkms install -m "$PKG" -v "$VER" -k "$KVER" --force

echo "=== [7/10] Verifying Secure Boot signatures ==="
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

echo "=== [8/10] Module load ordering ==="
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

echo "=== [9/10] Firmware ==="
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

echo "=== [10/10] Initramfs ==="
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
