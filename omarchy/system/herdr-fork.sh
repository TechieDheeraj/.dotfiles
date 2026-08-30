#!/usr/bin/env bash
# Build and install herdr from your fork, replacing the distro-packaged build.
#
#   bash herdr-fork.sh --help       # full usage; usage() below is the source of truth
#
# The comments in this file explain WHY things are the way they are; --help
# explains HOW to drive it. Keep user-facing wording in usage(), not up here.
#
# Runs on Linux (Arch/Omarchy) and macOS. Everything platform-specific is behind
# the shim block below -- adding a third platform means filling in one more case
# arm, not touching the logic.
#
# Environment overrides, all optional:
#   HERDR_REPO         fork to build from
#   HERDR_BRANCH       branch to track
#   HERDR_INSTALL_DIR  where the binary lands (default: see pick_install_dir)
#   HERDR_MACOS_SDK    macOS SDK to build against (default: see resolve_zig)
#
# BUILD ARTIFACTS ARE DELETED AFTER A SUCCESSFUL INSTALL. They are enormous --
# 765 MB of the 819 MB tree, mostly vendor/libghostty-vt/.zig-cache at 413 MB --
# and worthless once the binary is in /usr/local/bin. The source and .git stay
# (~54 MB) so the next run is still just a fetch. Cost: the next rebuild is a
# full one (~2.5 min) rather than incremental. Use --keep-build if you are
# iterating and want that back.
#
# Idempotent. First run clones and builds; later runs fetch, and only rebuild
# when the branch actually moved. Safe to run whenever you want to be current.
#
# READ-ONLY AGAINST THE REMOTE. It only ever fetches. There is no `git push`, no
# commit, no tag, no remote write of any kind -- do your development on GitHub or
# elsewhere and this just consumes whatever is on the branch.
#
# WHY NOT JUST UNINSTALL THE PACKAGE AND DROP A BINARY IN:
# that is what this does, but the ordering matters. On Arch /usr/local/bin
# precedes /usr/bin, so the fork wins even if the package comes back, and
# removing the package is safe: `pacman -Qi herdr` reports "Required By: None"
# and it is only an *optional* dep of omarchy-settings, so omarchy-update will
# not pull it back. On macOS there is no single dir you can count on winning --
# see pick_install_dir, which measures PATH instead of assuming.

set -euo pipefail

REPO=${HERDR_REPO:-https://github.com/TechieDheeraj/herdr}
BRANCH=${HERDR_BRANCH:-feat_health_check}
SRC="$HOME/.local/src/herdr-fork"
BIN="$SRC/target/release/herdr"
# Deliberately OUTSIDE target/: the cleanup below deletes target/, and a stamp
# living in there would vanish with it, making every run look like a rebuild.
STAMP="$SRC/.installed-from"
# Everything cargo and zig generate. build.rs drives the zig build, which is why
# the zig cache lives under vendor/ rather than target/.
ARTIFACTS=("$SRC/target" "$SRC/vendor/libghostty-vt/.zig-cache" "$SRC/vendor/libghostty-vt/zig-out")

MODE=${1:-install}
FORCE=0
KEEP=0
ALLOW_RUNNING=0
HANDOFF=0
HELP=0
[[ $MODE == --help || $MODE == -h ]] && { HELP=1; MODE=install; }
[[ $MODE == --force ]]         && { FORCE=1; MODE=install; }
[[ $MODE == --keep-build ]]    && { KEEP=1;  MODE=install; }
# Implies --allow-running: handing off is only meaningful when a server is up,
# so refusing to install under live sessions would make the flag unusable.
[[ $MODE == --handoff ]]       && { HANDOFF=1; ALLOW_RUNNING=1; MODE=install; }
# Separate from --force on purpose: "install over live sessions" and "rebuild
# even though nothing changed" are unrelated concerns, and folding them into one
# flag means paying a full rebuild just to get past the guard.
[[ $MODE == --allow-running ]] && { ALLOW_RUNNING=1; MODE=install; }

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %-22s %s\n' "$1" "${2-}"; }
die()  { printf '\033[1;31mxx  %s\033[0m\n' "$*" >&2; exit 1; }

# Called after the platform shim has resolved DEST, so the paths shown are the
# ones this machine will actually use rather than a generic guess.
usage() {
  cat <<EOF
herdr-fork.sh -- build and install herdr from your fork, replacing the
distro-packaged build. Runs on Linux (Arch/Omarchy) and macOS.

USAGE
  bash herdr-fork.sh [command | flag]

  Takes at most one argument. Anything unrecognised is an error rather than a
  silent fall-through to a full install.

COMMANDS
  (none)             update, build if the branch moved, install, verify, clean up
  status             report only -- no clone, no build, no root, no writes
  build              update + build, then stop before installing (keeps artifacts)
  --help, -h         this text

FLAGS  (each runs the default install flow, with one behaviour changed)
  --force            rebuild and reinstall even when nothing changed
  --keep-build       install but KEEP build artifacts, for fast iteration
  --allow-running    install while herdr sessions are live. They keep running
                     the OLD binary until you restart them yourself
  --handoff          install, then live-handoff the running server onto the new
                     binary WITHOUT losing panes. Implies --allow-running, and
                     still hands off when the binary is already up to date

ENVIRONMENT
  HERDR_REPO         fork to build from
                       now: $REPO
  HERDR_BRANCH       branch to track
                       now: $BRANCH
  HERDR_INSTALL_DIR  where the binary lands. Default is whichever of
                     /usr/local/bin, ~/.local/bin or the Homebrew prefix your
                     PATH prefers, so the fork always wins
                       now: $DEST
  HERDR_MACOS_SDK    macOS SDK to build against. Default probes for one the
                     pinned zig can actually link (macOS only)

PATHS
  source             $SRC
  install target     $DEST

NOTES
  Build artifacts are deleted after a successful install -- they are far larger
  than the source and worthless once the binary is in place. Use --keep-build
  while iterating. The source and .git stay, so the next run is just a fetch.

  Handoff is SERVER-only. Clients and \`--remote\` wrappers keep executing their
  original binary and go on drawing the old UI until restarted; the script lists
  any it finds so a stale layout is not mistaken for a failed install.

  Never run \`herdr update\` on a machine tracking this fork. It downloads the
  official release and overwrites the fork build.

  This script only ever FETCHES from the remote -- no push, commit or tag.
EOF
}

# --- install location -------------------------------------------------------
# 1-based position of a directory in PATH, or 9999 if it is not on PATH at all.
path_rank() {
  local target=$1 i=0 dir
  while IFS= read -r dir; do
    i=$((i + 1))
    [[ $dir == "$target" ]] && { echo "$i"; return; }
  done <<< "${PATH//:/$'\n'}"
  echo 9999
}

# Given candidate dirs, return whichever PATH actually prefers. The whole point
# of this script is that the fork shadows every other herdr, and on macOS no
# fixed directory guarantees that: Homebrew on Apple Silicon puts
# /opt/homebrew/bin ahead of /usr/local/bin, and a ~/.local/bin ahead of both is
# common. Guessing wrong installs a binary that something else quietly shadows,
# which looks exactly like "the build did not pick up my commit". Measuring is
# cheap and cannot be wrong. Falls back to the first candidate when none of them
# are on PATH (the verify step warns in that case).
pick_install_dir() {
  local best=$1 best_rank c r
  best_rank=$(path_rank "$1")
  shift
  for c in "$@"; do
    r=$(path_rank "$c")
    (( r < best_rank )) && { best=$c; best_rank=$r; }
  done
  printf '%s\n' "$best"
}

# --- platform shim ----------------------------------------------------------
# The only place either OS is named. What differs: how you hash a file, how you
# query and remove the packaged herdr, where the binary goes, and what to tell
# someone missing a toolchain. Everything below this block is OS-agnostic.
OS=$(uname -s)
case $OS in
  Darwin)
    # BSD ships shasum; sha256sum is GNU coreutils and is not present.
    sha256_of()     { shasum -a 256 "$1"; }
    # No /proc on macOS; lsof's "txt" row is the running executable image.
    file_inode()     { stat -f %i "$1" 2>/dev/null; }
    proc_exe_inode() { lsof -p "$1" 2>/dev/null | awk '$4=="txt" && $NF ~ /herdr$/ {print $(NF-1); exit}'; }
    pkg_installed() { command -v brew >/dev/null 2>&1 && brew list --formula herdr >/dev/null 2>&1; }
    pkg_remove()    { brew uninstall herdr; }
    pkg_label()     { echo "brew herdr"; }
    pkg_status()    { brew list --versions herdr 2>/dev/null || echo 'absent (correct)'; }
    mise_hint="brew install mise"
    # Three places a herdr can plausibly live on a Mac; PATH order decides which
    # one we use. Listed with the most conservative first, which is also the
    # fallback if none of them are on PATH.
    DARWIN_CANDIDATES=(/usr/local/bin "$HOME/.local/bin")
    command -v brew >/dev/null 2>&1 && DARWIN_CANDIDATES+=("$(brew --prefix)/bin")
    INSTALL_DIR=$(pick_install_dir "${DARWIN_CANDIDATES[@]}")
    ;;
  Linux)
    sha256_of()     { sha256sum "$1"; }
    # -L: /proc/PID/exe is a symlink to the image, which still resolves after
    # the on-disk file has been replaced.
    file_inode()     { stat -c %i "$1" 2>/dev/null; }
    proc_exe_inode() { stat -Lc %i "/proc/$1/exe" 2>/dev/null; }
    # Guarded on pacman existing so this degrades to a no-op on a non-Arch Linux
    # instead of erroring out of a `set -e` script.
    pkg_installed() { command -v pacman >/dev/null 2>&1 && pacman -Qq herdr >/dev/null 2>&1; }
    pkg_remove()    { sudo pacman -R --noconfirm herdr; }
    pkg_label()     { echo "pacman herdr"; }
    pkg_status()    { pacman -Q herdr 2>/dev/null || echo 'removed (correct)'; }
    mise_hint="curl https://mise.run | sh"
    # Pinned rather than ranked: on Arch /usr/local/bin already beats /usr/bin,
    # the reasoning in the header depends on that specific directory, and this
    # path is the one that has actually been exercised. Set HERDR_INSTALL_DIR if
    # your PATH puts something ahead of it.
    INSTALL_DIR=/usr/local/bin
    ;;
  *) die "unsupported platform: $OS (expected Linux or Darwin)" ;;
esac
DEST="${HERDR_INSTALL_DIR:-$INSTALL_DIR}/herdr"

# /usr/local/bin is root-owned on stock macOS and on Arch, but a Homebrew prefix
# is owned by you -- in which case sudo is pure friction, and worse, it prompts
# for a password it does not need.
SUDO=sudo
[[ -w ${DEST%/*} || ${EUID:-$(id -u)} -eq 0 ]] && SUDO=

# Deferred to here so --help can print the paths this machine resolved.
(( HELP )) && { usage; exit 0; }

# Without this, a typo ("--foce", "--hand-off") fell through as an unrecognised
# MODE and silently ran a full install -- the most destructive default possible
# for a mistyped flag.
case $MODE in
  install|status|build) ;;
  *) printf '\033[1;31mxx  unknown argument: %s\033[0m\n\n' "$MODE" >&2
     usage >&2
     exit 2 ;;
esac

# --- toolchains -------------------------------------------------------------
# Read from the tree rather than hardcoded, so a rebase that bumps either one
# does not silently build with the wrong compiler. The vendored libghostty-vt is
# Zig, compiled by build.rs shelling out to `zig`; without it the cargo build
# panics inside build.rs instead of saying what it wanted. Distro zig is usually
# too new for that vendored code, hence mise for both.
read_toolchains() {
  RUST=$(sed -nE 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
         "$SRC/rust-toolchain.toml" 2>/dev/null | head -1)
  # Named ZIG_VERSION, not ZIG: build.rs reads a ZIG env var meaning the zig
  # EXECUTABLE. Two different things, and colliding on the name is a trap.
  ZIG_VERSION=$(sed -nE 's/.*minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
        "$SRC/vendor/libghostty-vt/build.zig.zon" 2>/dev/null | head -1)
  [[ -n ${RUST:-} ]] || die "could not read rust channel from rust-toolchain.toml"
  [[ -n ${ZIG_VERSION:-} ]] || die "could not read minimum_zig_version from build.zig.zon"
}

# --- zig vs the macOS SDK ---------------------------------------------------
# Zig 0.15.x cannot link against the macOS 26 (Tahoe) SDK on Apple Silicon. The
# first document in that SDK's libSystem.B.tbd carries
#   targets: [x86_64-macos, x86_64-maccatalyst, arm64e-macos, arm64e-maccatalyst]
# with no plain arm64-macos slice, so an arm64 link resolves nothing and reports
# EVERY libc symbol as undefined (_malloc, _abort, _fork, ...). It surfaces as
# build.rs panicking with "zig build for vendored libghostty-vt failed".
#
# Bumping zig is NOT the fix, despite the field being called
# minimum_zig_version: build.zig calls requireZig() which rejects anything
# newer ("Your Zig version v0.16.0 does not meet the required build version of
# v0.15.2"), and 0.16 changed Dir.readFileAlloc's signature so the vendored
# build.zig no longer compiles there either. It is an exact pin in practice.
#
# The fix is to keep the pinned zig and hand it an older SDK that still ships
# the arm64-macos slice -- CLT installs several side by side. Getting zig to USE
# one is the fiddly part; three plausible levers do not work:
#
#   SDKROOT      ignored. zig asks `xcrun --sdk macosx --show-sdk-path`, and
#                that form of xcrun does not honour SDKROOT.
#   --sysroot    applies to the build's own compilations, NOT to the build
#                runner zig links first, which is exactly what fails here. And
#                build.rs execs zig with a fixed argv anyway (build.rs:63).
#   ZIG_LIBC     changes include/crt paths, not the -syslibroot used for linking.
#
# What does work is intercepting the question rather than the answer: put an
# `xcrun` earlier in PATH that reports the older SDK. zig then resolves that SDK
# for everything it links, build runner included.
#
# NOTE this prefix is in effect for the whole cargo build, so the Rust link
# steps see the older SDK too. That is the intended blast radius -- a binary
# built against the 15.x SDK runs fine on 26 -- but it is why the shim is scoped
# to the one build command and not exported globally.
#
# All Darwin-only and self-disarming: when a future zig or SDK links cleanly,
# the first probe passes and nothing below it runs.
SHIM_DIR="$(dirname "$SRC")/.herdr-sdk-shim"
SHIM_PATH=""   # PATH prefix ("dir:") while a shim is in use, else empty

# Lives outside $SRC deliberately: inside, it would show up as an untracked file
# and trip the dirty-tree guard, and purge_artifacts would delete it.
make_xcrun_shim() {
  mkdir -p "$SHIM_DIR"
  {
    echo '#!/usr/bin/env bash'
    echo '# Generated by herdr-fork.sh -- see "zig vs the macOS SDK" there.'
    printf 'SDK=%q\n' "$1"
    echo 'for a in "$@"; do'
    echo '  case $a in'
    echo '    --show-sdk-path)    printf "%s\n" "$SDK"; exit 0 ;;'
    echo '    --show-sdk-version) basename "$SDK" | sed -E "s/^MacOSX(.*)\.sdk$/\1/"; exit 0 ;;'
    echo '  esac'
    echo 'done'
    echo 'exec /usr/bin/xcrun "$@"'
  } > "$SHIM_DIR/xcrun"
  chmod +x "$SHIM_DIR/xcrun"
  SHIM_PATH="$SHIM_DIR:"
}

# Can this zig link a trivial libc program? $2 optionally forces an SDK. The
# probe deliberately mirrors how the real build invokes zig -- an earlier
# version of this used --sysroot, passed, and the actual build still failed.
zig_links_libc() {
  local v=$1 sdk=${2-} tmp rc=0 prefix=""
  tmp=$(mktemp -d) || return 1
  printf 'const std = @import("std");\npub fn main() void { std.debug.print("", .{}); }\n' \
    > "$tmp/probe.zig"
  if [[ -n $sdk ]]; then make_xcrun_shim "$sdk"; prefix="$SHIM_DIR:"; fi
  ( cd "$tmp" && PATH="$prefix$PATH" mise x "zig@$v" -- \
      zig build-exe probe.zig -lc -femit-bin=probe ) >/dev/null 2>&1 || rc=1
  rm -rf "$tmp"
  return $rc
}

# Newest installed SDK the pinned zig can actually link against. Name-sorted
# descending so we give up as little SDK as possible; the probe, not the name,
# decides correctness.
find_working_sdk() {
  local d
  for d in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk \
                   "$(xcode-select -p 2>/dev/null)"/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk \
                   2>/dev/null | sort -r); do
    [[ -e $d/usr/lib/libSystem.B.tbd ]] || continue
    if zig_links_libc "$ZIG_VERSION" "$d"; then printf '%s\n' "$d"; return 0; fi
  done
  return 1
}

resolve_zig() {
  SHIM_PATH=""
  [[ $OS == Darwin ]] || return 0   # Linux links against glibc; none of this applies

  if [[ -n ${HERDR_MACOS_SDK:-} ]]; then
    make_xcrun_shim "$HERDR_MACOS_SDK"
    info "macos sdk" "$HERDR_MACOS_SDK (override)"
    return 0
  fi
  if zig_links_libc "$ZIG_VERSION"; then
    info "zig probe" "links libc against the default SDK"
    return 0
  fi
  info "zig probe" "cannot link libc against $(/usr/bin/xcrun --show-sdk-path 2>/dev/null || echo 'the default SDK')"

  local sdk
  sdk=$(find_working_sdk) ||
    die "zig $ZIG_VERSION cannot link against any installed macOS SDK.
    Install an older one (Xcode CLT 15.x ships MacOSX15.sdk) or set
    HERDR_MACOS_SDK to a usable SDK."
  make_xcrun_shim "$sdk"
  info "macos sdk" "$sdk  (default SDK lacks an arm64-macos slice)"
}

# Checked before the build rather than during it: cargo's failure mode for a
# missing linker on macOS is a wall of ld errors that never mentions Xcode.
check_prereqs() {
  command -v git  >/dev/null 2>&1 || die "git not found"
  command -v mise >/dev/null 2>&1 || die "mise not found -- install it with: $mise_hint"
  if [[ $OS == Darwin ]] && ! xcode-select -p >/dev/null 2>&1; then
    die "Xcode command line tools not installed -- run: xcode-select --install"
  fi
}

# --- source -----------------------------------------------------------------
ensure_src() {
  # Do this FIRST: our stamp lives in the work tree, so without the exclude it
  # shows up as an untracked file and trips the dirty-tree guard further down.
  # .git/info/exclude is local-only -- never committed, never reaches the fork.
  local excl="$SRC/.git/info/exclude"
  if [[ -f $excl ]] && ! grep -qx '/.installed-from' "$excl" 2>/dev/null; then
    printf '/.installed-from\n' >> "$excl"
  fi

  if [[ -d $SRC/.git ]]; then
    # depth 50 rather than 1: enough history to show what actually changed, and
    # to cope when the branch history has been rewritten upstream (a rebase).
    git -C "$SRC" fetch --depth 50 origin "$BRANCH" --quiet
    local old new
    old=$(git -C "$SRC" rev-parse HEAD)
    new=$(git -C "$SRC" rev-parse "origin/$BRANCH")
    if [[ $old == "$new" ]]; then
      info "branch" "unchanged ($(git -C "$SRC" log --oneline -1))"
    elif git -C "$SRC" merge-base --is-ancestor "$old" "$new" 2>/dev/null; then
      echo "    new commits:"
      git -C "$SRC" log --oneline "$old..$new" | sed 's/^/      /'
    else
      # History was rewritten upstream (you rebased the branch). The old tip is
      # no longer an ancestor, so "$old..$new" would list nothing useful. Show
      # the new top of the branch instead.
      info "branch" "history rewritten upstream (rebase)"
      git -C "$SRC" log --oneline -5 "$new" | sed 's/^/      /'
    fi
    # This is a BUILD tree, not a working copy: checkout -B resets the local
    # branch to whatever origin has. Refuse if you have edits here, so a stray
    # experiment is never silently discarded.
    if [[ -n $(git -C "$SRC" status --porcelain 2>/dev/null) ]]; then
      git -C "$SRC" status --short | sed 's/^/      /'
      die "local changes in $SRC -- commit, stash or discard them first"
    fi
    git -C "$SRC" checkout -B "$BRANCH" "origin/$BRANCH" --quiet
  else
    mkdir -p "$(dirname "$SRC")"
    git clone --depth 50 --branch "$BRANCH" "$REPO" "$SRC" --quiet
    info "cloned" "$(git -C "$SRC" log --oneline -1)"
  fi
  HEAD_SHA=$(git -C "$SRC" rev-parse HEAD)
}

installed_sha() { [[ -x $DEST ]] && sha256_of "$DEST" | cut -c1-16 || echo "-"; }
built_sha()     { [[ -x $BIN  ]] && sha256_of "$BIN"  | cut -c1-16 || echo "-"; }

# Purge everything cargo and zig generate. Called only after a verified install,
# and also on the "already current" path so a tree left dirty by an earlier run
# (or a manual build) still gets cleaned. Needs no root -- all under $HOME.
purge_artifacts() {
  local a before found=0
  for a in "${ARTIFACTS[@]}"; do [[ -e $a ]] && found=1; done
  (( found )) || { info "artifacts" "already clean"; return 0; }
  before=$(du -sh "$SRC" 2>/dev/null | cut -f1)
  for a in "${ARTIFACTS[@]}"; do
    [[ -e $a ]] || continue
    info "removing" "${a#$SRC/}  ($(du -sh "$a" 2>/dev/null | cut -f1))"
    rm -rf "$a"
  done
  info "tree size" "$before -> $(du -sh "$SRC" 2>/dev/null | cut -f1)  (source + .git kept)"
}

# BSD pgrep has no -a, so build the listing out of ps, which takes the same
# -o pid=,command= on both platforms.
running_herdr() {
  pgrep -x herdr 2>/dev/null | while read -r p; do ps -p "$p" -o pid=,command=; done
}

# --- live handoff -----------------------------------------------------------
# The server can re-exec a replacement binary in place and carry the panes
# across, which is what `herdr update --handoff` does internally -- minus the
# download, which would replace this fork with an official release and is the
# reason `herdr update` must never be run on a machine tracking the fork.
#
# `herdr server live-handoff` is not in `herdr --help`, but it is a first-class
# command (src/cli/server.rs). It deliberately skips the CLI's protocol
# compatibility guard, because a handoff is itself the recovery path for a
# protocol mismatch -- which is exactly the situation here, where the running
# server is older than the binary we just installed.
#
# HANDOFF IS SERVER-ONLY. Clients and `--remote` wrappers keep executing their
# original inode and go on drawing the OLD UI until they are restarted. That
# looks indistinguishable from a failed install, so stale_pids names them.

# PIDs whose running image is not the binary we just installed.
stale_pids() {
  local want p ino
  want=$(file_inode "$DEST") || return 0
  [[ -n $want ]] || return 0
  for p in $(pgrep -x herdr 2>/dev/null); do
    ino=$(proc_exe_inode "$p") || continue
    [[ -n $ino && $ino != "$want" ]] && printf '%s\n' "$p"
  done
  return 0
}

live_handoff() {
  if ! pgrep -x herdr >/dev/null 2>&1; then
    info "handoff" "no herdr running -- nothing to hand off"
    return 0
  fi
  # Ask the NEW binary what protocol it speaks, so the server can verify the
  # replacement actually came up as expected instead of trusting the swap.
  local proto args=(--import-exe "$DEST") out
  proto=$("$DEST" api schema --json 2>/dev/null |
          sed -nE 's/.*"protocol"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -1)
  if [[ -n $proto ]]; then
    args+=(--expected-protocol "$proto")
    info "expecting protocol" "$proto"
  else
    info "warning" "could not read protocol from the new binary -- handing off unverified"
  fi

  if out=$("$DEST" server live-handoff "${args[@]}" 2>&1); then
    printf '    %s\n' "$out"
    info "server now" "$("$DEST" status server 2>&1 | sed -n 's/^version: //p')"
  else
    printf '    %s\n' "$out"
    # Not fatal: a refused handoff leaves the OLD server running with your
    # panes intact, which is the safe outcome. The new binary is installed
    # either way, so a plain restart still picks it up.
    info "handoff" "FAILED -- old server kept running, panes intact"
    info "" "restart herdr when convenient to pick up the new binary"
    return 0
  fi

  local stale
  stale=$(stale_pids)
  if [[ -n $stale ]]; then
    info "still on old binary" "these did not hand off and need a restart:"
    echo "$stale" | while read -r p; do ps -p "$p" -o pid=,command= | sed 's/^/      /'; done
  fi
}

# --- status -----------------------------------------------------------------
if [[ $MODE == status ]]; then
  step "herdr fork status"
  info "platform" "$OS ($(uname -m))"
  info "repo" "$REPO"
  info "branch" "$BRANCH"
  if [[ -d $SRC/.git ]]; then
    git -C "$SRC" fetch --depth 50 origin "$BRANCH" --quiet 2>/dev/null || true
    info "local HEAD" "$(git -C "$SRC" rev-parse --short HEAD) $(git -C "$SRC" log --format=%s -1)"
    info "remote HEAD" "$(git -C "$SRC" rev-parse --short "origin/$BRANCH" 2>/dev/null || echo '?')"
    info "installed from" "$(cut -c1-7 "$STAMP" 2>/dev/null || echo 'never')"
    info "artifacts" "$([[ -d $SRC/target ]] && echo "present ($(du -sh "$SRC" 2>/dev/null | cut -f1))" || echo "cleaned ($(du -sh "$SRC" 2>/dev/null | cut -f1))")"
  else
    info "source" "not cloned yet"
  fi
  info "built binary" "$([[ -x $BIN ]] && "$BIN" --version 2>&1 | head -1 || echo none) [$(built_sha)]"
  info "install path" "$DEST"
  info "installed" "$([[ -x $DEST ]] && "$DEST" --version 2>&1 | head -1 || echo none) [$(installed_sha)]"
  info "$(pkg_label)" "$(pkg_status)"
  info "PATH resolves to" "$(command -v herdr || echo 'NOT FOUND')"
  exit 0
fi

# --- update + build ---------------------------------------------------------
step "Fetching $REPO ($BRANCH)"
info "platform" "$OS ($(uname -m))"
check_prereqs
ensure_src
read_toolchains
info "rust (from tree)" "$RUST"
info "zig (from tree)" "$ZIG_VERSION"

# Nothing to do at all? Artifacts are deleted after install, so the question is
# not "is there a built binary" but "is the INSTALLED one from this commit".
if [[ $MODE == install ]] && (( ! FORCE )) &&
   [[ -x $DEST && $(cat "$STAMP" 2>/dev/null) == "$HEAD_SHA" ]]; then
  step "Already current"
  info "installed" "$("$DEST" --version 2>&1 | head -1)"
  info "from commit" "$(echo "$HEAD_SHA" | cut -c1-7)"
  # "Already current" is about the binary ON DISK, which says nothing about what
  # the RUNNING processes are executing -- install without handoff leaves the
  # server on its old inode. So --handoff still has work to do here, and this is
  # in fact its most common use: hand off after an earlier plain install.
  if (( HANDOFF )); then
    step "Handing off live sessions to the new binary"
    live_handoff
  fi
  (( KEEP )) || purge_artifacts
  exit 0
fi

need_build=0
if (( FORCE )); then
  need_build=1; info "rebuild" "forced"
elif [[ ! -x $BIN ]]; then
  need_build=1; info "rebuild" "no build artifacts (cleaned after last install)"
else
  info "rebuild" "reusing existing artifacts"
fi

if (( need_build )); then
  step "Toolchains (mise, user-level -- no root, no system package manager)"
  # Deliberately down here rather than next to read_toolchains: probing costs a
  # zig install, and a run that turns out to have nothing to build should not
  # pay for it.
  mise install "rust@$RUST" "zig@$ZIG_VERSION"
  resolve_zig

  step "Building (release)"
  # SHIM_PATH is "<dir>:" when resolve_zig had to force an older SDK, empty
  # otherwise. Scoped to this one command rather than exported, so nothing else
  # in the session inherits a doctored xcrun.
  ( cd "$SRC" && PATH="$SHIM_PATH$PATH" \
      mise x "rust@$RUST" "zig@$ZIG_VERSION" -- cargo build --release )
  # NOT stamped here. $STAMP means "the installed binary came from this commit",
  # and a successful build has installed nothing. Stamping it here made `build`
  # mode poison the next `install`: DEST exists (the OLD binary) and the stamp
  # already matches HEAD, so the "Already current" check short-circuits, purges
  # the artifacts and exits, leaving the old binary in place while reporting
  # success. The only write is after the install below.
  info "built" "$("$BIN" --version 2>&1 | head -1)"
fi

# Validate the config against the NEW binary before it replaces a working one.
step "Validating your config against the new build"
# Captured into a variable rather than `... | tee /dev/stderr | grep`: when this
# script's stdout and stderr are the same FILE (bash herdr-fork.sh > log 2>&1),
# tee opens /dev/stderr with O_TRUNC and rewinds to offset 0, destroying every
# line written before it. Silent, and only visible when you redirect to a file.
config_out=$("$BIN" config check 2>&1) || true
printf '    %s\n' "$config_out"
grep -qi '^config: ok' <<<"$config_out" ||
  die "config check failed against the new build -- not installing"

[[ $MODE == build ]] && { echo; echo "Built only. Re-run without 'build' to install."; exit 0; }

# --- install ----------------------------------------------------------------
# Swapping the binary under a live session leaves that process on the old inode
# and can confuse a later reattach. Refuse rather than surprise you.
if pgrep -x herdr >/dev/null 2>&1; then
  echo
  running_herdr | sed 's/^/    /'
  # --force has to actually bypass this, not just be mentioned in the error:
  # the common case is running this script FROM a herdr session, where an
  # absolute guard means you could never update at all.
  if (( FORCE || ALLOW_RUNNING )); then
    (( HANDOFF )) || {
      info "warning" "installing under live sessions"
      info "" "they stay on the old inode until restarted"
      info "" "re-run with --handoff to move the server across without losing panes"
    }
  else
    die "herdr is running -- close those sessions first, re-run with --handoff to
    keep your panes, or --allow-running to install and restart manually"
  fi
fi

step "Installing to $DEST"
if pkg_installed; then
  echo "    removing the packaged herdr (it shadows nothing, but keep it tidy)"
  pkg_remove
else
  info "$(pkg_label)" "already absent"
fi
# Split out of a single `install -Dm755`: BSD install has no -D, and wants the
# mode as a separate argument.
$SUDO mkdir -p "${DEST%/*}"
$SUDO install -m 755 "$BIN" "$DEST"

# Stamped only after the binary is in place, so an aborted install never claims
# to be current.
printf '%s\n' "$HEAD_SHA" > "$STAMP"

step "Verifying"
hash -r 2>/dev/null || true
resolved=$(command -v herdr || echo 'NOT FOUND')
info "which herdr" "$resolved"
# Belt and braces against the PATH-ordering trap the INSTALL_DIR comment
# describes: if something still shadows what we just wrote, say so out loud
# rather than leave you wondering why --version disagrees with the commit.
[[ $resolved == "$DEST" ]] || info "warning" "PATH prefers $resolved over $DEST"
info "version" "$("$DEST" --version 2>&1 | head -1)"
info "config" "$("$DEST" config check 2>&1 | head -1)"

# After the install and verify, so a handoff never points a live server at a
# binary that failed its own config check.
if (( HANDOFF )); then
  step "Handing off live sessions to the new binary"
  live_handoff
fi

if (( KEEP )); then
  step "Keeping build artifacts (--keep-build)"
  info "size" "$(du -sh "$SRC" 2>/dev/null | cut -f1)"
else
  step "Removing build artifacts"
  # Only after the install and verification above succeeded -- set -e means a
  # failure anywhere earlier aborts before we destroy anything rebuildable.
  purge_artifacts
fi
echo
echo "    Config lives at ~/.config/herdr/config.toml (symlinked to this repo by install.sh)."
