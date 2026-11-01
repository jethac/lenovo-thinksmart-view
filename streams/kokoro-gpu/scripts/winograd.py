#!/usr/bin/env python3
"""Winograd F(m, r) for 1-D correlation y[i] = sum_k g[k] d[i+k], built from
interpolation points (Toom-Cook with the point at infinity), and its error
when the transformed weights and inputs are rounded to FP16 and the products
are summed over C input channels in FP16, folded into FP32 every `fold`
channels (as straylight-gpu's kernels do).

    winograd.py              table of SNR (dB) against an exact direct conv
"""
import itertools, sys
from fractions import Fraction as Fr
import numpy as np


def mats(m, r, pts):
    """AT (m x n), G (n x r), BT (n x n), exact (Fractions), n = m + r - 1."""
    n = m + r - 1
    a = [Fr(p) for p in pts]
    assert len(a) == n - 1
    AT = [[a[j] ** i for j in range(n - 1)] + [Fr(int(i == m - 1))] for i in range(m)]
    G = []
    for j in range(n - 1):
        f = Fr(1)
        for l in range(n - 1):
            if l != j:
                f *= a[j] - a[l]
        G.append([a[j] ** k / f for k in range(r)])
    G.append([Fr(int(k == r - 1)) for k in range(r)])

    def poly(roots):  # ascending coefficients of prod (x - root)
        c = [Fr(1)]
        for t in roots:
            c = [Fr(0)] + c
            for i in range(len(c) - 1):
                c[i] -= t * c[i + 1]
        return c

    BT = []
    for j in range(n - 1):
        c = poly([a[l] for l in range(n - 1) if l != j])
        BT.append(c + [Fr(0)] * (n - len(c)))
    c = poly(a)
    BT.append(c[:n])
    return AT, G, BT


def check(AT, G, BT, m, r):
    """The construction can come out mirrored; return matrices that compute
    the correlation exactly (float64 test), or None."""
    AT, G, BT = (np.array([[float(x) for x in row] for row in M]) for M in (AT, G, BT))
    rng = np.random.default_rng(0)
    d, g = rng.standard_normal(m + r - 1), rng.standard_normal(r)
    ref = np.array([sum(g[k] * d[i + k] for k in range(r)) for i in range(m)])
    for flip in itertools.product([False, True], repeat=3):
        A_, G_, B_ = AT, G, BT
        if flip[0]: A_ = A_[::-1, ::-1]
        if flip[1]: G_ = G_[:, ::-1]
        if flip[2]: B_ = B_.T
        y = A_ @ ((G_ @ g) * (B_ @ d))
        if np.allclose(y, ref, atol=1e-8 * np.abs(ref).max() * 1e3):
            return A_, G_, B_
    # try reversing roles (transpose formulation)
    y = AT @ ((G @ g[::-1]) * (BT @ d))
    if np.allclose(y, ref):
        return AT, G[:, ::-1] * 1, BT
    return None


def f16(x):
    return x.astype(np.float16).astype(np.float32)


def sim(M, m, r, C=128, T=2048, fold=4, seed=1):
    """SNR of the FP16 Winograd conv (C in -> 4 out channels) vs exact."""
    AT, G, BT = M
    n = m + r - 1
    rng = np.random.default_rng(seed)
    x = rng.standard_normal((C, T + r - 1)).astype(np.float32)
    w = (rng.standard_normal((4, C, r)) / np.sqrt(C * r)).astype(np.float32)
    ref = np.zeros((4, T))
    for k in range(r):
        ref += np.einsum('oc,ct->ot', w[:, :, k].astype(np.float64), x[:, k:k + T].astype(np.float64))
    tiles = T // m
    # input tiles: (C, tiles, n)
    idx = np.arange(tiles)[:, None] * m + np.arange(n)[None, :]
    D = x[:, idx]                                    # C, tiles, n
    V = f16(np.einsum('jn,ctn->ctj', BT.astype(np.float32), D))     # transformed input, fp16 storage
    U = f16(np.einsum('jk,ock->ocj', G.astype(np.float32), w))      # transformed weights, fp16
    acc = np.zeros((4, tiles, n), np.float32)
    for c0 in range(0, C, fold):
        part = np.zeros((4, tiles, n), np.float16)
        for c in range(c0, min(c0 + fold, C)):
            part = (part + (U[:, c, None, :].astype(np.float16) * V[None, c].astype(np.float16))).astype(np.float16)
        acc += part.astype(np.float32)
    Y = np.einsum('ij,otj->oti', AT.astype(np.float32), acc).reshape(4, -1)
    e = Y - ref[:, :tiles * m]
    return 10 * np.log10((ref[:, :tiles * m] ** 2).sum() / (e ** 2).sum())


def direct_sim(r, C=128, T=2048, fold=4, seed=1):
    rng = np.random.default_rng(seed)
    x = rng.standard_normal((C, T + r - 1)).astype(np.float32)
    w = (rng.standard_normal((4, C, r)) / np.sqrt(C * r)).astype(np.float32)
    ref = np.zeros((4, T))
    for k in range(r):
        ref += np.einsum('oc,ct->ot', w[:, :, k].astype(np.float64), x[:, k:k + T].astype(np.float64))
    acc = np.zeros((4, T), np.float32)
    xh, wh = f16(x).astype(np.float16), f16(w).astype(np.float16)
    for c0 in range(0, C, fold):
        part = np.zeros((4, T), np.float16)
        for c in range(c0, min(c0 + fold, C)):
            for k in range(r):
                part = (part + wh[:, c, k, None] * xh[c, None, k:k + T]).astype(np.float16)
        acc += part.astype(np.float32)
    e = acc - ref
    return 10 * np.log10((ref ** 2).sum() / (e ** 2).sum())


POINTS = {
    1: [], 2: [0], 3: [0, 1], 4: [0, 1, -1], 5: [0, 1, -1, 2], 6: [0, 1, -1, 2, -2], 7: [0, 1, -1, 2, -2, Fr(1, 2)],
    8: [0, 1, -1, 2, -2, Fr(1, 2), -Fr(1, 2)], 9: [0, 1, -1, 2, -2, Fr(1, 2), -Fr(1, 2), 3],
    10: [0, 1, -1, 2, -2, Fr(1, 2), -Fr(1, 2), 3, -3],
    11: [0, 1, -1, 2, -2, Fr(1, 2), -Fr(1, 2), 3, -3, Fr(1, 3)],
    12: [0, 1, -1, 2, -2, Fr(1, 2), -Fr(1, 2), 3, -3, Fr(1, 3), -Fr(1, 3)],
    13: [0, 1, -1, 2, -2, Fr(1, 2), -Fr(1, 2), 3, -3, Fr(1, 3), -Fr(1, 3), 4],
    14: [0, 1, -1, 2, -2, Fr(1, 2), -Fr(1, 2), 3, -3, Fr(1, 3), -Fr(1, 3), 4, -4],
    15: [0, 1, -1, 2, -2, Fr(1, 2), -Fr(1, 2), 3, -3, Fr(1, 3), -Fr(1, 3), 4, -4, Fr(1, 4)],
    16: [0, 1, -1, 2, -2, Fr(1, 2), -Fr(1, 2), 3, -3, Fr(1, 3), -Fr(1, 3), 4, -4, Fr(1, 4), -Fr(1, 4)],
}

if __name__ == '__main__':
    print('direct FP16 (fold 4): r3 %.1f dB, r7 %.1f dB, r11 %.1f dB' % (direct_sim(3), direct_sim(7), direct_sim(11)))
    print('%-8s %4s %8s %10s' % ('F(m,r)', 'n', 'MAC/out', 'SNR dB'))
    for r in (3, 7, 11):
        for m in (2, 3, 4, 5, 6):
            n = m + r - 1
            if n not in POINTS:
                continue
            M = check(*mats(m, r, POINTS[n]), m, r)
            if M is None:
                print('F(%d,%d) construction failed' % (m, r)); continue
            print('F(%d,%-2d)  %4d %8.2f %10.1f   (direct %d MAC/out: %.2fx fewer)' % (m, r, n, n / m, sim(M, m, r), r, r * m / n))
