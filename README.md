# AW88399 HDA speaker fix — patched for Ubuntu kernel 7.0

Working internal speakers on Lenovo Legion laptops with **Awinic AW88399** smart
amplifiers, on Ubuntu kernels that predate upstream support. No kernel rebuild.

This is a **patched fork** of [`nuclearcat/aw88399-hda-dkms`](https://github.com/nuclearcat/aw88399-hda-dkms)
(base commit `7c307da`). Upstream does not build on kernel 7.0, and once it does build
it crashes the audio stack. See [What we changed](#what-we-changed).

> **Read this before you start.** This is an out-of-tree driver that compiles against
> *vendored copies* of private kernel headers. It is safe on a kernel whose struct
> layouts match those copies and **actively dangerous on one that does not** — the
> mismatch compiles perfectly cleanly and then corrupts kernel memory at boot. The
> `preflight-abi-check.sh` gate exists to catch exactly that. Do not bypass it.
>
> If you can run **kernel 7.3 or newer, use that instead.** The driver is upstream
> there and none of this applies.

---

## Is this for you?

| Requirement | Why |
|---|---|
| Lenovo Legion with AW88399 amps | Check: `ls /sys/bus/acpi/devices/ \| grep -i AWDZ8399` — if empty, this is the wrong fix |
| Codec SSID in the supported list | See [Hardware coverage](#hardware-coverage) below |
| Kernel older than 7.3 | On 7.3+ the driver is in-tree; installing this on top is pointless and risky |
| `pahole` available | `sudo apt install dwarves` — required by the preflight gate |
| Kernel built with BTF | `[ -r /sys/kernel/btf/vmlinux ]`. True on Ubuntu stock kernels |
| MOK enrolled, if Secure Boot is on | DKMS signs locally; see [Secure Boot](#secure-boot) |

Verified working on: **Legion Pro 7 16IAX10H**, Ubuntu 24.04.5, kernel
`7.0.0-31-generic`, codec SSID `0x17aa3907`.

## Install

```bash
sudo apt install dwarves linux-headers-$(uname -r)   # prerequisites

./preflight-abi-check.sh                             # 1. verify — runs unprivileged
sudo ./install-dkms-signed.sh                        # 2. install (re-runs the gate)
sudo reboot                                          # 3.
```

The preflight is unprivileged and changes nothing, so always run it on its own first.
The installer runs it again as a hard gate and refuses to proceed if it fails.

The installer also gates on the **hardware** before it touches anything (step 1), which
the preflight does not — the preflight only compares struct layouts against the running
kernel. It refuses outright if there is no ACPI `AWDZ8399` device, or if the kernel is
7.3 or newer and already has the driver in-tree. It warns but continues if the codec
SSID is unsupported, or unreadable because the card failed to register — that second
case is the broken state you reinstall *from*, so refusing there would lock you out.
`ALLOW_UNVERIFIED_HW=1` forces past the two fatal checks.

This matters because installing on the wrong machine is not a no-op: the patched
`snd-hda-codec-alc269` lands in `/updates/dkms`, which `depmod` prefers, so it replaces
the stock Realtek codec driver on *any* machine with a Realtek codec.

### Verify after rebooting

```bash
cat /proc/asound/cards                 # expect an "HDA Intel PCH" entry
amixer -c PCH scontrols | grep -i speaker
journalctl -k -b | grep -icE 'BUG:|Oops|try_assign'   # must be 0
cat /proc/sys/kernel/tainted           # 4096 is expected (out-of-tree module)
```

A healthy install shows a **`Bass Speaker`** control with a working volume range, plus
`Internal Mic` / `Internal Mic Boost` still present.

### Roll back

```bash
sudo ./uninstall-dkms.sh && sudo reboot
```

Restores the stock audio stack: the in-tree modules were never overwritten.

---

## After every kernel update — important

**`dkms.conf` sets `AUTOINSTALL="no"` deliberately.** This is unusual for a DKMS
package, and it is the single most important safety property of this fork.

Because the vendored headers only match some kernels, an automatic rebuild at
`apt upgrade` time would silently produce modules for a kernel nobody has verified, and
you would boot straight into a page fault that takes the whole analog card down. The
preflight gate *cannot* prevent that, because `/sys/kernel/btf` only describes the
**running** kernel and Ubuntu's signed images yield no extractable `vmlinux` — so a
kernel you have not booted cannot be checked at all.

With `AUTOINSTALL="no"` a kernel update fails safe: the new kernel simply has stock
audio — silent speakers, but a healthy card and no oops. The sequence is:

```bash
# after booting the new kernel
./preflight-abi-check.sh          # PASS -> proceed;  FAIL -> fix the header first
sudo ./install-dkms-signed.sh
sudo reboot
```

If the preflight fails it prints the offending struct, both sizes, and how to find the
differing member. **The error runs in both directions** — a member missing from these
headers *and* a member present here but absent from the kernel are equally fatal. Do
not just keep appending fields.

---

## What we changed

Upstream `7c307da` does not work on kernel 7.0. Six fixes, three of them bugs that
affect any kernel:

| # | Problem | Fix |
|---|---|---|
| 1 | `obj-m += realtek/snd-hda-codec-alc269.o` — since 6.16 `MODULE_DEVICE_TABLE()` pastes `KBUILD_MODNAME` into a C identifier, so a `/` in a module name is a syntax error | Declare modules at the `Makefile` top level with `-y` object mappings; `BUILT_MODULE_LOCATION[*]` → `./` |
| 2 | `snd_soc_kcontrol_component()` removed from `<sound/soc.h>` in 7.0 (16 call sites) | Function-like macro in `soc-codecs/aw88399.h` wrapping `snd_kcontrol_chip()`; shadows the inline on older kernels so it builds either way |
| 3 | **`struct hda_multi_out` ABI mismatch** → page fault in `try_assign_dacs`, entire `HDA Intel PCH` card fails to register | Added the missing trailing `struct snd_kcontrol *share_spdif_kctl` to `common/hda_local.h`; added `preflight-abi-check.sh` |
| 4 | `alc287_fixup_legion_16iax_aw88399()` is an **empty stub** upstream | Ported the real body: `suppress_auto_mic`, force DAC `0x02` on bass speaker pin `0x17` (default `0x06` has no volume controls), clamp playback to 2 channels |
| 5 | Quirks registered with `SND_PCI_QUIRK`, which matches the **controller's** PCI subsystem ID (`17aa:3d6c` on a 16IAX10H) — so they can never fire | Switched to `HDA_CODEC_QUIRK`, which matches the **codec** SSID (`17aa:3907`) |
| 6 | `install.sh` hand-copies `.ko` files, producing unsigned modules that Secure Boot silently refuses; `make_deb.sh` sets a harmful boot parameter | Use `dkms add/build/install` so Ubuntu signs with the enrolled MOK, and verify `modinfo -F signer` before touching boot config |

The code diff from upstream is small — 5 files, 91 insertions, most of it comment:

```
Makefile              20 +-    (1)
soc-codecs/aw88399.h  12 +     (2)
common/hda_local.h    16 +     (3)
realtek/alc269.c      26 +-    (4, 5)
dkms.conf             34 +-    (1, AUTOINSTALL, PACKAGE_VERSION)
```

Fix 6 is not in that diff: it is the two install scripts, which replace upstream's
`install.sh` and `make_deb.sh` rather than patching them.

### Why fix 3 was so hard to find

Module symbol versioning cannot detect it. Symbol CRCs hash the signatures of exported
*functions* — both sides agree that `snd_hda_gen_parse_auto_config()` takes a
`struct hda_codec *`, so the CRC matches even though the layout of a struct reached
through that pointer does not. The build is clean, `modprobe` is happy, and the only
symptom is memory corruption at runtime. Worse, the amps initialise *fully* first —
I²C clients created, ACPI calibration read, both side-codecs registered and bound — so
the logs look healthy right up to the oops, which points attention at the wrong layer.

### Do NOT set `snd_intel_dspcfg.dsp_driver=3`

`README.upstream.md` calls this parameter "Required" and upstream's `make_deb.sh`
installs it. It is wrong on this hardware and we deliberately omit it. (Upstream's
`install.sh` and `make_deb.sh` are **not** shipped in this archive — the first produces
unsigned modules that Secure Boot silently refuses, the second sets this parameter.)

The claim is that the amps need an I²S clock from the Intel DSP to lock their PLL.
There is no PLL check anywhere in the code this tree ships (grep `side-codecs/*.c` and
`aw88399_setup.c` for `pll` — only copyright lines). It appears to be a leftover from
an older patch generation paired with newer codec code.

What it actually does is force the SOF path, loading `snd_soc_skl_hda_dsp` so the codec
probes via `hdac_hda` instead of legacy `snd_hda_intel`. It also **disables the internal
microphone**, because `alsa-ucm-conf` 1.2.10 has no `sof-hda-dsp` profile. Staying on
the legacy HDA path keeps both speakers and mic working.

The `ucm2/` configs in this tree are never installed by any installer here; they would
only matter if something forced SOF mode.

---

## Hardware coverage

This tree matches codec SSIDs:

```
0x17aa3906  0x17aa3907   Legion Pro 7i 16IAX10H / Y9000P IAX10
0x17aa3938               Legion Pro 7 16AFR10H
```

The maintained upstream patch covers more — `3927 3928 3934 3935 3936 3937 3939`
(Legion R9000P ADR10 / AFR10 / ADR10H, and the second 16AFR10H ID). **If your SSID is
not listed above, this fork will do nothing at all.** Find yours with:

```bash
awk '/^Codec: Realtek/{f=1} f&&/Subsystem Id/{print $3; exit}' /proc/asound/*/codec#*
```

To add one, copy an existing `HDA_CODEC_QUIRK(0x17aa, ...)` line in
`realtek/alc269.c`. Note these are **codec** SSIDs, not the controller's PCI subsystem
ID — see fix 5. Do not assume the two are equal; on a 16IAX10H they differ
(`17aa:3d6c` vs `17aa:3907`).

## Secure Boot

DKMS signs modules with the machine's own enrolled MOK, so **this cannot be centralised
— each machine needs its own key.** If none is enrolled, step 7 of the installer
reports `UNSIGNED` and aborts *before* touching any boot configuration, leaving the
current boot untouched.

To enrol one: `sudo mokutil --import /var/lib/shim-signed/mok/MOK.der`, then confirm in
the MOK manager on the next reboot. A successful install shows your key name as the
signer for all six modules.

## Firmware

`firmware/aw88399_acf.bin` is the amps' ACF calibration/config blob. Without it the
modules load and bind correctly and the speakers stay **silent**, with nothing obviously
wrong in `dmesg` — an easy failure to misdiagnose. Upstream's `install.sh` never
installs it; `install-dkms-signed.sh` step 9 does, backing up any existing copy.

It installs to `/lib/firmware/aw88399_acf.bin`, matching `AW88399_ACF_FILE` in
`soc-codecs/aw88399.h`. Kernel 7.4-rc1 moved upstream to
`/lib/firmware/awinic/aw88399_acf_<SSID>.bin`; this tree predates that and hardcodes the
old name, so do not "modernise" the path without changing the `#define`.

`uninstall-dkms.sh` leaves the blob in place on purpose — it is inert without the
driver and is what a stock 7.3+ kernel will want anyway.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Preflight FAILs | Vendored header does not match this kernel. Fix the struct, don't install. See [after a kernel update](#after-every-kernel-update--important) |
| `HDA Intel PCH` missing from `/proc/asound/cards`, `try_assign_dacs` in `journalctl -k` | ABI mismatch installed anyway, or `dsp_driver=3` is set. Check `/etc/default/grub.d/` for a stale `99-aw88399-hda.cfg` |
| Modules load, amps bind, speakers silent | Missing/wrong firmware — re-run the installer and check step 9 |
| Modules absent from `lsmod` | Unsigned under Secure Boot. `dmesg \| grep -i 'key was rejected'` |
| Nothing happens at all, no `aw88399` lines in `dmesg` | SSID not matched — see [Hardware coverage](#hardware-coverage) |
| `Bass Speaker` has no volume control | Fix 4 not applied — the fixup is the empty upstream stub |
| Internal mic gone | `dsp_driver=3` is set; remove it |

Useful one-shot diagnostic:

```bash
cat /proc/asound/cards; echo ---; lsmod | grep aw88399; echo ---
journalctl -k -b | grep -iE 'aw88399|BUG:|Oops|try_assign'
```

## Licence and provenance

Derived from the Linux kernel (**GPL-2.0**) and `nuclearcat/aw88399-hda-dkms`
(base commit `7c307da`). All modules declare `MODULE_LICENSE("GPL")`, so redistribution
is under GPL-2.0. The full licence text is in [`LICENSE`](LICENSE); `PROVENANCE` records
which files derive from where.

Upstream ships no licence file despite the same GPL obligations — adding one is the
fourth thing worth sending back.

The Realtek codec patches correspond to the maintained guide at
[`nadimkobeissi/16iax10h-linux-sound-saga`](https://github.com/nadimkobeissi/16iax10h-linux-sound-saga),
which is the authoritative reference for this hardware and tracks upstream kernel
status.

**`firmware/aw88399_acf.bin` is vendor firmware and its redistribution terms are not
established here.** Confirm you are permitted to redistribute it before sharing this
archive outside your organisation.

### Worth sending upstream

Fixes 3, 4 and 5 are genuine defects in `nuclearcat/aw88399-hda-dkms` that affect every
user of that repo, not local configuration. They are worth reporting upstream. So is the
missing licence file — upstream ships none despite the same GPL-2.0 obligations.

Fix 3 has independent corroboration. The fork at
[`fbottarel/aw88399-hda-dkms`](https://github.com/fbottarel/aw88399-hda-dkms) (branch
`legion-fix`) reached the identical one-line conclusion about `struct hda_multi_out`
about ten weeks earlier — commit `1c4f2a8`, *"fix struct hda_multi_out layout drift
causing NULL deref crash"*, applied in `82bd903`. Credit for that independent diagnosis
is theirs; this tree arrived at it separately via BTF and `pahole`. Two forks landing on
the same missing member is the strongest possible argument that it is an upstream defect.

That fork is worth knowing about if you are choosing between them. It converges on fixes
1, 2 and 3, and adds a `WARN_ON_ONCE(!cdc)` guard this tree does not have. It differs in
that it **keeps `dsp_driver=3`** and solves the resulting loss of the internal microphone
by diverting the distribution's HDA UCM2 configs — a legitimate route, at the cost of
fighting `alsa-ucm-conf` package upgrades indefinitely. It does not carry fix 5, so its
quirk entries cannot match a 16IAX10H's controller SSID; it does not sign modules; and it
leaves `AUTOINSTALL="yes"`. See `PROVENANCE` for detail.
