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

## Reinstalling from scratch — the runbook

Follow top to bottom. Each row says what it fixes, so you can skip what you do
not need. Everything is idempotent: re-running a step is always safe.

**Before you start:** plug in the AC adapter (steps 2 and 7 rewrite boot images;
losing power mid-write leaves an unbootable machine), and have an Arch/Omarchy
live USB written if you intend to do step 8.

| # | Run | What it fixes | Root | Reboot after |
|---|---|---|---|---|
| 1 | `bash install.sh` | Restores your Hyprland keybindings, input tweaks, monitor scale, kitty, herdr and bar config. Wires `~/.dotfiles/bashrc_mac` into `~/.bashrc`. Disables the screensaver and idle lock so the machine never blanks. | no | no |
| 2 | `sudo bash system/apply.sh` | **The core server fix.** Lid close and idle stop suspending the machine. Battery charge cap on. Always-on USB charging off. Hibernate powers off cleanly instead of ACPI S4. | yes | no |
| 3 | *see "Step 3 — SSH" below* | Makes the machine actually reachable. Without this the only way in is a password, on a box that is online permanently. | yes | no |
| 4 | `sudo pacman -S kitty`<br>`omarchy-default-terminal kitty` | Omarchy 4 ships config templates for four terminals but installs only `foot`. Step 1 already placed your kitty config. | yes | no |
| 5 | `sudo bash system/wifi-be200-suspend-fix.sh` | Stops the Intel BE200 wifi card falling off the PCI bus on the first resume from suspend, where only a physical power-off recovers it. Do this before you ever suspend. | yes | no |
| 6 | `bash system/herdr-fork.sh` | *Optional.* Builds herdr from your GitHub fork. Skip it unless you need the fork's features — the packaged herdr runs your config fine. | asks | no |
| 7 | `sudo pacman -S fwupd`<br>`fwupdmgr refresh --force`<br>`sudo fwupdmgr update` | **Must come before step 8.** Applies firmware/UEFI-dbx updates. Each one changes PCR 7, which invalidates a TPM enrollment — do them first or you will enroll, update firmware, and be back at the passphrase prompt wondering why. Lenovo does not publish this model's BIOS to LVFS, so expect only the dbx. | yes | yes |
| 8 | `sudo bash tpm/tpm2-unlock.sh check`<br>`… convert` → reboot<br>`… enroll` → reboot | *Optional but high value.* Unlocks the encrypted disk from the TPM so the machine reboots unattended. Without it every reboot stops at the passphrase prompt until someone is physically present. **Read `tpm/README.md` first.** | yes | **yes, twice** |
| 9 | `sudo bash system/sunshine-remote-desktop.sh`<br>`bash install.sh` | *Optional.* Remote desktop from the Mac via Moonlight. The `install.sh` re-run enables the user service. | yes | no |

Step 2 is the one that makes this a server. Steps 6 and 9 are conveniences.

**Not automated, and not scripted anywhere — do these by hand:**

| | |
|---|---|
| Git identity | `~/.config/git/config` holds your name/email. Omarchy's template has neither, and this repo does not track it (it would commit your address). Re-add with `git config --global user.name` / `user.email`. |
| Shell | Step 1 appends a block to `~/.bashrc` sourcing `~/.dotfiles/bashrc_mac`. Note the top-level `~/.dotfiles/install.sh` copies `./bashrc` over `~/.bashrc` — running that *after* this would undo it. |

### Step 3 -- SSH (nothing here does this for you)

Enabling `sshd` is not enough. Without an `authorized_keys` file the only way in
is a **password**, on a machine that is online permanently. Order matters: add
the key and prove it works BEFORE disabling passwords, or you lock yourself out.

Omarchy has a helper that does all three parts at once:

    omarchy-setup-security-sshd        # installs+enables sshd, ufw limit 22/tcp, adds your key

Or by hand. From the machine you connect FROM (password auth is still on, which
is what makes this work):

    ssh-copy-id dheeraj@<host>

On the server:

    sudo ufw status | grep 22 || { sudo ufw limit 22/tcp && sudo ufw reload; }

Verify key login from the other machine, in a NEW terminal:

    ssh -o PreferredAuthentications=publickey dheeraj@<host> 'echo KEY OK'

Only once that prints, and keeping your existing session open:

    sudo tee /etc/ssh/sshd_config.d/10-hardening.conf <<'EOF'
    PasswordAuthentication no
    PermitRootLogin no
    EOF
    sudo systemctl reload sshd

`/etc/ssh/sshd_config` ships `#PasswordAuthentication yes` commented out, so the
default applies and passwords are accepted until this drop-in exists.

Then prove the machine is actually a server -- from the other machine:

    ssh dheeraj@<host> 'while true; do date; sleep 5; done'

Close the lid. If the output keeps flowing, it works. This is the only way to
tell a running clamshell machine from a suspended one: with the lid shut the
screen is dark and silent either way.

Note this laptop is **wifi-only with DHCP** -- no ethernet port, so the address
can move. Set a DHCP reservation on the router, or use mDNS (`avahi-daemon` is
enabled, so `<hostname>.local` resolves).

Run the wifi fix **as well** -- it is no longer in conflict with step 2. It used
to be, because `apply.sh` masked `sleep.target`; masking is now opt-in and off by
default, so suspend works and the BE200 fix matters again:

    sudo bash system/wifi-be200-suspend-fix.sh

Without it the Intel BE200 falls off the PCI bus on the first resume from s2idle
and only a physical power-off brings it back. See the header comment in that
script for the full diagnosis; the short version is that the platform drops the
card to D3cold and never restores power, and no rescan or bus reset recovers it,
so the fix has to prevent the transition rather than repair it afterwards.

`install.sh` symlinks rather than copies, so later edits to `~/.config/hypr/*.lua`
land in this repo and `git status` shows the drift. The Omarchy templates it
replaces are kept beside them as `*.lua.omarchy-default`.

## What each file is

| File | Purpose | Run by |
|---|---|---|
| `install.sh` | Symlinks user configs into `~/.config`, copies `shell.json`, links `~/.local/bin`, disables idle | you, step 1 |
| `config/hypr/bindings.lua` | Keybindings ported from Omarchy 2.x — focus on `; ' [ /`, swap on `HJKL`, resize on `, . - =` | symlinked |
| `config/hypr/input.lua` | `repeat_delay=600`, touchpad `natural_scroll` | symlinked |
| `config/hypr/monitors.lua` | Pins integer scale 2 for this 3000x1876 panel (machine-specific) | symlinked |
| `config/kitty/kitty.conf` | kitty with your 2.x preferences translated from macOS | symlinked |
| `config/herdr/config.toml` | tmux-style herdr config, backtick prefix | symlinked |
| `config/omarchy/shell.json` | Bar layout, 12-hour clock, battery percentage | **copied** — the bar writes to it |
| `config/sunshine/` | Sunshine host config and trimmed `apps.json` | **copied** |
| `bin/battery-cap` | `battery-cap [on\|off\|status\|usb …]` — charge cap and USB charging | symlinked to `~/.local/bin` |
| `system/apply.sh` | Installs everything under `system/etc/`; `--revert` undoes it | you, step 2 |
| `system/etc/systemd/logind.conf.d/50-always-on-server.conf` | Lid, idle, power and sleep keys all `ignore` | apply.sh |
| `system/etc/systemd/sleep.conf.d/50-hibernate-mode.conf` | `HibernateMode=shutdown` — plain power-off, not ACPI S4 | apply.sh |
| `system/etc/systemd/system/battery-conservation.service` | Charge cap on, always-on USB charging off, at every boot | apply.sh |
| `system/etc/udev/rules.d/99-lenovo-battery-conservation.rules` | Lets `wheel` toggle those without sudo | apply.sh |
| `system/wifi-be200-suspend-fix.sh` | Installs the sleep hook under `system/usr/` that keeps the BE200 out of D3cold | you, step 5 |
| `system/herdr-fork.sh` | Builds + installs herdr from your fork | you, step 6 |
| `system/sunshine-remote-desktop.sh` | Sunshine install, ufw ports, service | you, step 8 |
| `tpm/tpm2-unlock.sh` | TPM2 LUKS unlock — `check`/`convert`/`enroll`/`revert`, all auto-detected | you, step 7 |
| `tpm/README.md` | Full TPM procedure, validation and three levels of rollback | reading |

## Verifying it worked

    omarchy-debug-idle | grep '"enabled"'                  # false = idle disabled
    systemctl is-active sshd                               # active
    busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
      org.freedesktop.login1.Manager HandleLidSwitch       # "ignore"
    battery-cap status                                     # cap ON, USB OFF
    grep -o rd.luks.name /proc/cmdline                     # TPM unlock active (step 7)
    systemd-analyze cat-config systemd/sleep.conf | grep HibernateMode   # shutdown

Then the real test — from another machine:

    ssh dheeraj@<host> 'while true; do date; sleep 5; done'

Close the lid. If output keeps flowing, it is a server.

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

### Sunshine (remote desktop from the Mac)

Streams this laptop's Hyprland session to Moonlight on the Mac. Two halves, in
this order -- the root half installs the package the user half then enables:

    sudo bash system/sunshine-remote-desktop.sh
    bash install.sh

**Do not use `omarchy-install-service-sunshine`.** It installs the package, then
runs `systemctl --user enable --now sunshine`, which fails: the packaged unit is
`app-dev.lizardbyte.app.Sunshine.service` and its `Alias=sunshine.service` does
not resolve until the real unit has been enabled once. `set -e` aborts the rest
-- firewall rules, admin web app, autostart entry -- so you end up with the
package installed, nothing enabled, no ports open, and no error that says which
step died. Enable the real unit name; that is what `install.sh` does.

**Never run `sunshine` from an SSH shell.** It inherits no `WAYLAND_DISPLAY` and
every encoder fails:

    Error: [wayland] Environment variable WAYLAND_DISPLAY has not been defined
    Info: Encoder [vaapi] failed

The systemd *user* service is the only correct way in: the user manager holds the
session environment (`WAYLAND_DISPLAY=wayland-1`, `XDG_CURRENT_DESKTOP=Hyprland`)
that an SSH shell does not. A healthy start logs `Found H.264 encoder:
h264_vaapi`, and HEVC and AV1 beside it. Log lives at
`~/.config/sunshine/sunshine.log`.

**The admin UI stays on localhost.** Port 47990 is deliberately absent from the
firewall list. Reach it from the Mac over a tunnel:

    ssh -L 47990:localhost:47990 dheeraj@<host>     # leave running

then `https://localhost:47990` in the Mac's browser (self-signed cert). First
load creates Sunshine's own admin login -- unrelated to the system account.
Moonlight shows a 4-digit PIN; enter it under the PIN tab. Pairing is one-time;
normal streaming does not need the tunnel.

**Picture quality is a client-side setting, not a host one.** Sunshine encodes at
whatever bitrate the client requests. `max_bitrate` can only lower that number,
never raise it, and there is no host setting that overrides a client asking for
too little. The first connect here negotiated 7.3 Mbps against a 3000x1876 panel
downscaled to 1920x1080, which is exactly as blurry as it sounds -- and nothing
in `sunshine.conf` could have fixed it. In Moonlight on the Mac:

| setting | value | why |
|---|---|---|
| Video bitrate | 100-150 Mbps | the default ask was 7.3 Mbps; the wifi link is ~2.1 Gbit/s |
| Resolution | custom `3000x1876` | matches the panel exactly |
| | or `2560x1600` | best standard fallback: 1.600 against the panel's 1.599, so no distortion |
| FPS | 60 | the panel's preferred mode (it also advertises 120) |
| Codec | HEVC, or AV1 on M3+ | earlier Apple Silicon has no AV1 hardware decode |
| YUV 4:4:4 | on, if offered | 4:2:0 chroma subsampling is what smears coloured text |
| Optimize game settings | off | it overrides the resolution you just picked |

Avoid every 16:9 preset: 1920x1080 against this panel is a downscale *and* an
aspect-ratio fight.

**Capture backend and the lid.** Sunshine selects `zwlr_screencopy` here rather
than the xdg portal -- no permission dialog, and the full 3000x1876 framebuffer.
It survives a lid close: `omarchy-hyprland-monitor-clamshell` only disables the
internal panel when an external monitor is *also* active
(`omarchy-hw-clamshell && omarchy-hyprland-monitor-external-active`), which on
this machine never happens, so eDP-1 stays enabled and capturable. The lid does
still lock the session via `omarchy-system-lid-close`, but you can unlock through
Moonlight. Note this is the one place the always-on-server setup helps rather
than fights: `apply.sh` already stops the lid from suspending the machine.

**`apps.json` is trimmed to a single Desktop entry.** The stock file also ships
"Low Res Desktop", whose prep-cmd is `xrandr --output HDMI-1 --mode 1920x1080` --
an X11 command for a display this machine does not have. It fails on every
launch with `Unable to find executable [xrandr]`. The Steam entry went too;
Steam is not installed.

**Checking the firewall rules landed.** `ufw` writes rule comments to
`/etc/ufw/user.rules` hex-encoded, so `grep omarchy-sunshine` on that file always
returns nothing even when all 27 rules are present -- look for
`comment=6f6d61726368792d73756e7368696e65`, or just use `sudo ufw status`, which
prints them in plain text.

Exit a running stream with **Ctrl+Alt+Shift+Q** (Control+Option+Shift+Q on the
Mac). `Ctrl+Alt+Shift+S` toggles the stats overlay. Quitting only disconnects;
the Hyprland session carries on untouched.

### A keybinding trap worth remembering

`SUPER + ALT + EQUAL` looks free in `hyprctl binds` but is not: Omarchy binds
that combo as `SUPER + ALT + code:21`, and keycode 21 *is* the equal key. A
keysym binding on the same physical key fires alongside it rather than replacing
it. Every minus/equal combination is taken this way by the resize variants. When
picking a key, check for `code:20`/`code:21` at that modmask, not just the
keysym.

## What each piece does

**Never sleeps by itself, but you can still put it to sleep.** That distinction
is the whole design.

`HandleLidSwitch` defaults to `suspend`, so closing the lid would drop every SSH
session. The logind drop-in sets that plus the docked/AC variants, the power key
and the suspend/hibernate keys to `ignore`, and pins `IdleAction=ignore`. Result:

| trigger | behaviour |
|---|---|
| lid close | ignored |
| idle timeout | ignored |
| power / suspend / hibernate keys | ignored |
| `systemctl suspend` / `hibernate` | **works** |
| Omarchy power menu | **works** |

Nothing else on the system can sleep it: no timer, no service, and the Omarchy
idle plugin only draws a screensaver and locks -- it has no suspend call at all.

`apply.sh` can additionally mask `sleep.target`, `suspend.target`,
`hibernate.target`, `hybrid-sleep.target` and `suspend-then-hibernate.target`,
making sleep structurally impossible. That is **opt-in and off by default**:

    sudo MASK_SLEEP=1 bash system/apply.sh

Worth doing before a long unattended stretch, or if someone else gets access --
this laptop has **no ethernet port**, so a suspended machine cannot be woken
remotely by any means. The only recovery is physically pressing a key. Masking is
also a useful diagnostic: it turns a mystery suspend into a logged `Access
denied` that names the caller.

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
ideapad's `conservation_mode`, an on/off EC cap. **Measured on this machine the
cap is ~80%**, not the ~55-60% commonly quoted for older IdeaPads -- observed
holding at 80% with `Not charging` and `conservation_mode=1`. For a machine
that lives on AC that is the better setting anyway: calendar aging tracks state
of charge, so ~80% still ages the cell more slowly than sitting at 100%.

    battery-cap status | on | off

`battery-conservation.service` re-enables the cap on every boot, so `off` is
temporary — use it to charge to 100% before taking the laptop out.

## Known quirks on this hardware

### acpi-fan fails to restore after every hibernate — harmless, NOT fixable

Every resume from hibernate logs 15 lines like:

    acpi-fan PNP0C0B:00: Error updating fan power state
    acpi-fan PNP0C0B:00: PM: dpm_run_callback(): platform_pm_restore returns -19
    acpi-fan PNP0C0B:00: PM: failed to restore: error -19

`-19` is `ENODEV`. Afterwards the five Fan cooling devices read `cur_state = ERR`.

**Root cause is a Lenovo firmware bug, not Linux.** Attempting a driver rebind
(`/sys/bus/platform/drivers/acpi-fan/{unbind,bind}`) makes the real error visible:

    ACPI BIOS Error (bug): Could not resolve symbol [\_SB.PC00.LPCB.UPFS], AE_NOT_FOUND
    ACPI Error: Aborting method \_TZ.FNCL due to previous error
    ACPI Error: Aborting method \_TZ.FN03._ON due to previous error
    acpi PNP0C0B:03: Failed to set initial power state

The fans' `_ON` power-resource method calls `\_TZ.FNCL`, which references
`\_SB.PC00.LPCB.UPFS` -- a symbol that does not exist in the ACPI namespace. No
kernel change can fix a method that points at nothing. Only a Lenovo BIOS update
could, and this model's BIOS is not published to LVFS (Windows-only package).

**Do not attempt the rebind.** `bind` re-runs the failing probe, so it does not
recover them -- it only removes the cooling devices entirely until a reboot.

**It does not affect cooling.** Fan speed is driven by the EC in firmware, which
never consults Linux. Verified by load test with the ACPI fan objects *completely
unbound*:

| time | CPU °C | draw W |
|---|---|---|
| idle | 42 | 6.9 |
| 30s load | 57 | 25.2 |
| 75s load | 63 | 28.4 |
| 90s load | **63** | 27.2 |
| +5s idle | **53** | 15.2 |

Temperature plateaued at 63 °C while dissipating 28 W -- thermal equilibrium,
i.e. active airflow -- then dropped 10 °C in five seconds on release. Passive
cooling cannot do either. 42 °C of headroom below the 105 °C limit.

Related: no thermal zone binds a fan (`cdevs=0` everywhere), the objects are
binary on/off (`max_state=1`), and the firmware publishes no fan RPM at all. They
were decorative even before they broke. The `yogafan` hwmon driver auto-loads on
a vendor-wide DMI alias but never probes -- no matching device.

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
    sudo bash system/sunshine-remote-desktop.sh --revert   # closes the Moonlight ports

To drop a ported binding, delete it from `config/hypr/bindings.lua` and run
`hyprctl reload`. To go back to stock, point `~/.config/hypr/bindings.lua` at the
saved `bindings.lua.omarchy-default`.
