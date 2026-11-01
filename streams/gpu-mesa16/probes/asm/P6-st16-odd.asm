@in(r0.x)	in0 (wrmask=0x7)
mov.u32u32 r1.x, 0
shl.b r0.w, r0.x, 1
shl.b r1.y, r0.x, 1
shl.b r1.z, r0.x, 2
mov.u32u32 r1.w, 0
(rpt5)nop
ldgb.untyped.4d.u16.1 hr2.x, g[1], r0.w, r0.x
add.u r1.y, r1.y, 1
add.u r1.z, r1.z, 2
(sy)(rpt5)nop
stgb.untyped.4d.u16.1 g[0], hr2.x, r1.y, r1.z
end
nop
