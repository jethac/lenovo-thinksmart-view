-- ThinkSmart View: DSI panel, 800x1280 portrait, about 189 ppi (8 in).
-- Scale 1.25 gives a 640x1024 logical desktop: touch targets and text at a
-- size a finger can hit, and 800/1.25 and 1280/1.25 are whole numbers, so
-- Hyprland accepts it without rounding. Native orientation is portrait with
-- the camera top left, so no transform.
-- Check the connector name with: hyprctl monitors all
hl.monitor({ output = "DSI-1", mode = "800x1280@60", position = "0x0", scale = 1.25 })
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })

-- X11/XWayland apps only. GTK honours whole numbers; 1 is nearest to 1.25.
hl.env("GDK_SCALE", "1")

-- Adreno 506 has no Vulkan driver (Turnip starts at a6xx). Keep GTK4 on GL.
hl.env("GSK_RENDERER", "ngl")
