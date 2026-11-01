@in(r0.x)	in0 (wrmask=0x7)
mov.u32u32 r1.x, 0
shl.b r0.w, r0.x, 2
shl.b r0.y, r0.x, 1
(rpt5)nop
ldgb.untyped.4d.u16.2 hr2.x, g[1], r0.w, r0.y
mov.u32u32 r1.w, 0
(sy)(rpt5)nop
stgb.untyped.4d.u16.2 g[0], hr2.x, r0.y, r0.w
end
nop
