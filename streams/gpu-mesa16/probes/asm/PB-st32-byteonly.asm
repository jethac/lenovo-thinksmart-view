@in(r0.x)	in0 (wrmask=0x7)
mov.u32u32 r1.x, 0
shl.b r0.w, r0.x, 2
mov.u32u32 r1.y, 0
(rpt5)nop
ldgb.untyped.4d.u32.1 r2.x, g[1], r0.w, r0.x
(sy)(rpt5)nop
stgb.untyped.4d.u32.1 g[0], r2.x, r1.y, r0.w
end
nop
