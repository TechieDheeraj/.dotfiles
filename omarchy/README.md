# Omarchy always-on server config

Turns this Lenovo Yoga Pro 7 14IAH10 (Omarchy 4.0.0) into a machine that runs
24/7 on AC, headless in clamshell, and never sleeps, locks, or updates itself.

## Where Omarchy 4 keeps its config

Omarchy 2.x was a git clone at `~/.local/share/omarchy` that you edited in place.
That is gone. Omarchy 4 is a distro made of pacman packages:

| Path | Owner | Safe to edit? |
|---|---|---|
| `/usr/share/omarchy/{bin,default,config,shell}` | `omarchy` pkg | **No** — rewritten by every `omarchy-update` |
| `/etc/mkinitcpio.conf.d/omarchy_hooks.conf` | `omarchy-settings` pkg | **No** — same reason |
| `/etc/systemd/logind.conf.d/10-*.conf`, `20-*.conf` | `omarchy-settings` pkg | **No** |
| `~/.config/hypr/*.lua`, `~/.config/omarchy/*` | you | **Yes** — the designed override layer |
| `~/.local/state/omarchy/{toggles,indicators}/*` | you | **Yes** — runtime toggles |
| new drop-ins under `/etc/**/*.d/` | you | **Yes** |

Everything here follows that rule: nothing writes to a package-owned path. Where
a package-owned file had to be overridden, a later-sorting drop-in does it
(`50-always-on-server.conf`, `zz-server-sd-encrypt.conf`) so `omarchy-update`
can keep improving the defaults underneath.

## Contents

    install.sh               user-level: symlinks configs, disables idle (no root)
    config/hypr/*.lua        keybinding + input overrides ported from Omarchy 2.x
    config/kitty/kitty.conf  kitty, with your 2.x preferences merged in
    config/herdr/config.toml your tmux-style herdr config (backtick prefix)
    config/omarchy/shell.json bar config, 12-hour clock (COPIED, not linked)
    bin/battery-cap          toggle the battery charge cap
    system/apply.sh          root-level setup (idempotent, has --revert)
    system/herdr-fork.sh     build + install herdr from your GitHub fork
    tpm/                     TPM2 auto-unlock for LUKS root -- see tpm/README.md
    system/wifi-be200-suspend-fix.sh
                             laptop-only: stop the BE200 wifi dying on resume
    system/etc/              the files apply.sh installs
    system/usr/              the sleep hook wifi-be200-suspend-fix.sh installs

## Install

    bash install.sh                     # 1. user level, no root
    sudo bash system/apply.sh           # 2. always-on server settings
    sudo pacman -S kitty                # 3. kitty is not installed by default
    omarchy-default-terminal kitty
    bash system/herdr-fork.sh           # 4. herdr from your fork (asks for sudo)
    sudo bash tpm/tpm2-unlock.sh convert      # 5. optional; see tpm/README.md
    sudo bash tpm/tpm2-unlock.sh enroll       #    reboot between the two stages

If this machine is a laptop you actually suspend, run the wifi fix **instead of**
step 2 -- `apply.sh` masks `sleep.target`, so the two contradict each other:

    sudo bash system/wifi-be200-suspend-fix.sh

Without it the Intel BE200 falls off the PCI bus on the first resume from s2idle
and only a physical power-off brings it back. See the header comment in that
script for the full diagnosis; the short version is that the platform drops the
card to D3cold and never restores power, and no rescan or bus reset recovers it,
so the fix has to prevent the transition rather than repair it afterwards.

`install.sh` symlinks rather than copies, so later edits to `~/.config/hypr/*.lua`
land in this repo and `git status` shows the drift. The Omarchy templates it
replaces are kept beside them as `*.lua.omarchy-default`.

## Ported from Omarchy 2.x

`config/hypr/bindings.lua` reproduces what used to live in
`~/.dotfiles/files/config/local/share/omarchy/default/hypr/bindings/`. In 2.x you
customised by editing Omarchy's own default files; in 4 those are package-owned,
so the same result comes from `hl.unbind()` + `o.bind()` in your own file.

| | keys | replaces |
|---|---|---|
| Focus | `SUPER + ; ' [ /` | arrow keys |
| Swap | `SUPER + H J K L` | `SUPER + SHIFT +` arrows |
| Resize | `SUPER + , . - =` | `SUPER + code:20/21` |
| Force kill | `SUPER + SHIFT + W` | (new; was Omawrite) |
| Full width | `SUPER + bracketright` | `SUPER + ALT + F` |
| Keybindings | `SUPER + SHIFT + K` | `SUPER + K`, now swap-down |
| Monitor scale up | `SUPER + SHIFT + ALT + SLASH` | `SUPER + SLASH`, now focus-down |

Unbound to match 2.x: `SUPER + F`, `SUPER + CTRL + F`, `SUPER + ALT + F`,
`XF86PowerOff`.

`config/hypr/input.lua` carries the only two input settings that actually differ
from Omarchy 4: `repeat_delay = 600` and `touchpad.natural_scroll = true`.

### kitty

Your 2.x kitty.conf was a macOS config -- `kitty_mod` was `cmd+shift`, and every
`cmd+` binding in it is inert on Linux. `config/kitty/kitty.conf` translates the
intent: `alt+;` / `alt+'` for shell word-navigation (`ESC b` / `ESC f`, matching
`SUPER + ;` / `'` for window focus), `ctrl+shift+;` / `'` for pane cycling,
splits and resize on the same relative keys, plus `disable_ligatures always`,
unlimited scrollback, and `window_padding_width 0`.

Font size stays at Omarchy's 9.0 rather than your 2.x 16.0 -- that 16 was for a
different display; this panel is 3000x1876 at scale 2.

kitty is NOT installed by default on Omarchy 4 (only foot is):

    sudo pacman -S kitty
    omarchy-default-terminal kitty

### herdr

`system/herdr-fork.sh` builds herdr from
`github.com/TechieDheeraj/herdr @ feat_health_check` and installs it to
`/usr/local/bin/herdr`, replacing the packaged build. Removing the package is
safe: `pacman -Qi herdr` says "Required By: None", and it is only an *optional*
dep of omarchy-settings, so `omarchy-update` will not pull it back. Even if it
did, `/usr/local/bin` precedes `/usr/bin` in PATH here.

Two build gotchas, both handled by the script:

* The toolchains are pinned by the tree -- `rust-toolchain.toml` wants Rust
  1.96.1 and `vendor/libghostty-vt/build.zig.zon` wants zig >= 0.15.2. Arch
  ships zig 0.16.0, a breaking release for that vendored code, so the script
  uses mise for both instead of pacman. No root needed for the build itself.
* `build.rs` shells out to `zig` to compile the vendored libghostty-vt. With zig
  missing it panics with `Os { code: 2, kind: NotFound }` rather than saying what
  it wanted.

Your config was written for herdr 0.7.5. Every key it uses still exists in the
0.8.0 source, and `herdr config check` reports `config: ok` against the built
fork binary.

### A trap worth remembering

`SUPER + ALT + EQUAL` looks free in `hyprctl binds` but is not: Omarchy binds
that combo as `SUPER + ALT + code:21`, and keycode 21 *is* the equal key. A
keysym binding on the same physical key fires alongside it rather than replacing
it. Every minus/equal combination is taken this way by the resize variants. When
picking a key, check for `code:20`/`code:21` at that modmask, not just the
keysym.

## What each piece does

**Never sleeps.** `HandleLidSwitch` defaults to `suspend`, so closing the lid
would suspend the box and drop every SSH session. The logind drop-in sets that
plus the docked/AC variants and the suspend/hibernate keys to `ignore`, and pins
`IdleAction=ignore`. `apply.sh` additionally masks `sleep.target`,
`suspend.target`, `hibernate.target`, `hybrid-sleep.target` and
`suspend-then-hibernate.target`, so nothing can suspend the machine even by
explicit request. Deliberate suspend is lost; that is the trade.

**No screensaver, no lock.** Omarchy 4 has no hypridle. Its shell runs an idle
service reading `~/.config/omarchy/shell.json` (`idle.screensaver` 150s,
`idle.lock` 300s). Rather than setting those to absurd values, use the supported
switch, which disables the whole idle cycle:

    omarchy-toggle-idle stay-awake     # off (a file in ~/.local/state, survives reboot+update)
    omarchy-toggle-idle status
    omarchy-debug-idle                 # full state dump; "enabled": false is what you want
    omarchy-toggle-idle allow-idle     # back to normal

Closing the lid still locks the session (Hyprland binds `switch:on:Lid Switch` to
`omarchy-system-lid-close`). That is independent of the idle timer and does not
affect SSH. It also disables the internal panel, which is what you want on this
machine's OLED.

**No auto-updates.** Nothing to disable — Omarchy 4 never updates itself. There
are no update timers; `omarchy-update` is manual. The only automatic thing is the
`omarchy.system-update` bar widget polling `omarchy-update-available` to show an
icon. To remove even that, delete the `{"id": "omarchy.system-update"}` entry
from the `center` array in `~/.config/omarchy/shell.json`.

**Battery.** No percentage target is possible on this hardware. There is no
`charge_control_end_threshold`, no `charge_behaviour`, and
`/sys/class/firmware-attributes/` is empty. The only firmware charge limiter is
ideapad's `conservation_mode`, an on/off EC cap at roughly 55-60%. For a machine
that lives on AC that is the better setting anyway: calendar aging tracks state
of charge, so ~60% ages the cell far more slowly than 90% would.

    battery-cap status | on | off

`battery-conservation.service` re-enables the cap on every boot, so `off` is
temporary — use it to charge to 100% before taking the laptop out.

## Deliberately NOT ported from 2.x

* **waybar** (`files/config/waybar/`) — Omarchy 4 replaced waybar with its own
  Quickshell bar. `config.jsonc`, `style.css` and `scripts/fan-spin.sh` have no
  direct equivalent. The bar is configured in `~/.config/omarchy/shell.json`;
  a fan/RPM readout would have to be rebuilt as a plugin under
  `~/.config/omarchy/plugins/`.
* **hypridle.conf / hyprlock.conf** — hypridle and hyprlock are not installed on
  Omarchy 4. Idle now lives in `shell.json` (`idle.screensaver`, `idle.lock`) and
  locking is `omarchy-system-lock`. Your 2.x timeouts were the 2.x defaults
  anyway, and this machine has idling disabled outright.
* **hypr/lid.sh** — your clamshell script (dpms off eDP-1, move workspace to the
  external monitor) is superseded by `omarchy-hyprland-monitor-clamshell`, which
  Omarchy 4 already binds to the lid switch.
* **ghostty config** — a macOS config like the kitty one. Its portable ideas are
  already carried over into `config/kitty/kitty.conf`; port them here too if you
  switch terminals.
* **alacritty / foot** — left at Omarchy 4 defaults; you chose kitty.
* **cmux** — not packaged for Omarchy 4.
* **nvim** — nothing to port. Your only change was
  `vim.opt.relativenumber = false`, which `omarchy-nvim` already sets.
* **alacritty font / monitor scale** — CaskaydiaMono and `opacity 0.98` were the
  2.x Omarchy defaults, not your edits. `monitor=eDP-1,...,1.33333` was for a
  different display; you already set `omarchy_monitor_scale = 2` here.

## Reverting

    bash install.sh                          # re-apply user level
    sudo bash system/apply.sh --revert
    omarchy-toggle-idle allow-idle
    sudo bash tpm/tpm2-unlock.sh revert      # only if you ran tpm2-unlock.sh

To drop a ported binding, delete it from `config/hypr/bindings.lua` and run
`hyprctl reload`. To go back to stock, point `~/.config/hypr/bindings.lua` at the
saved `bindings.lua.omarchy-default`.
