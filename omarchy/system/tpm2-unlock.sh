#!/usr/bin/env bash
#
# Make this laptop's LUKS root unlock from the TPM2 so it can reboot unattended.
#
#   sudo bash tpm2-unlock.sh convert   # stage 1: initramfs + kernel cmdline
#   <reboot, type your passphrase as usual, confirm it boots>
#   sudo bash tpm2-unlock.sh enroll    # stage 2: bind the key to the TPM
#   <reboot, should now unlock with no prompt>
#   sudo bash tpm2-unlock.sh revert    # undo either stage
#
# ---------------------------------------------------------------------------
# WHY TWO STAGES
#
# `systemd-cryptenroll --tpm2-device=auto` writes a LUKS2 *token*. Only the
# systemd-based initramfs (sd-encrypt) knows how to read that token. This
# machine currently builds a busybox initramfs -- /etc/mkinitcpio.conf.d/
# omarchy_hooks.conf sets:
#
#   HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms \
#          keymap consolefont block encrypt filesystems fsck btrfs-overlayfs)
#
# ...where `udev` + `encrypt` are the busybox pair. So enrolling the TPM first
# would silently do nothing. Stage 1 converts the initramfs and is verified by a
# reboot that still uses your passphrase; stage 2 only touches the LUKS header
# once stage 1 is known good. If stage 1 is going to fail, it fails while your
# passphrase keyslot is the only thing that matters.
#
# YOUR PASSPHRASE KEYSLOT IS NEVER REMOVED. It stays as the fallback.
#
# ---------------------------------------------------------------------------
# RUN THIS SITTING AT THE MACHINE, NOT OVER SSH, with an Arch/Omarchy USB stick
# in your pocket. It rewrites how the machine boots. `revert` exists, but a
# machine that will not boot cannot run `revert`.
# ---------------------------------------------------------------------------

set -euo pipefail

LUKS_PART=/dev/nvme0n1p2
LUKS_UUID=8851ac79-80d3-47bd-9e2e-f4497e31fd11
BACKUP=/root/pre-tpm2-backup
HOOKS_DROPIN=/etc/mkinitcpio.conf.d/zz-server-sd-encrypt.conf

(( EUID == 0 )) || { echo "Run with sudo: sudo bash $0 $*" >&2; exit 1; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }

# The cmdline currently says `cryptdevice=PARTUUID=...:root`, which is the
# busybox `encrypt` hook's syntax. sd-encrypt does not understand it and would
# leave the root device unopened. The systemd equivalent is rd.luks.name.
OLD_CRYPT='cryptdevice=PARTUUID=a64c4bb5-ad9a-4b44-81d8-e09ce4eb2c6c:root'
NEW_CRYPT="rd.luks.name=${LUKS_UUID}=root"

case "${1:-}" in

convert)
  step "Sanity checks"
  [[ -b $LUKS_PART ]] || { echo "no $LUKS_PART"; exit 1; }
  cryptsetup isLuks "$LUKS_PART" || { echo "$LUKS_PART is not LUKS"; exit 1; }
  [[ $(blkid -s UUID -o value "$LUKS_PART") == "$LUKS_UUID" ]] \
    || { echo "LUKS UUID changed -- edit this script"; exit 1; }
  for h in sd-encrypt sd-vconsole sd-btrfs-overlayfs; do
    [[ -f /usr/lib/initcpio/install/$h ]] || { echo "missing hook: $h"; exit 1; }
  done
  echo "ok"

  step "Backing up everything this stage touches -> $BACKUP"
  mkdir -p "$BACKUP"
  cp -a /etc/default/limine            "$BACKUP/default-limine"
  cp -a /etc/kernel/cmdline            "$BACKUP/kernel-cmdline"
  cp -a /etc/mkinitcpio.conf.d         "$BACKUP/mkinitcpio.conf.d"
  # A LUKS header backup is your last line of defence. Guard it: anyone holding
  # this file plus your passphrase can decrypt the disk, so it must not leave
  # root-only storage. Copy it to offline media and delete it from here.
  cryptsetup luksHeaderBackup "$LUKS_PART" --header-backup-file "$BACKUP/luks-header.img"
  chmod 600 "$BACKUP/luks-header.img"
  ls -la "$BACKUP"
  warn "Copy $BACKUP/luks-header.img to a USB stick and keep it offline."

  step "Writing $HOOKS_DROPIN"
  # NOT editing omarchy_hooks.conf: it is owned by the omarchy-settings package
  # and omarchy-update will overwrite it. mkinitcpio sources every drop-in in
  # this directory in sorted order, so a "zz-" file is read last and its plain
  # HOOKS= assignment overrides whatever the earlier files built up. This is the
  # update-safe way to change hooks on Omarchy.
  cat > "$HOOKS_DROPIN" <<'EOF'
# Systemd-based initramfs, required for TPM2-backed LUKS unlock.
# Sorts after omarchy_hooks.conf / omarchy_resume.conf / thunderbolt_module.conf,
# and replaces HOOKS outright.
#
# Mapping from the busybox line this replaces:
#   udev              -> systemd            (systemd runs as PID 1 in the initrd)
#   encrypt           -> sd-encrypt         (reads LUKS2 TPM2 tokens; the point)
#   keymap consolefont-> sd-vconsole        (systemd's console setup)
#   btrfs-overlayfs   -> sd-btrfs-overlayfs (limine's systemd variant; keeps
#                                            read-only snapshot booting working)
#   plymouth          -> plymouth           (unchanged: mkinitcpio's plymouth
#                                            hook detects the systemd initrd and
#                                            installs systemd-ask-password-plymouth)
#   resume            -> dropped            (systemd-hibernate-resume-generator
#                                            is built into the systemd hook)
HOOKS=(base systemd plymouth autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck sd-btrfs-overlayfs)

# MODULES from thunderbolt_module.conf is additive and survives; re-assert it
# here so this file is self-describing if that drop-in ever disappears.
MODULES+=(thunderbolt)
EOF
  cat "$HOOKS_DROPIN"

  step "Rewriting the kernel cmdline"
  echo "  from: $OLD_CRYPT"
  echo "  to:   $NEW_CRYPT"
  # Both files matter: limine-entry-tool reads /etc/default/limine to build the
  # boot entries, and mkinitcpio reads /etc/kernel/cmdline when embedding the
  # cmdline into the UKI. Leaving them disagreeing is how you get a machine that
  # boots one way from the menu and another way directly.
  sed -i "s|${OLD_CRYPT}|${NEW_CRYPT}|g" /etc/default/limine /etc/kernel/cmdline
  grep -H "$NEW_CRYPT" /etc/default/limine /etc/kernel/cmdline || {
    warn "cmdline substitution did not apply -- restoring backups"
    cp -a "$BACKUP/default-limine" /etc/default/limine
    cp -a "$BACKUP/kernel-cmdline" /etc/kernel/cmdline
    rm -f "$HOOKS_DROPIN"
    exit 1
  }

  step "Rebuilding initramfs and UKI"
  limine-mkinitcpio

  step "Verifying the new initramfs actually contains the systemd unlock path"
  img=$(ls -t /boot/EFI/Linux/omarchy*.efi 2>/dev/null | head -1)
  echo "UKI: ${img:-<none found>}"
  if lsinitcpio -l "$img" 2>/dev/null | grep -q 'systemd-cryptsetup'; then
    echo "  systemd-cryptsetup present: OK"
  else
    warn "Could not confirm systemd-cryptsetup inside the image."
    warn "Check 'lsinitcpio -a $img' before rebooting."
  fi

  cat <<'NEXT'

STAGE 1 DONE.

Reboot now. You should get your NORMAL passphrase prompt -- the TPM is not
involved yet. That prompt proves sd-encrypt works.

  * If it boots: run `sudo bash tpm2-unlock.sh enroll`.
  * If it does NOT boot: pick an older snapshot in the Limine menu, or boot the
    USB stick and run `tpm2-unlock.sh revert` from the chroot.
NEXT
  ;;

enroll)
  step "Confirming stage 1 actually took effect"
  # If the running system did not boot via the systemd initrd, enrolling would
  # produce a token nothing can read, and the next boot would silently fall back
  # to the passphrase. Refuse rather than pretend.
  if ! grep -q 'rd.luks.name' /proc/cmdline; then
    echo "This system did not boot with rd.luks.name -- stage 1 has not taken effect."
    echo "Run 'convert' and reboot first."; exit 1
  fi
  [[ -c /dev/tpmrm0 ]] || { echo "no TPM resource manager at /dev/tpmrm0"; exit 1; }
  echo "ok: booted via sd-encrypt, TPM present"

  step "Current LUKS keyslots and tokens (before)"
  cryptsetup luksDump "$LUKS_PART" | grep -E '^\s*[0-9]+: |^Tokens:|tpm2|luks2-keyslot' || true

  step "Enrolling the TPM2"
  # --tpm2-pcrs=7 binds to the Secure Boot policy state.
  #
  # BE CLEAR-EYED ABOUT WHAT THIS BUYS YOU: Secure Boot is DISABLED on this
  # machine, and /boot is unencrypted. Someone with physical possession can
  # modify the initramfs; PCR 7 will not change, so the TPM will hand over the
  # key to their modified image. TPM2 unlock here is a convenience feature, and
  # against a physical attacker with time it is close to having no full-disk
  # encryption at all. It still protects against a plain drive-pull.
  #
  # To make it meaningful later: enable Secure Boot, enroll your own keys, sign
  # the UKI, then re-enroll here with --tpm2-pcrs=7 (which then actually means
  # something) or 7+11. Binding to PCR 11 today would force a re-enroll after
  # every single kernel update, since 11 measures the UKI itself.
  #
  # --wipe-slot=tpm2 clears any previous TPM enrollment so re-runs are idempotent.
  # It does NOT touch your passphrase keyslot.
  systemd-cryptenroll "$LUKS_PART" --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7

  step "LUKS keyslots and tokens (after)"
  cryptsetup luksDump "$LUKS_PART" | grep -E '^\s*[0-9]+: |^Tokens:|tpm2|luks2-keyslot' || true

  step "Rebuilding boot images so the token is picked up"
  limine-mkinitcpio

  cat <<'NEXT'

STAGE 2 DONE.

Reboot. The machine should now go straight to the login screen with no
passphrase prompt, and (with autologin already on) straight into your Hyprland
session -- which is what makes unattended reboots work.

Your passphrase still works. Press Esc at the Plymouth splash if you ever need
to type it.

REMEMBER: a firmware update or a BIOS setting change alters PCR 7 and the TPM
will refuse to release the key. That is not a lockout -- type your passphrase,
then re-run `sudo bash tpm2-unlock.sh enroll`.
NEXT
  ;;

revert)
  step "Removing the TPM2 keyslot (passphrase keyslot untouched)"
  systemd-cryptenroll "$LUKS_PART" --wipe-slot=tpm2 2>/dev/null || echo "(no tpm2 slot to wipe)"

  step "Restoring initramfs hooks and cmdline"
  rm -fv "$HOOKS_DROPIN"
  [[ -f $BACKUP/default-limine ]] && cp -av "$BACKUP/default-limine" /etc/default/limine
  [[ -f $BACKUP/kernel-cmdline ]] && cp -av "$BACKUP/kernel-cmdline" /etc/kernel/cmdline

  step "Rebuilding boot images"
  limine-mkinitcpio
  echo "Reverted to passphrase-only boot. Reboot to confirm."
  ;;

*)
  echo "Usage: sudo bash $0 <convert|enroll|revert>" >&2
  exit 2
  ;;
esac
