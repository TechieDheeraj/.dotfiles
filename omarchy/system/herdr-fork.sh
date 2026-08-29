#!/usr/bin/env bash
# Build and install herdr from your fork, replacing Omarchy's packaged build.
#
#   bash herdr-fork.sh          # clone/update, build, then install (asks for sudo)
#   bash herdr-fork.sh build    # build only, no root, no package changes
#
# WHY NOT JUST `pacman -R herdr` AND DROP A BINARY IN:
# that is exactly what this does, but the ordering matters. /usr/local/bin comes
# before /usr/bin in PATH on this system, so the fork wins even if the package
# ever comes back. Removing the package is safe: `pacman -Qi herdr` reports
# "Required By: None" and it is only an *optional* dep of omarchy-settings, so
# omarchy-update will not pull it back.

set -euo pipefail

REPO=https://github.com/TechieDheeraj/herdr
BRANCH=feat_health_check
SRC="$HOME/.local/src/herdr-fork"
# Pinned to what the tree asks for: rust-toolchain.toml says 1.96.1, and
# vendor/libghostty-vt/build.zig.zon says minimum_zig_version = "0.15.2".
# Arch ships zig 0.16.0, which is a breaking release for that vendored code --
# hence mise rather than pacman for both toolchains.
RUST=1.96.1
ZIG=0.15.2

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

step "Fetching $REPO ($BRANCH)"
if [[ -d $SRC/.git ]]; then
  git -C "$SRC" fetch --depth 1 origin "$BRANCH"
  git -C "$SRC" checkout -B "$BRANCH" "origin/$BRANCH"
else
  mkdir -p "$(dirname "$SRC")"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$SRC"
fi
git -C "$SRC" log --oneline -1

step "Toolchains (mise, user-level -- no root, no pacman)"
mise install "rust@$RUST" "zig@$ZIG"

step "Building (release)"
# The vendored libghostty-vt is Zig, compiled by build.rs shelling out to `zig`.
# Without zig on PATH the cargo build panics in build.rs rather than failing
# with a useful message, so both toolchains have to be in the same `mise x`.
cd "$SRC"
mise x "rust@$RUST" "zig@$ZIG" -- cargo build --release
ls -la "$SRC/target/release/herdr"
"$SRC/target/release/herdr" --version

[[ ${1:-} == build ]] && { echo; echo "Built only. Re-run without 'build' to install."; exit 0; }

step "Replacing the packaged herdr"
if pacman -Qq herdr >/dev/null 2>&1; then
  sudo pacman -R --noconfirm herdr
else
  echo "(packaged herdr already absent)"
fi
sudo install -Dm755 "$SRC/target/release/herdr" /usr/local/bin/herdr

step "Verifying"
hash -r 2>/dev/null || true
printf '%-18s %s\n' "which herdr:" "$(command -v herdr)"
printf '%-18s %s\n' "version:" "$(herdr --version 2>&1 | head -1)"
echo
echo "Config: ~/.config/herdr/config.toml (symlinked to this repo by install.sh)"
