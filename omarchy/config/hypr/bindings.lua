-- Personal keybinding overrides, ported from the Omarchy 2.x config in
-- ~/.dotfiles/files/config/local/share/omarchy/default/hypr/bindings/.
--
-- In 2.x you customised by editing Omarchy's own default files. Omarchy 4 makes
-- those package-owned (/usr/share/omarchy/default/hypr/bindings/*.lua), so they
-- are rewritten on every update. The supported equivalent is this file:
-- unbind the default, then bind your key. It loads after the defaults.
--
-- See every active binding with:  omarchy menu keybindings --print

--------------------------------------------------------------------------------
-- Focus: SUPER + ; ' [ /   (home-row punctuation instead of the arrow keys)
--------------------------------------------------------------------------------
-- SUPER + SLASH is "Monitor scaling up" in Omarchy 4, so it has to go first.
-- The other three keys are unbound by default.
hl.unbind("SUPER + SLASH")

o.bind("SUPER + semicolon", "Focus on left window", hl.dsp.focus({ direction = "l" }))
o.bind("SUPER + apostrophe", "Focus on right window", hl.dsp.focus({ direction = "r" }))
o.bind("SUPER + bracketleft", "Focus on above window", hl.dsp.focus({ direction = "u" }))
o.bind("SUPER + slash", "Focus on below window", hl.dsp.focus({ direction = "d" }))

-- Monitor scaling loses its key above. Note SUPER+ALT+EQUAL is NOT free even
-- though `hyprctl binds` shows nothing on "EQUAL" there: Omarchy binds it as
-- SUPER+ALT+code:21, and keycode 21 is the equal key, so a keysym binding on the
-- same combo fires alongside "Shrink window left a little". Every minus/equal
-- combo is taken that way by the resize variants. SUPER+SHIFT+ALT+SLASH is
-- genuinely free and pairs with the default scaling-down key.
--   scaling down stays on SUPER + ALT + SLASH (Omarchy default, untouched)
o.bind("SUPER + SHIFT + ALT + SLASH", "Monitor scaling up", "omarchy-hyprland-monitor-scaling up")

--------------------------------------------------------------------------------
-- Swap windows: SUPER + H J K L  (vim directions)
--------------------------------------------------------------------------------
-- All three of these carry Omarchy 4 defaults that would otherwise win.
hl.unbind("SUPER + J") -- was: Toggle window split
hl.unbind("SUPER + K") -- was: Keybindings menu  (moved to SUPER+SHIFT+K below)
hl.unbind("SUPER + L") -- was: Toggle workspace layout

o.bind("SUPER + H", "Swap window to the left", hl.dsp.window.swap({ direction = "l" }))
o.bind("SUPER + L", "Swap window to the right", hl.dsp.window.swap({ direction = "r" }))
o.bind("SUPER + J", "Swap window up", hl.dsp.window.swap({ direction = "u" }))
o.bind("SUPER + K", "Swap window down", hl.dsp.window.swap({ direction = "d" }))

-- Keybindings menu, displaced by the swap-down binding.
o.bind("SUPER + SHIFT + K", "Keybindings", "omarchy-menu-keybindings")

--------------------------------------------------------------------------------
-- Resize: SUPER + , . - =
--------------------------------------------------------------------------------
-- code:20 IS the minus key and code:21 IS equals, so rebinding them unshifted
-- for vertical resize means unbinding Omarchy's horizontal resize on the same
-- keys. SUPER + comma is "Dismiss last notification" by default.
hl.unbind("SUPER + comma")
hl.unbind("SUPER + code:20")
hl.unbind("SUPER + code:21")

o.bind("SUPER + comma", "Expand window left", hl.dsp.window.resize({ x = -100, y = 0, relative = true }))
o.bind("SUPER + period", "Shrink window left", hl.dsp.window.resize({ x = 100, y = 0, relative = true }))
o.bind("SUPER + minus", "Shrink window up", hl.dsp.window.resize({ x = 0, y = -100, relative = true }))
o.bind("SUPER + equal", "Expand window down", hl.dsp.window.resize({ x = 0, y = 100, relative = true }))

--------------------------------------------------------------------------------
-- Window management
--------------------------------------------------------------------------------
-- Force-kill a hung window. SUPER+SHIFT+W is "Omawrite" among Omarchy 4's
-- preinstalled-app bindings.
hl.unbind("SUPER + SHIFT + W")
o.bind("SUPER + SHIFT + W", "Force kill window", "kill -9 $(hyprctl activewindow -j | jq .pid)")

-- Your 2.x "fullscreen, 1" (full width, keeps the bar). Omarchy 4 calls this
-- fullscreen mode "maximized".
o.bind("SUPER + bracketright", "Full width", hl.dsp.window.fullscreen({ mode = "maximized" }))

-- You had these three commented out in 2.x once bracketright took over.
-- Delete these lines to get Omarchy's fullscreen keys back.
hl.unbind("SUPER + F")        -- was: Full screen
hl.unbind("SUPER + CTRL + F") -- was: Tiled full screen
hl.unbind("SUPER + ALT + F")  -- was: Full width

--------------------------------------------------------------------------------
-- Misc
--------------------------------------------------------------------------------
-- You disabled the hardware power button opening the system menu. Note that
-- logind is separately set to ignore the power key (see the server config), so
-- this is belt and braces.
hl.unbind("XF86PowerOff")

-- NOT ported, deliberately:
--
-- * The arrow keys still focus (SUPER + arrows) and swap (SUPER + SHIFT +
--   arrows). You had commented them out in 2.x, but they collide with nothing
--   here, so they are left working as a fallback. To match 2.x exactly:
--       hl.unbind("SUPER + LEFT")  hl.unbind("SUPER + RIGHT")
--       hl.unbind("SUPER + UP")    hl.unbind("SUPER + DOWN")
--       hl.unbind("SUPER + SHIFT + LEFT")  ... and so on.
--
-- * XF86Calculator -> gnome-calculator. gnome-calculator is not installed on
--   Omarchy 4; the key already opens omacalc, which is the same idea.
--
-- * "Dismiss last notification" has no key now that SUPER + comma resizes.
--   SUPER + SHIFT + comma still dismisses all of them.
