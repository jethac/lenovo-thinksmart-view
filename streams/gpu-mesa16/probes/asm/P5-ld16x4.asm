@in(r0.x)	in0 (wrmask=0x7)
mov.u32u32 r1.x, 0
shl.b r0.w, r0.x, 3
shl.b r0.y, r0.x, 2
(rpt5)nop
ldgb.untyped.4d.u16.4 hr2.x, g[1], r0.w, r0.y
(sy)cov.u16u32 r3.x, hr2.x
cov.u16u32 r3.y, hr2.y
cov.u16u32 r3.z, hr2.z
cov.u16u32 r3.w, hr2.w
shl.b r1.z, r0.x, 4
mov.u32u32 r1.w, 0
(rpt5)nop
stgb.untyped.4d.u32.4 g[0], r3.x, r0.y, r1.z
end
nop
