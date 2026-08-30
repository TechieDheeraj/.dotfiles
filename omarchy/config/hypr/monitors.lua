-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- List current monitors and supported resolutions with: hyprctl monitors all

-- MACHINE-SPECIFIC. Tuned for this laptop's internal panel: a 14.5" 3000x1876
-- eDP display (~245 PPI). Revisit both numbers on any other hardware.
--
-- Omarchy's default is scale = "auto", which derives a factor from the EDID's
-- physical size and can land on a fractional value. Fractional scaling on
-- Wayland makes XWayland apps blurry, so this pins the integer instead:
--   3000x1876 physical / 2 = 1500x938 logical
--
-- GDK_SCALE matches it so GTK apps render at 2x rather than being upscaled.
local omarchy_gdk_scale = 2
local omarchy_monitor_scale = 2

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
-- output = "" is a catch-all rule applying to every connected display.
-- mode = "preferred" takes whatever the EDID marks preferred, which on this
-- panel is 60Hz even though it also advertises 3000x1876@120. Fine for a
-- machine that runs lid-shut; set the mode explicitly if you want 120.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })

-- Configure a specific monitor.
-- hl.monitor({ output = "DP-2", mode = "2560x1440@144", position = "0x0", scale = 1 })

-- Portrait/rotated secondary monitor (transform: 1 = 90°, 3 = 270°).
-- hl.monitor({ output = "DP-2", mode = "preferred", position = "auto", scale = 1, transform = 1 })
