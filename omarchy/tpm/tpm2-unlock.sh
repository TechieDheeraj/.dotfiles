#!/usr/bin/env bash
#
# TPM2 auto-unlock for a LUKS root, so the machine can reboot unattended.
#
#   sudo bash tpm2-unlock.sh check     # compatibility report, changes nothing
#   sudo bash tpm2-unlock.sh convert   # stage 1: initramfs + kernel cmdline
#   <reboot, type your passphrase as usual, confirm it boots>
#   sudo bash tpm2-unlock.sh enroll    # stage 2: bind a key to the TPM
#   <reboot, should now unlock with no prompt>
#   sudo bash tpm2-unlock.sh revert    # undo either stage
#
# Nothing about this machine is hardcoded: the LUKS device, its UUID, the crypt
# term on the kernel command line, which files carry that command line, the
# current mkinitcpio HOOKS, and the image-rebuild command are all discovered at
# run time. `check` refuses to go further on a system that cannot support this.
#
# WHY TWO STAGES
#
# `systemd-cryptenroll` writes a LUKS2 *token*, and only a systemd initramfs
# (sd-encrypt) can read one. A busybox initramfs -- the `udev` + `encrypt` hook
# pair, which puts `cryptdevice=...` on the kernel command line -- predates LUKS2
# tokens entirely, so enrolling first would write a valid token that nothing ever
# reads: you would reboot, still be prompted, and have no error to explain it.
# Stage 1 replaces the machinery, stage 2 adds the key.
#
# The reboot between them is a test with a free rollback. Stage 1 rewrites how
# the machine boots, which is the risky half; stage 2 modifies the LUKS header.
# Split, a broken boot path is found while the header is untouched and the
# passphrase is the only thing that matters.
#
# YOUR PASSPHRASE KEYSLOT IS NEVER REMOVED.
#
# RUN THIS AT THE MACHINE, NOT OVER SSH, with a live USB in your pocket.
# `check` prints a rescue recipe tailored to this machine's actual layout.

set -euo pipefail

BACKUP=${TPM2_BACKUP_DIR:-/root/pre-tpm2-backup}
HOOKS_DROPIN=/etc/mkinitcpio.conf.d/zz-tpm2-sd-encrypt.conf
MANIFEST="$BACKUP/manifest"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mxx  %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '    \033[32m✔\033[0m %-30s %s\n' "$1" "${2-}"; }
bad()  { printf '    \033[31m✘\033[0m %-30s %s\n' "$1" "${2-}"; COMPAT=0; }
note() { printf '    \033[33m·\033[0m %-30s %s\n' "$1" "${2-}"; }

# ---------------------------------------------------------------------------
# Discovery. Every one of these was a hardcoded constant in the first version.
# ---------------------------------------------------------------------------

ROOT_SRC=""; MAPPER=""; LUKS_PART=""; LUKS_UUID=""; LUKS_VERSION=""
CRYPT_OLD=""; CRYPT_NEW=""; DM_NAME=""; BOOT_STYLE=""
CMDLINE_FILES=(); HOOKS_NOW=(); HOOKS_NEW=(); REBUILD=()

detect_root_luks() {
  ROOT_SRC=$(findmnt -n -o SOURCE / | sed 's/\[.*//')
  [[ $ROOT_SRC == /dev/mapper/* || $ROOT_SRC == /dev/dm-* ]] || return 1
  MAPPER=$ROOT_SRC
  DM_NAME=$(basename "$(realpath "$ROOT_SRC")")
  DM_NAME=$(dmsetup info -c --noheadings -o name "$DM_NAME" 2>/dev/null || basename "$ROOT_SRC")

  # Walk the device tree downwards from the mapper to the partition holding it.
  # lsblk -s prints the dependency chain; the first `part` line is the backer.
  LUKS_PART=$(lsblk -s -n -p -o NAME,TYPE "$ROOT_SRC" 2>/dev/null |
    awk '$2=="part"{gsub(/[^\/a-zA-Z0-9_-]/,"",$1); print $1; exit}')
  [[ -b ${LUKS_PART:-} ]] || return 1

  # Identify LUKS from lsblk rather than `cryptsetup isLuks`: cryptsetup needs
  # read access to the raw device, so it fails for a non-root `check` run and
  # would abort discovery before the UUID is ever read.
  [[ $(lsblk -dn -o FSTYPE "$LUKS_PART" 2>/dev/null) == crypto_LUKS ]] ||
    cryptsetup isLuks "$LUKS_PART" 2>/dev/null || return 1

  # -d matters: without it lsblk also prints the UUID of the filesystem INSIDE
  # the container, which is not the LUKS UUID and would build a wrong
  # rd.luks.name= term.
  LUKS_UUID=$(cryptsetup luksUUID "$LUKS_PART" 2>/dev/null ||
              lsblk -dn -o UUID "$LUKS_PART" 2>/dev/null | head -1)
  LUKS_VERSION=$(cryptsetup luksDump "$LUKS_PART" 2>/dev/null |
                 awk -F': *' '/^Version/{print $2; exit}')
  return 0
}

# The crypt term names the device to unlock. Busybox spells it cryptdevice=,
# systemd spells it rd.luks.name= / rd.luks.uuid=. Read whichever is live, then
# build the systemd form from it, preserving the mapper name.
detect_cmdline_terms() {
  CRYPT_OLD=$(tr ' ' '\n' < /proc/cmdline |
              grep -m1 -E '^(cryptdevice|rd\.luks\.(name|uuid))=' || true)
  local name=${DM_NAME:-root}
  case $CRYPT_OLD in
    cryptdevice=*)
      # cryptdevice=<device>:<dm-name>[:options]
      name=$(cut -d: -f2 <<<"${CRYPT_OLD#cryptdevice=}")
      [[ -n $name ]] || name=root
      BOOT_STYLE=busybox
      ;;
    rd.luks.name=*|rd.luks.uuid=*) BOOT_STYLE=systemd ;;
    *) BOOT_STYLE=unknown ;;
  esac
  CRYPT_NEW="rd.luks.name=${LUKS_UUID}=${name}"
}

# Rather than guessing per bootloader, find every config file that actually
# contains the live crypt term and edit all of them. Covers Limine, GRUB,
# systemd-boot entries and plain /etc/kernel/cmdline without special-casing.
detect_cmdline_files() {
  CMDLINE_FILES=()
  [[ -n $CRYPT_OLD ]] || return 0
  local f
  for f in /etc/kernel/cmdline /etc/default/limine /etc/default/grub \
           /etc/limine-entry-tool.d/*.conf /boot/loader/entries/*.conf \
           /etc/cmdline.d/*.conf; do
    [[ -f $f ]] || continue
    grep -qF "$CRYPT_OLD" "$f" 2>/dev/null && CMDLINE_FILES+=("$f")
  done
}

# mkinitcpio's own precedence: /etc/mkinitcpio.conf, then the .conf drop-ins in
# sorted order. Sourcing them is exactly what mkinitcpio does.
read_effective_hooks() {
  local out
  out=$(
    set +u
    unset HOOKS
    # shellcheck disable=SC1091
    . /etc/mkinitcpio.conf 2>/dev/null || true
    for f in /etc/mkinitcpio.conf.d/*.conf; do
      [[ -e $f ]] || continue
      # shellcheck disable=SC1090
      . "$f" 2>/dev/null || true
    done
    printf '%s\n' "${HOOKS[*]}"
  )
  read -r -a HOOKS_NOW <<<"$out"
}

# Map busybox hooks to their systemd counterparts IN PLACE, so any hook this
# machine has that we don't know about keeps its position instead of being
# dropped by a hardcoded replacement list.
transform_hooks() {
  HOOKS_NEW=()
  local h mapped
  for h in "${HOOKS_NOW[@]}"; do
    case $h in
      udev)              mapped=systemd ;;
      encrypt)           mapped=sd-encrypt ;;
      keymap|consolefont|vconsole) mapped=sd-vconsole ;;
      btrfs-overlayfs)   mapped=sd-btrfs-overlayfs ;;
      resume)            continue ;;   # systemd-hibernate-resume is built in
      plymouth-encrypt)  mapped=sd-encrypt ;;
      *)                 mapped=$h ;;
    esac
    # keymap+consolefont both collapse to sd-vconsole; keep one.
    local seen k
    seen=0
    for k in "${HOOKS_NEW[@]}"; do [[ $k == "$mapped" ]] && { seen=1; break; }; done
    (( seen )) || HOOKS_NEW+=("$mapped")
  done
}

detect_rebuild_cmd() {
  if command -v limine-mkinitcpio >/dev/null; then
    REBUILD=(limine-mkinitcpio)
  elif command -v mkinitcpio >/dev/null; then
    REBUILD=(mkinitcpio -P)
  else
    REBUILD=()
  fi
}

discover() {
  detect_root_luks || true
  detect_cmdline_terms
  detect_cmdline_files
  read_effective_hooks
  transform_hooks
  detect_rebuild_cmd
}

# ---------------------------------------------------------------------------
# Compatibility
# ---------------------------------------------------------------------------

COMPAT=1

run_check() {
  COMPAT=1
  discover
  step "System"
  note "machine" "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_version 2>/dev/null)"
  note "kernel" "$(uname -r)"
  note "systemd" "$(systemctl --version | head -1 | awk '{print $2}')"

  step "Encrypted root"
  if [[ -n $LUKS_PART ]]; then
    ok "root is LUKS" "$ROOT_SRC -> $LUKS_PART"
    ok "  mapper name" "$DM_NAME"
    if [[ -n $LUKS_UUID ]]; then ok "  UUID" "$LUKS_UUID"
    else bad "  UUID" "could not read -- run as root"; fi
    # LUKS1 has no token support at all; enrolling would be impossible.
    if [[ $LUKS_VERSION == 2 ]]; then ok "  LUKS version" "2"
    elif [[ -z $LUKS_VERSION ]]; then note "  LUKS version" "unknown (run as root)"
    else bad "  LUKS version" "$LUKS_VERSION -- TPM2 tokens need LUKS2"; fi
  else
    bad "root is LUKS" "root is not on a LUKS device; nothing to do"
  fi

  step "TPM"
  if [[ -c /dev/tpmrm0 ]]; then ok "device" "/dev/tpmrm0"; else bad "device" "no /dev/tpmrm0"; fi
  # Enumerating the node is NOT proof it works: a firmware TPM wedged by a
  # suspend cycle still shows up but returns EIO to every command, which makes
  # enrollment fail with no obvious cause. Read a PCR to be sure.
  if cat /sys/class/tpm/tpm0/pcr-sha256/7 >/dev/null 2>&1; then
    ok "PCR 7 readable" "$(cut -c1-16 /sys/class/tpm/tpm0/pcr-sha256/7)…"
  else
    bad "PCR 7 readable" "TPM not responding -- reboot and retry"
  fi
  if systemctl --version | grep -q '+TPM2'; then ok "systemd TPM2 support"; else bad "systemd TPM2 support" "systemd built without +TPM2"; fi
  command -v systemd-cryptenroll >/dev/null && ok "systemd-cryptenroll" || bad "systemd-cryptenroll" "missing"
  [[ -d /sys/firmware/efi ]] && ok "UEFI boot" || bad "UEFI boot" "PCR 7 is meaningless without UEFI"
  if [[ $(bootctl status 2>/dev/null | grep -ci 'secure boot: enabled') -gt 0 ]]; then
    ok "Secure Boot" "enabled"
  else
    note "Secure Boot" "disabled -- PCR 7 binding is convenience, not security"
  fi

  step "Initramfs"
  if command -v mkinitcpio >/dev/null; then ok "mkinitcpio" ; else bad "mkinitcpio" "only mkinitcpio is supported"; fi
  note "current HOOKS" "${HOOKS_NOW[*]}"
  note "would become" "${HOOKS_NEW[*]}"
  local h missing=0
  for h in "${HOOKS_NEW[@]}"; do
    [[ -f /usr/lib/initcpio/install/$h ]] || { bad "  missing hook" "$h"; missing=1; }
  done
  (( missing )) || ok "all replacement hooks exist"
  if [[ ${#REBUILD[@]} -gt 0 ]]; then ok "rebuild command" "${REBUILD[*]}"; else bad "rebuild command" "none found"; fi

  step "Kernel command line"
  case $BOOT_STYLE in
    busybox)
      ok "current style" "busybox  ($CRYPT_OLD)"
      ok "would become" "$CRYPT_NEW"
      if [[ ${#CMDLINE_FILES[@]} -gt 0 ]]; then
        ok "files to edit" "${CMDLINE_FILES[*]}"
      else
        bad "files to edit" "no config file contains '$CRYPT_OLD'"
      fi
      ;;
    systemd)
      ok "current style" "systemd already ($CRYPT_OLD)"
      note "stage 1" "already done -- go straight to 'enroll'"
      ;;
    *) bad "current style" "no crypt term found on /proc/cmdline" ;;
  esac

  step "Rescue recipe for THIS machine"
  print_rescue

  echo
  if (( COMPAT )); then
    printf '\033[1;32mCompatible.\033[0m Next: sudo bash %s %s\n' "${BASH_SOURCE[0]##*/}" \
      "$([[ $BOOT_STYLE == systemd ]] && echo enroll || echo convert)"
  else
    printf '\033[1;31mNot compatible.\033[0m See the ✘ lines above.\n'
    return 1
  fi
}

# Generated from live mounts, so it always names the real subvolumes and
# partitions. Mounting only the root subvolume can leave /home empty.
print_rescue() {
  echo "      cryptsetup open $LUKS_PART $DM_NAME"
  local tgt src opts sub
  while read -r tgt src opts; do
    sub=$(sed -n 's/.*subvol=\([^,]*\).*/\1/p' <<<"$opts")
    [[ -n $sub ]] || continue
    if [[ $tgt == "/" ]]; then
      echo "      mount -o subvol=$sub $MAPPER /mnt"
    else
      echo "      mount -o subvol=$sub $MAPPER /mnt$tgt"
    fi
  done < <(findmnt -rn -o TARGET,SOURCE,OPTIONS -t btrfs 2>/dev/null | sort)
  local esp
  esp=$(findmnt -n -o SOURCE /boot 2>/dev/null || true)
  [[ -n $esp ]] && echo "      mount $esp /mnt/boot"
  echo "      arch-chroot /mnt bash $BACKUP/$(basename "${BASH_SOURCE[0]}") revert"
}

require_root() { (( EUID == 0 )) || die "Run with sudo: sudo bash $0 $*"; }

# ---------------------------------------------------------------------------

case "${1:-check}" in

check)
  run_check
  ;;

convert)
  require_root "$@"
  discover
  [[ $BOOT_STYLE != systemd ]] || { echo "Already converted ($CRYPT_OLD). Run 'enroll'."; exit 0; }
  run_check >/dev/null || { run_check; die "refusing to convert"; }

  step "Backing up everything this stage touches -> $BACKUP"
  mkdir -p "$BACKUP/cmdline"
  : > "$MANIFEST"
  local_i=0
  for f in "${CMDLINE_FILES[@]}"; do
    cp -a "$f" "$BACKUP/cmdline/$local_i"
    printf '%s\t%s\n' "$local_i" "$f" >> "$MANIFEST"
    echo "  saved $f -> cmdline/$local_i"
    local_i=$((local_i + 1))
  done
  cp -a /etc/mkinitcpio.conf.d "$BACKUP/mkinitcpio.conf.d"
  # Guard this: whoever holds it plus your passphrase can decrypt the disk.
  cryptsetup luksHeaderBackup "$LUKS_PART" --header-backup-file "$BACKUP/luks-header.img"
  chmod 600 "$BACKUP/luks-header.img"
  # This script may live on a separate /home subvolume that a minimal rescue
  # chroot would not mount. Keep a copy beside the backups, under /root.
  cp -a "${BASH_SOURCE[0]}" "$BACKUP/"
  printf '%s\n' "$CRYPT_OLD" > "$BACKUP/crypt-term-old"
  ls -la "$BACKUP"
  warn "Copy $BACKUP/luks-header.img to offline media."

  step "Writing $HOOKS_DROPIN"
  # A late-sorting drop-in rather than editing the distribution's own file,
  # which a package update would overwrite. Only HOOKS is set: anything else
  # earlier drop-ins established (MODULES, FILES) is left alone.
  {
    echo "# Systemd initramfs, required for TPM2-backed LUKS unlock."
    echo "# Generated by tpm2-unlock.sh on $(date -Is). Delete to revert."
    echo "# was: ${HOOKS_NOW[*]}"
    echo "HOOKS=(${HOOKS_NEW[*]})"
  } > "$HOOKS_DROPIN"
  cat "$HOOKS_DROPIN"

  step "Rewriting the kernel command line"
  echo "  from: $CRYPT_OLD"
  echo "  to:   $CRYPT_NEW"
  for f in "${CMDLINE_FILES[@]}"; do
    sed -i "s|$(sed 's/[]\/$*.^[]/\\&/g' <<<"$CRYPT_OLD")|$CRYPT_NEW|g" "$f"
    grep -qF "$CRYPT_NEW" "$f" || die "substitution failed in $f -- run 'revert'"
    echo "  updated $f"
  done

  step "Rebuilding initramfs and boot images"
  "${REBUILD[@]}"

  step "Verifying the new image contains the systemd unlock path"
  found=0
  for img in /boot/EFI/Linux/*.efi /boot/initramfs-*.img; do
    [[ -f $img ]] || continue
    if lsinitcpio -l "$img" 2>/dev/null | grep -q 'systemd-cryptsetup'; then
      echo "  systemd-cryptsetup present in $img"; found=1; break
    fi
  done
  (( found )) || warn "Could not confirm systemd-cryptsetup in any image; check before rebooting."

  cat <<'NEXT'

STAGE 1 DONE.

Reboot. You should get your NORMAL passphrase prompt -- the TPM is not involved
yet. That prompt is the proof that sd-encrypt works.

  * If it boots: run this script with 'enroll'.
  * If it does not: boot a live USB and use the rescue recipe from 'check'.
NEXT
  ;;

enroll)
  require_root "$@"
  discover
  # Without this guard the enrollment would silently do nothing: a busybox
  # initramfs never looks for LUKS2 tokens.
  [[ $BOOT_STYLE == systemd ]] || die "This system did not boot with rd.luks.* -- run 'convert' and reboot first."
  cat /sys/class/tpm/tpm0/pcr-sha256/7 >/dev/null 2>&1 || die "TPM is not responding (PCR 7 unreadable). Reboot and retry."
  echo "ok: booted via sd-encrypt, TPM responding"

  step "LUKS keyslots and tokens (before)"
  cryptsetup luksDump "$LUKS_PART" | grep -E '^\s*[0-9]+: |^Tokens:|tpm2|luks2-keyslot' || true

  step "Enrolling the TPM2"
  # PCR 7 measures Secure Boot policy: stable across kernel updates. PCR 11
  # measures the UKI itself and would force a re-enroll after every kernel
  # update. --wipe-slot=tpm2 clears only a previous TPM slot, never a passphrase.
  systemd-cryptenroll "$LUKS_PART" --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7

  step "LUKS keyslots and tokens (after)"
  cryptsetup luksDump "$LUKS_PART" | grep -E '^\s*[0-9]+: |^Tokens:|tpm2|luks2-keyslot' || true

  step "Rebuilding boot images"
  "${REBUILD[@]}"

  cat <<'NEXT'

STAGE 2 DONE. Reboot -- it should go straight through with no prompt.

Your passphrase still works; press Esc at the splash to type it.

A firmware or BIOS change alters PCR 7 and the TPM will refuse. That is not a
lockout: type the passphrase, boot, and run 'enroll' again.
NEXT
  ;;

revert)
  require_root "$@"
  discover

  step "Checking the backups this revert depends on"
  # Verified BEFORE anything changes. Without this guard a missing backup is
  # SILENT: the restore is skipped, execution continues, and the rebuild below
  # then writes a boot image pairing busybox hooks with a systemd command line.
  # That machine does not boot, and nothing in the output said why.
  blocked=0
  declare -a restore_from restore_to
  if [[ -f $MANIFEST ]]; then
    while IFS=$'\t' read -r idx path; do
      if [[ -f $BACKUP/cmdline/$idx ]]; then
        restore_from+=("$BACKUP/cmdline/$idx"); restore_to+=("$path")
        echo "  ok  $path"
      else
        warn "missing backup for $path"; blocked=1
      fi
    done < "$MANIFEST"
  else
    # Backups written by the machine-specific first version of this script.
    legacy=0
    for pair in "default-limine:/etc/default/limine" "kernel-cmdline:/etc/kernel/cmdline"; do
      if [[ -f $BACKUP/${pair%%:*} ]]; then
        restore_from+=("$BACKUP/${pair%%:*}"); restore_to+=("${pair##*:}")
        echo "  ok  ${pair##*:} (legacy backup)"; legacy=1
      fi
    done
    (( legacy )) || { warn "no manifest and no legacy backups in $BACKUP"; blocked=1; }
  fi

  for f in "${restore_from[@]}"; do
    grep -q 'cryptdevice=' "$f" || { warn "no cryptdevice= line in $f"; blocked=1; }
  done

  if (( blocked )); then
    cat >&2 <<MANUAL

Refusing to revert: the original command line cannot be restored from backup.
Removing the hooks drop-in without it would pair a busybox initramfs with a
systemd command line and break booting at the next kernel update.

Do it by hand. In every bootloader config that contains it, replace
  $CRYPT_OLD
with the original cryptdevice=... term$( [[ -f $BACKUP/crypt-term-old ]] && echo ", which was:
  $(cat "$BACKUP/crypt-term-old")" ), then:

  rm -f $HOOKS_DROPIN
  ${REBUILD[*]}

MANUAL
    exit 1
  fi

  step "Removing the TPM2 keyslot (passphrase keyslot untouched)"
  systemd-cryptenroll "$LUKS_PART" --wipe-slot=tpm2 2>/dev/null || echo "(no tpm2 slot to wipe)"

  step "Restoring hooks and command line"
  rm -fv "$HOOKS_DROPIN"
  for i in "${!restore_from[@]}"; do
    cp -av "${restore_from[$i]}" "${restore_to[$i]}"
  done

  step "Confirming the command line is back to the busybox form"
  # Before the rebuild on purpose: if this fails, set -e stops here and the
  # existing working boot image is left alone rather than replaced.
  grep -H 'cryptdevice=' "${restore_to[@]}"

  step "Rebuilding boot images"
  "${REBUILD[@]}"

  cat <<'DONE'

Reverted to passphrase-only busybox boot. Reboot to confirm -- you should be
asked for your passphrase again.

If you only wanted to stop the TPM unlocking the disk while KEEPING the systemd
initramfs, you did not need this: `systemd-cryptenroll <dev> --wipe-slot=tpm2`
alone does that, and changes nothing about how the machine boots.
DONE
  ;;

*)
  echo "Usage: sudo bash $0 <check|convert|enroll|revert>" >&2
  exit 2
  ;;
esac
