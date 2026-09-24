-- Change the default Omarchy look'n'feel.

-- https://wiki.hypr.land/Configuring/Basics/Variables/#general
 hl.config({
   general = {
    -- No gaps between windows or borders.
     gaps_in = 0,
     gaps_out = 0,

     -- Thin colored border so the active window is easy to spot
     -- (uses the theme's accent color via col.active_border).
     border_size = 2,
--
--     -- Change to niri-like side-scrolling layout.
--     layout = "scrolling",
  },
 })

-- https://wiki.hypr.land/Configuring/Basics/Variables/#decoration
 hl.config({
   decoration = {
--     -- Use round window corners.
--     rounding = 8,
     blur = { enabled = false },
--     shadow = { enabled = false },
--
--     -- Dim unfocused windows (0.0 = no dim, 1.0 = fully dimmed).
--     dim_inactive = true,
--     dim_strength = 0.15,
   },
 })

-- https://wiki.hypr.land/Configuring/Basics/Variables/#animations
-- hl.config({
--   animations = {
--     -- Disable all animations.
--     enabled = false,
--   },
-- })

-- Fully opaque windows: no alpha blending of what's underneath, and lets
-- fullscreen apps use direct scanout. Overrides Omarchy's default-opacity
-- (0.985 0.96) and browser (1.0 0.985) rules, which load before this file.
o.window({ tag = "default-opacity" }, { opacity = "1 1" })
o.window({ tag = "chromium-based-browser" }, { opacity = "1 1" })
o.window({ tag = "firefox-based-browser" }, { opacity = "1 1" })

-- https://wiki.hypr.land/Configuring/Basics/Variables/#layout
-- hl.config({
--   layout = {
--     -- Avoid overly wide single-window layouts on wide screens.
--     single_window_aspect_ratio = { 1, 1 },
--   },
-- })

-- https://wiki.hypr.land/Configuring/Layouts/Scrolling-Layout/
-- hl.config({
--   scrolling = {
--     -- See only one column per screen instead of two.
--     column_width = 0.97,
--   },
-- })
