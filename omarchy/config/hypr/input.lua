-- Personal input overrides, ported from ~/.dotfiles/files/config/hypr/input.conf.
-- Only the two settings that actually differ from Omarchy 4's defaults are set
-- here; everything else in your 2.x input.conf already matches what Omarchy 4
-- ships (see the notes at the bottom).

hl.config({
  input = {
    -- You slowed the repeat delay from Omarchy's 250ms to 600ms, so a held key
    -- waits noticeably longer before it starts repeating. repeat_rate stays at
    -- Omarchy's 40, which is what you had too.
    repeat_delay = 600,

    touchpad = {
      -- Mac-style inverse scrolling. Omarchy 4 defaults this to false.
      natural_scroll = true,
    },
  },
})

-- Already identical to Omarchy 4's defaults, so deliberately not repeated here:
--
--   repeat_rate = 40, numlock_by_default = true, touchpad.scroll_factor = 0.4,
--   and the per-app touchpad scroll rules for Alacritty/kitty/ghostty.
--
-- One difference worth knowing about rather than reverting:
--
--   kb_options: you had "compose:caps". Omarchy 4 defaults to
--   "compose:caps,shift:both_capslock_cancel" -- same compose key, plus both
--   Shifts together as the new home for Caps Lock (which compose:caps takes
--   over). That is a superset of your setting, so it is left alone.
--
--   touchpad.clickfinger_behavior: off in 2.x, true in Omarchy 4. That was the
--   2.x default rather than a choice you made, so Omarchy 4's default stands.
--   Set it to false here if you prefer right-click in the lower-right corner.
