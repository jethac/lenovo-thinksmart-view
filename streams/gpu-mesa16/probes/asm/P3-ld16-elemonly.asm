@in(r0.x)	in0 (wrmask=0x7)
mov.u32u32 r1.x, 0
mov.u32u32 r0.w, 0
(rpt5)nop
ldgb.untyped.4d.u16.1 hr2.x, g[1], r0.w, r0.x
(sy)cov.u16u32 r1.y, hr2.x
shl.b r1.z, r0.x, 2
mov.u32u32 r1.w, 0
(rpt5)nop
stgb.untyped.4d.u32.1 g[0], r1.y, r0.x, r1.z
end
nop
