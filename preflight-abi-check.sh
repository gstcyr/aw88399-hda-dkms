#!/bin/bash
# Preflight ABI check -- run this BEFORE installing, and after every kernel update.
#
# WHY THIS EXISTS
#
# This project vendors private kernel headers (common/hda_local.h, common/generic.h,
# realtek/realtek.h) but ships no matching .c files. So realtek/alc269.c allocates and
# populates `struct alc_spec` using *these* struct definitions, while the code that
# reads that struct back lives in the in-tree snd_hda_codec_generic module and uses
# *the running kernel's* definitions. If the two disagree by even one member, every
# field past that point is read from the wrong offset.
#
# That is not a theoretical concern. On Ubuntu's 7.0.0-31, `struct hda_multi_out` had
# gained a trailing member these headers lacked (`struct snd_kcontrol *share_spdif_kctl`),
# making it 96 bytes instead of 104 and shifting all of hda_gen_spec after offset 184:
#
#     BUG: unable to handle page fault for address: 0000000000010000
#     RIP: try_assign_dacs+0x8b/0x6a0 [snd_hda_codec_generic]
#
# The result is that the entire "HDA Intel PCH" card fails to register -- no analog
# audio at all, plus a tainted kernel.
#
# Module symbol versioning (MODVERSIONS) CANNOT catch this. Symbol CRCs hash the
# signatures of exported *functions*; both sides agree that
# snd_hda_gen_parse_auto_config() takes a `struct hda_codec *`, so the CRC is identical
# even though the layout of a struct reached through that pointer is not. The build is
# clean, modprobe is happy, and the failure appears only at runtime as memory
# corruption. A human has to check, so this script does it.
#
# HOW
#
# The kernel ships its own BTF type information at /sys/kernel/btf, so no kernel source
# is needed. We compile this tree's objects (which carry DWARF), then compare every
# struct that appears in both against the kernel's own definition.
#
# LIMITATION -- READ THIS
#
# /sys/kernel/btf describes the RUNNING kernel only. Ubuntu's signed kernel images do
# not yield an extractable vmlinux, so this cannot validate a kernel you have not booted.
# Therefore the safe sequence after a kernel update is:
#
#     1. boot the new kernel (audio will be stock: silent speakers, but a healthy card)
#     2. run this script
#     3. if it passes, run install-dkms-signed.sh
#
# This is also why dkms.conf sets AUTOINSTALL="no". If DKMS rebuilt automatically at
# apt-upgrade time it would produce an unverified module for a kernel nobody has
# checked, and you would boot straight into the oops above.
#
# Exit status: 0 = safe to install, 1 = DO NOT INSTALL, 2 = could not check.

set -uo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
KVER="$(uname -r)"
KBUILD="/lib/modules/$KVER/build"

# Structs that cross the module boundary and have actually bitten us. These are checked
# explicitly and a failure to even locate them is treated as an error, so they can never
# be silently skipped.
CRITICAL=(hda_multi_out hda_gen_spec alc_spec)

# Kernel BTF sources we link against. vmlinux first; the rest are split BTF.
BTF_MODULES=(
    snd_hda_codec_generic
    snd_hda_codec_realtek_lib
    snd_hda_codec
    snd_hda_core
    snd_hda_scodec_component
    snd_soc_core
)

die()  { echo "ERROR: $*" >&2; exit 2; }
note() { echo "  $*"; }

echo "=== AW88399 preflight ABI check ==="
echo "    kernel: $KVER"
echo

# ---------------------------------------------------------------- prerequisites
echo "--- [1/4] Prerequisites ---"
command -v pahole >/dev/null 2>&1 || die "pahole not found. Install it: sudo apt install dwarves"
note "pahole: $(pahole --version 2>&1 | head -1)"

[ -r /sys/kernel/btf/vmlinux ] || die "/sys/kernel/btf/vmlinux not readable. This kernel lacks BTF (CONFIG_DEBUG_INFO_BTF), so the check cannot run."
note "vmlinux BTF: present"

[ -d "$KBUILD" ] || die "kernel headers missing. Install: sudo apt install linux-headers-$KVER"
note "kernel headers: $KBUILD"
echo

# ---------------------------------------------------------------- build
# Build a throwaway copy so the source tree stays clean and we never reuse a stale .o
# from a different kernel.
echo "--- [2/4] Building objects (throwaway copy) ---"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

tar -C "$SRC_DIR" \
    --exclude=.git --exclude='*.o' --exclude='*.ko' --exclude='.*.cmd' \
    --exclude='*.mod' --exclude='*.mod.c' --exclude=Module.symvers \
    --exclude=modules.order --exclude='.tmp_versions' \
    -cf - . 2>/dev/null | tar -C "$TMP" -xf -

if ! make -C "$KBUILD" M="$TMP" modules >"$TMP/.build.log" 2>&1; then
    echo
    echo "  Build FAILED. Last 20 lines:" >&2
    tail -20 "$TMP/.build.log" >&2
    exit 2
fi
nobj=$(find "$TMP" -name '*.o' ! -name '*.mod.o' | wc -l)
note "built $nobj objects"
[ "$nobj" -gt 0 ] || die "no objects produced"
echo

# ---------------------------------------------------------------- kernel size table
echo "--- [3/4] Reading kernel struct layouts from BTF ---"
KTAB="$TMP/kernel_sizes.txt"
: > "$KTAB"

pahole --sizes /sys/kernel/btf/vmlinux 2>/dev/null \
    | awk 'NF>=2 {print $1, $2, "vmlinux"}' >> "$KTAB"

for m in "${BTF_MODULES[@]}"; do
    [ -r "/sys/kernel/btf/$m" ] || continue
    pahole --sizes --btf_base /sys/kernel/btf/vmlinux "/sys/kernel/btf/$m" 2>/dev/null \
        | awk -v s="$m" 'NF>=2 {print $1, $2, s}' >> "$KTAB"
done

ktypes=$(cut -d' ' -f1 "$KTAB" | sort -u | wc -l)
note "$ktypes distinct struct names from $(( ${#BTF_MODULES[@]} + 1 )) BTF sources"
[ "$ktypes" -gt 100 ] || die "implausibly few kernel types ($ktypes); BTF read probably failed"
echo

# Look up every size the kernel reports for a struct name (may be several sources).
ksizes_for() { awk -v n="$1" '$1==n {print $2}' "$KTAB" | sort -u; }

# ---------------------------------------------------------------- compare
echo "--- [4/4] Comparing this tree against the kernel ---"
MISMATCH_LOG="$TMP/mismatches.txt"
: > "$MISMATCH_LOG"
compared=0

# Broad sweep. A struct passes if ANY kernel BTF source agrees on its size; different
# modules can legitimately define unrelated local structs that happen to share a name,
# and we do not want those as false positives. The explicit CRITICAL pass below is what
# guarantees the structs that matter are really checked.
while read -r name size _; do
    mapfile -t ks < <(ksizes_for "$name")
    [ "${#ks[@]}" -eq 0 ] && continue
    compared=$((compared + 1))
    for k in "${ks[@]}"; do
        [ "$k" = "$size" ] && continue 2
    done
    printf '%s  this_tree=%s  kernel=%s\n' "$name" "$size" "$(printf '%s,' "${ks[@]}" | sed 's/,$//')" >> "$MISMATCH_LOG"
done < <(find "$TMP" -name '*.o' ! -name '*.mod.o' -exec pahole --sizes {} \; 2>/dev/null \
         | awk 'NF>=2 {print $1, $2}' | sort -u)

note "compared $compared shared structs"

# Explicit check of the known-dangerous structs. Unlike the sweep, "not found" is fatal
# here -- if we cannot locate hda_gen_spec we have no idea whether it is safe.
crit_fail=0
for S in "${CRITICAL[@]}"; do
    rs=$(find "$TMP" -name '*.o' ! -name '*.mod.o' -exec pahole --sizes {} \; 2>/dev/null \
         | awk -v n="$S" '$1==n {print $2; exit}')
    mapfile -t ks < <(ksizes_for "$S")

    if [ -z "$rs" ]; then
        printf "  %-16s SKIPPED (not referenced by this tree)\n" "$S"
        continue
    fi
    if [ "${#ks[@]}" -eq 0 ]; then
        printf "  %-16s UNVERIFIABLE (absent from kernel BTF)\n" "$S"
        crit_fail=1
        continue
    fi
    ok=0
    for k in "${ks[@]}"; do [ "$k" = "$rs" ] && ok=1; done
    if [ "$ok" -eq 1 ]; then
        printf "  %-16s OK        this_tree=%s kernel=%s\n" "$S" "$rs" "$rs"
    else
        printf "  %-16s MISMATCH  this_tree=%s kernel=%s\n" "$S" "$rs" "$(printf '%s,' "${ks[@]}" | sed 's/,$//')"
        crit_fail=1
    fi
done
echo

# ---------------------------------------------------------------- verdict
if [ -s "$MISMATCH_LOG" ] || [ "$crit_fail" -ne 0 ]; then
    echo "=============================================================="
    echo " FAIL -- DO NOT INSTALL"
    echo "=============================================================="
    if [ -s "$MISMATCH_LOG" ]; then
        echo
        echo "Structs whose layout disagrees with the running kernel:"
        sed 's/^/  /' "$MISMATCH_LOG"
    fi
    cat <<EOF

Installing now would build cleanly and then corrupt memory at boot, most likely
taking the whole "HDA Intel PCH" card down with a page fault in try_assign_dacs.

To fix, align the vendored header with the kernel. Inspect the real layout:

  pahole -C <struct> --btf_base /sys/kernel/btf/vmlinux \\
      /sys/kernel/btf/snd_hda_codec_generic

and compare against this tree's:

  pahole -C <struct> /path/to/built/object.o

Then add or remove the differing member in common/hda_local.h (or common/generic.h /
realtek/realtek.h, whichever declares it) so the sizes match exactly. Members are
normally appended at the end, so a trailing pointer is the usual culprit. Re-run this
script until it passes.

Note that a member missing from these headers AND a member present here but absent
from the kernel are both fatal -- the error can run in either direction, so do not
simply keep adding fields.
EOF
    exit 1
fi

echo "=============================================================="
echo " PASS -- layouts match the running kernel ($KVER)"
echo "=============================================================="
echo
echo "Safe to install:  sudo $SRC_DIR/install-dkms-signed.sh"
exit 0
