@in(r0.x)	in0 (wrmask=0x7)
mov.u32u32 r1.x, 0
shl.b r0.w, r0.x, 1
(rpt5)nop
ldgb.untyped.4d.f16.1 hr2.x, g[1], r0.w, r0.x
(sy)add.f hr2.y, hr2.x, hr2.x
mov.u32u32 r1.w, 0
(rpt5)nop
stgb.untyped.4d.f16.1 g[0], hr2.y, r0.x, r0.w
end
nop
