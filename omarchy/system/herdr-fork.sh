#!/usr/bin/env bash
# Build and install herdr from your fork, replacing Omarchy's packaged build.
#
#   bash herdr-fork.sh              # do everything: update, build, install, clean up
#   bash herdr-fork.sh status       # report only -- no clone, no build, no root
#   bash herdr-fork.sh build        # update + build, stop before installing (keeps artifacts)
#   bash herdr-fork.sh --force      # rebuild and reinstall even if nothing changed
#   bash herdr-fork.sh --keep-build # install but KEEP artifacts, for fast iteration
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
# WHY NOT JUST `pacman -R herdr` AND DROP A BINARY IN:
# that is what this does, but the ordering matters. /usr/local/bin precedes
# /usr/bin in PATH here, so the fork wins even if the package comes back.
# Removing the package is safe: `pacman -Qi herdr` reports "Required By: None"
# and it is only an *optional* dep of omarchy-settings, so omarchy-update will
# not pull it back.

set -euo pipefail

REPO=https://github.com/TechieDheeraj/herdr
BRANCH=feat_health_check
SRC="$HOME/.local/src/herdr-fork"
DEST=/usr/local/bin/herdr
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
[[ $MODE == --force ]]      && { FORCE=1; MODE=install; }
[[ $MODE == --keep-build ]] && { KEEP=1;  MODE=install; }

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %-22s %s\n' "$1" "${2-}"; }
die()  { printf '\033[1;31mxx  %s\033[0m\n' "$*" >&2; exit 1; }

# --- toolchains -------------------------------------------------------------
# Read from the tree rather than hardcoded, so a rebase that bumps either one
# does not silently build with the wrong compiler. The vendored libghostty-vt is
# Zig, compiled by build.rs shelling out to `zig`; without it the cargo build
# panics inside build.rs instead of saying what it wanted. Arch ships a zig too
# new for that vendored code, hence mise for both.
read_toolchains() {
  RUST=$(sed -nE 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
         "$SRC/rust-toolchain.toml" 2>/dev/null | head -1)
  ZIG=$(sed -nE 's/.*minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
        "$SRC/vendor/libghostty-vt/build.zig.zon" 2>/dev/null | head -1)
  [[ -n ${RUST:-} ]] || die "could not read rust channel from rust-toolchain.toml"
  [[ -n ${ZIG:-}  ]] || die "could not read minimum_zig_version from build.zig.zon"
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

installed_sha() { [[ -x $DEST ]] && sha256sum "$DEST" | cut -c1-16 || echo "-"; }

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
built_sha()     { [[ -x $BIN  ]] && sha256sum "$BIN"  | cut -c1-16 || echo "-"; }

# --- status -----------------------------------------------------------------
if [[ $MODE == status ]]; then
  step "herdr fork status"
  info "repo" "$REPO"
  info "branch" "$BRANCH"
  if [[ -d $SRC/.git ]]; then
    git -C "$SRC" fetch --depth 50 origin "$BRANCH" --quiet 2>/dev/null || true
    info "local HEAD" "$(git -C "$SRC" rev-parse --short HEAD) $(git -C "$SRC" log --format=%s -1)"
    info "remote HEAD" "$(git -C "$SRC" rev-parse --short origin/$BRANCH 2>/dev/null || echo '?')"
    info "installed from" "$(cut -c1-7 "$STAMP" 2>/dev/null || echo 'never')"
    info "artifacts" "$([[ -d $SRC/target ]] && echo "present ($(du -sh "$SRC" 2>/dev/null | cut -f1))" || echo "cleaned ($(du -sh "$SRC" 2>/dev/null | cut -f1))")"
  else
    info "source" "not cloned yet"
  fi
  info "built binary" "$([[ -x $BIN ]] && "$BIN" --version 2>&1 | head -1 || echo none) [$(built_sha)]"
  info "installed" "$([[ -x $DEST ]] && "$DEST" --version 2>&1 | head -1 || echo none) [$(installed_sha)]"
  info "pacman herdr" "$(pacman -Q herdr 2>/dev/null || echo 'removed (correct)')"
  info "PATH resolves to" "$(command -v herdr || echo 'NOT FOUND')"
  exit 0
fi

# --- update + build ---------------------------------------------------------
step "Fetching $REPO ($BRANCH)"
ensure_src
read_toolchains
info "rust (from tree)" "$RUST"
info "zig (from tree)" "$ZIG"

# Nothing to do at all? Artifacts are deleted after install, so the question is
# not "is there a built binary" but "is the INSTALLED one from this commit".
if [[ $MODE == install ]] && (( ! FORCE )) &&
   [[ -x $DEST && $(cat "$STAMP" 2>/dev/null) == "$HEAD_SHA" ]]; then
  step "Already current"
  info "installed" "$("$DEST" --version 2>&1 | head -1)"
  info "from commit" "$(echo "$HEAD_SHA" | cut -c1-7)"
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
  step "Toolchains (mise, user-level -- no root, no pacman)"
  mise install "rust@$RUST" "zig@$ZIG"

  step "Building (release)"
  ( cd "$SRC" && mise x "rust@$RUST" "zig@$ZIG" -- cargo build --release )
  # Stamp only after cargo succeeds, so a failed build never looks current.
  printf '%s\n' "$HEAD_SHA" > "$STAMP"
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
  pgrep -a herdr | sed 's/^/    /'
  die "herdr is running -- close those sessions first, or re-run with --force"
fi

step "Installing to $DEST"
if pacman -Qq herdr >/dev/null 2>&1; then
  echo "    removing the packaged herdr (it shadows nothing, but keep it tidy)"
  sudo pacman -R --noconfirm herdr
else
  info "pacman herdr" "already absent"
fi
sudo install -Dm755 "$BIN" "$DEST"

# Stamped only after the binary is in place, so an aborted install never claims
# to be current.
printf '%s\n' "$HEAD_SHA" > "$STAMP"

step "Verifying"
hash -r 2>/dev/null || true
info "which herdr" "$(command -v herdr)"
info "version" "$(herdr --version 2>&1 | head -1)"
info "config" "$(herdr config check 2>&1 | head -1)"

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
