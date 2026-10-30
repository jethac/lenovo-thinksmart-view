-- Adreno 506 shares memory bandwidth with the CPU: no animations, blur or
-- shadows (the same choice omarchy-arm makes for the Raspberry Pi), and
-- thinner gaps on a 640 px wide logical screen.
hl.config({
  animations = { enabled = false },
  decoration = {
    rounding = 0,
    blur = { enabled = false },
    shadow = { enabled = false },
  },
  general = {
    gaps_in = 2,
    gaps_out = 4,
  },
})
