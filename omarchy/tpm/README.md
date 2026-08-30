# TPM2 auto-unlock for LUKS root

Lets this machine unlock its encrypted root from the TPM instead of a typed
passphrase, so it can reboot unattended — after a power cut, a kernel update, or
a `reboot` issued over SSH. Without it, every reboot stops at the LUKS prompt
until someone is physically there, which for a headless server means a remote
`reboot` locks you out of your own machine.

Your passphrase is **never removed**. It stays as the fallback at every stage.

## Tested on

Everything here was run end to end on **this laptop** and confirmed working.

| | |
|---|---|
| Machine | Lenovo Yoga Pro 7 14IAH10 (83KF) |
| CPU | Intel Core Ultra 7 255H (Arrow Lake) |
| BIOS | QGCN34WW, 2025-11-24 |
| TPM | **Intel PTT firmware TPM**, `INTC7001:00`, `tpm_crb_acpi`, TPM 2.0 |
| Secure Boot | **disabled** |
| OS | Omarchy 4.0.1 |
| Kernel | 7.1.9-arch1-2 |
| systemd | 261.2 |
| cryptsetup | 2.8.7 |
| Bootloader | Limine 12.6.0, UKI enabled, limine-snapper-sync |
| Root | LUKS2 on `/dev/nvme0n1p2`, btrfs subvols `@ @home @log @pkg` |
| ESP | `/dev/nvme0n1p1`, vfat, mounted at `/boot` |
| Date | 2026-08-29 |

Verified working: boot goes straight to the session with no prompt, and the
passphrase still works as a fallback.

The script itself is **generic** — nothing about this machine is baked in. The
table above records where it has actually been exercised, not where it will run.

## Portability: what is detected, not hardcoded

Run `check` first on any machine. It changes nothing, works without root (with a
couple of fields degraded), and prints a full compatibility report plus a rescue
recipe generated from that machine's real layout.

```bash
bash tpm2-unlock.sh check
```

Discovered at run time:

| | how |
|---|---|
| LUKS partition | walk `findmnt /` → mapper → `lsblk -s` down to the backing partition |
| LUKS UUID | `cryptsetup luksUUID`, falling back to `lsblk -dn -o UUID` |
| dm name | preserved from the live crypt term, so `rd.luks.name=` keeps your mapper name |
| current crypt term | parsed from `/proc/cmdline` (`cryptdevice=` vs `rd.luks.*`) |
| which files carry it | every candidate bootloader config that actually contains the term — covers Limine, GRUB, systemd-boot entries and `/etc/kernel/cmdline` without special-casing |
| current `HOOKS` | sourcing `/etc/mkinitcpio.conf` then the drop-ins in sorted order, exactly as mkinitcpio does |
| new `HOOKS` | mapped **in place** from the current list, so hooks it does not recognise keep their position rather than being dropped by a fixed replacement list |
| rebuild command | `limine-mkinitcpio` if present, else `mkinitcpio -P` |
| rescue recipe | generated from live `findmnt` output, so every subvolume and the ESP are named correctly |

Hook mapping: `udev`→`systemd`, `encrypt`/`plymouth-encrypt`→`sd-encrypt`,
`keymap`+`consolefont`+`vconsole`→`sd-vconsole` (deduplicated),
`btrfs-overlayfs`→`sd-btrfs-overlayfs`, `resume` dropped. Everything else is
carried through untouched.

The drop-in it writes sets **only** `HOOKS`. An earlier version also re-asserted
`MODULES`, which produced a harmless but sloppy `thunderbolt thunderbolt`
duplicate on this machine.

`check` refuses to continue unless: root is on LUKS, the header is **LUKS2**
(LUKS1 has no token support at all), a TPM2 node exists **and PCR 7 actually
reads** (see Gotchas — a wedged fTPM still enumerates), systemd is built `+TPM2`,
`systemd-cryptenroll` exists, every replacement hook is installed, at least one
config file carries the crypt term, a rebuild command exists, and the machine is
UEFI. Secure Boot being off is reported as a note, not a failure.

## Why two stages

`systemd-cryptenroll` writes a LUKS2 **token**. Only a systemd-based initramfs
(`sd-encrypt`) can read one. Omarchy ships the **busybox** `encrypt` hook — that
is what `cryptdevice=PARTUUID=...` on the kernel command line means — and busybox
predates LUKS2 tokens entirely.

So enrolling first would write a perfectly valid token that nothing ever reads.
You would reboot, still get prompted, and have no error to explain why. Stage 1
replaces the machinery; stage 2 adds the key.

The reboot between them is the point: it is a **test with a free rollback**.
Stage 1 rewrites how the machine boots, which is the risky half. Stage 2 modifies
the LUKS header. Splitting them means a broken boot path is discovered while the
header is still pristine and the passphrase is the only thing that matters.

## Prerequisites

- **AC plugged in.** Both stages rewrite the UKI in `/boot`. Losing power
  mid-write leaves a truncated boot image and an unbootable machine.
- **A live USB already written** (Arch or Omarchy). See Rescue below.
- **TPM responsive:** `cat /sys/class/tpm/tpm0/pcr-sha256/7` must print a hash,
  not `Input/output error`. See Gotchas.
- **Firmware updates done first.** `sudo fwupdmgr get-updates` should be empty.
  A firmware or dbx update changes PCR 7 and invalidates the enrollment.
- **SSH working**, so you can watch what the machine does across both reboots.

## Stage 1 — convert

```bash
sudo bash tpm2-unlock.sh check      # always run this first
sudo bash tpm2-unlock.sh convert
sudo reboot
```

What it changes:

1. Writes `/etc/mkinitcpio.conf.d/zz-tpm2-sd-encrypt.conf`, replacing `HOOKS`
   with the mapped version of whatever that machine already had.
   A `zz-` drop-in rather than editing `omarchy_hooks.conf`, because that file
   belongs to the `omarchy-settings` package and is overwritten on update.

   | busybox | systemd | why |
   |---|---|---|
   | `udev` | `systemd` | real systemd as PID 1 in the initramfs |
   | `encrypt` | `sd-encrypt` | **the point** — can read LUKS2 tokens |
   | `keymap consolefont` | `sd-vconsole` | systemd console setup |
   | `btrfs-overlayfs` | `sd-btrfs-overlayfs` | keeps snapshot booting working |
   | `resume` | *(dropped)* | systemd handles resume natively |

2. Rewrites the crypt term in **every** config file found to contain it (on this
   machine: `/etc/default/limine` and `/etc/kernel/cmdline`):
   `cryptdevice=PARTUUID=...:root` → `rd.luks.name=<luks-uuid>=root`.
   Same instruction, different dialects. Changing hooks without the cmdline
   leaves the new initramfs unable to identify the device — unbootable.

3. Rebuilds the initramfs and UKI with `limine-mkinitcpio`, then greps the
   result to confirm `systemd-cryptsetup` is inside it.

Before touching anything it backs up to `/root/pre-tpm2-backup/`:
`cmdline/` (each edited file, numbered) plus a `manifest` mapping those back to
their original paths, `mkinitcpio.conf.d/`, `crypt-term-old`, a full
`luks-header.img`, and **a copy of this script** (because the script normally
lives in `@home`, which a minimal rescue chroot would not mount).

`revert` also still understands the flat `default-limine` / `kernel-cmdline`
layout written by the earlier machine-specific version, so an existing backup
made before this rewrite keeps working.

**Encryption is untouched by this stage.** Same master key, same passphrase, same
keyslots.

### Validating stage 1

The reboot **must still ask for your passphrase**. That is success — it proves
`sd-encrypt` works while the LUKS header is still pristine. Do not run stage 2
until you have seen it.

```bash
grep -o 'rd\.luks\.name=[^ ]*' /proc/cmdline    # not cryptdevice=
systemctl --failed                              # 0 units
journalctl -b -o short-monotonic | grep -iE 'systemd-cryptsetup|Initrd Root Device|Plymouth switch root'
```

Observed on this machine:

```
[ 5.823520] systemd-cryptsetup[279]: Set cipher aes, mode xts-plain64,
            key size 512 bits for device /dev/disk/by-uuid/8851ac79-...
[ 8.547949] Reached target Initrd Root Device.
[ 9.620239] Finished Plymouth switch root service.
```

The gap between those first two lines is the passphrase being typed. Plymouth
survived the conversion — the splash did not swallow the prompt.

Also confirm the backups, including the script copy:

```bash
sudo ls -la /root/pre-tpm2-backup/
sudo cp /root/pre-tpm2-backup/luks-header.img /path/to/usb/   # keep offline
```

Guard that file: anyone holding it **and** your passphrase can decrypt the disk.

## Stage 2 — enroll

```bash
sudo bash tpm2-unlock.sh enroll
sudo reboot
```

It refuses to run unless `/proc/cmdline` contains `rd.luks.name`, so it cannot
fire before stage 1 has actually taken effect.

The line that matters:

```
systemd-cryptenroll /dev/nvme0n1p2 --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7
```

It generates a random key, adds it as an **additional** LUKS keyslot, seals that
key in the TPM against PCR 7, and writes a token into the header pointing at it.
`--wipe-slot=tpm2` clears only a previous *TPM* slot so re-runs are idempotent;
it never touches the passphrase slot. Keyslots are printed before and after.

### Why PCR 7 and not PCR 11

PCR 11 measures the UKI itself, so it changes on **every kernel update** and
would force a re-enroll each time. PCR 7 measures Secure Boot policy, which is
stable across kernel updates.

Confirmed on this machine: PCR 7 was byte-identical before and after the stage 1
initramfs swap.

**Be clear about what PCR 7 buys with Secure Boot disabled: not much.** `/boot`
is unencrypted (it has to be), and PCR 7 records "Secure Boot off" either way, so
someone with physical possession could modify the initramfs and the TPM would
still release the key — into an autologin session. This is the accepted trade for
a machine in a secure facility. It **does** still protect against a pulled drive:
a different TPM cannot unseal the key.

To make it meaningful: enable Secure Boot, enroll your own keys, sign the UKI,
then re-enroll.

### Validating stage 2

The reboot should go **straight through with no prompt**, into the session.

```bash
grep -o rd.luks.name /proc/cmdline                          # systemd initramfs
sudo cryptsetup luksDump /dev/nvme0n1p2 | grep -A3 Tokens   # systemd-tpm2 token
systemctl --failed                                          # 0 units
```

Passphrase fallback: press **Esc** at the Plymouth splash.

Real test: `sudo reboot` over SSH, close the lid, walk away. If it returns to the
network by itself, it works.

## Reverting

Three levels. **Pick the smallest one that does what you want.**

### Level 1 — stop TPM unlock, keep the systemd initramfs (recommended)

```bash
sudo systemd-cryptenroll /dev/nvme0n1p2 --wipe-slot=tpm2
sudo reboot
```

Removes only the TPM keyslot. The boot path does not change, so this carries
**zero risk of breaking boot**. You are back to typing the passphrase, and
`enroll` re-enables it in one command.

This is almost always the right choice. The systemd initramfs is the modern Arch
default; busybox `encrypt` is the legacy path. Going back to it is another
boot-path change — another chance to break booting — in exchange for nothing.

### Level 2 — full revert to the busybox initramfs

```bash
sudo bash tpm2-unlock.sh revert
sudo reboot
```

Wipes the TPM keyslot, deletes the hooks drop-in, restores both cmdline files
from backup, rebuilds the UKI. You end up exactly as before stage 1, and the
reboot asks for your passphrase again.

It **refuses to start** unless both backups exist *and* contain a `cryptdevice=`
line, and it verifies the restore before rebuilding the boot image — so a failure
leaves the working UKI untouched rather than replacing it with a mismatched one.

The one real argument for this level: the `zz-` drop-in overrides `HOOKS`
wholesale, so future Omarchy improvements to that line are silently ignored.
If you have abandoned TPM unlock for good, returning to stock avoids that drift.

### Level 3 — by hand

If the backups are gone, `revert` refuses rather than half-finishing, and prints
these steps with the real values filled in. In **every** bootloader config that
contains it, replace the `rd.luks.name=...` term with the original
`cryptdevice=...` one, then rebuild:

```bash
sudo rm -f /etc/mkinitcpio.conf.d/zz-tpm2-sd-encrypt.conf
sudo limine-mkinitcpio          # or: mkinitcpio -P
```

`convert` writes the original term to `/root/pre-tpm2-backup/crypt-term-old`
precisely so it survives losing the rest. On **this** machine it is:

```
cryptdevice=PARTUUID=a64c4bb5-ad9a-4b44-81d8-e09ce4eb2c6c:root
```

and the files carrying it are `/etc/default/limine` and `/etc/kernel/cmdline`.

## Rescue from a live USB

This layout has **four btrfs subvolumes**. Mounting only `@` leaves `/home`
empty — and that is where this script normally lives, which is why `convert`
stashes a copy in `/root/pre-tpm2-backup/` (inside `@`).

Full repair chroot:

```bash
cryptsetup open /dev/nvme0n1p2 root          # your passphrase
mount -o subvol=@     /dev/mapper/root /mnt
mount -o subvol=@home /dev/mapper/root /mnt/home
mount -o subvol=@log  /dev/mapper/root /mnt/var/log
mount -o subvol=@pkg  /dev/mapper/root /mnt/var/cache/pacman/pkg
mount /dev/nvme0n1p1 /mnt/boot
arch-chroot /mnt bash /root/pre-tpm2-backup/tpm2-unlock.sh revert
```

Just to reach your **data** — no chroot needed:

```bash
cryptsetup open /dev/nvme0n1p2 root
mount -o subvol=@home /dev/mapper/root /mnt
ls /mnt/dheeraj
```

Nothing here damages the filesystem. A failure means the boot image is wrong, not
that the disk is hurt — every byte in `@home` is intact and reachable with the
passphrase.

## Gotchas

**A firmware or BIOS update breaks the unlock.** It changes PCR 7, the TPM
refuses to unseal, and you get the passphrase prompt back. Not a lockout — type
it, boot, and re-run `enroll`. Do firmware updates *before* enrolling.

**Suspend can wedge the fTPM.** Observed on this machine before suspend was
masked: after an s2idle cycle the kernel logged

```
tpm tpm0: NULL Seed name comparison failed
tpm_crb_acpi INTC7001:00: Ignoring error -5 while suspending
```

and every TPM read returned `Input/output error` until a reboot — which would
make `enroll` fail with no obvious cause. The server config masks `sleep.target`
and `suspend.target`, so this should not recur. If PCR reads ever fail, reboot.

**`fwupdmgr security` reporting `TPM v2.0: Not found` means exactly this**, not a
missing chip. `systemd-cryptenroll --tpm2-device=list` only enumerates the device
node, so it still looks fine — reading a PCR is the real test.

**Clearing the TPM or resetting BIOS defaults destroys the sealed key.** This is
a *firmware* TPM, so its state lives in firmware. Passphrase still works.
