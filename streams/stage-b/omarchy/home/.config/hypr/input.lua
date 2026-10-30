-- ThinkSmart View input overrides.
hl.config({
  input = {
    -- The FT8201 (or HX83100A) touchscreen maps onto the DSI panel. If touches
    -- land mirrored or rotated, set transform here (0-7, as for monitors).
    touchdevice = {
      output = "DSI-1",
      transform = 0,
    },
  },
})
