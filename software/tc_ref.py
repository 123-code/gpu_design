#!/usr/bin/env python3
"""Bit-exact reference for the tensor core (src/tensor_core.sv).

One MMA:  D (+)= A x B  on a 4x4 tile.
  A : 4 x K, row i = one 32-bit shared-memory word
  B : K x 4, stored K-major: column j = one 32-bit word
  D : 4 x 4 int32 in TMEM

Kinds (TCFG kind field):
  0  s8    int8 x int8, K = 4. D is a plain int32.
  1  e4m3  FP8 (1-4-3, bias 7), K = 4.
  2  e2m1  FP4 (1-2-1, bias 1), K = 8 (two per byte, low nibble first).
  3  mxf4  e2m1 with E8M0 block scales (OCP MX), K = 8.
  4  u8    A int8 x B uint8, K = 4 (weights x post-ReLU activations). Row i of A has
           scale byte sa[i] at A + 16 + i, column j of B has sb[j] at
           B + 16 + j; the block is one MMA's K.

For the float kinds, D holds a fixed-point value with D_FRAC = 8 fractional
bits (D = value * 256). Each (i, j) dot product over K is computed EXACTLY in
a wide integer, then lands in D with one arithmetic right shift (floor) if it
has more fractional bits than D. D always wraps mod 2^32. So the hardware and
this model agree bit for bit; the only rounding is that one documented floor.

Float decoding (no NaN/Inf: every code is a number, which is how OCP e2m1
works and how e4m3 is treated here, all-ones = 480):
  e4m3: value = M * 2^(E-9),  E = max(e,1)-1,  M = (e ? 8 : 0) + mant
  e2m1: value = M * 2^(E-1),  E = max(e,1)-1,  M = (e ? 2 : 0) + mant
Products of two such numbers are integers in units of 2^-18 (e4m3) or 2^-2
(e2m1).
"""
import random

D_FRAC = 8
KINDS = {"s8": 0, "e4m3": 1, "e2m1": 2, "mxf4": 3, "u8": 4}
K_OF = {0: 4, 1: 4, 2: 8, 3: 8, 4: 4}


def wrap32(x):
    x &= 0xFFFFFFFF
    return x - (1 << 32) if x & 0x80000000 else x


def s8(b):
    return b - 256 if b & 0x80 else b


def e4m3_parts(code):
    s, e, m = (code >> 7) & 1, (code >> 3) & 0xF, code & 7
    M = (8 if e else 0) + m
    E = max(e, 1) - 1
    return (-1 if s else 1), M, E


def e2m1_parts(code):
    s, e, m = (code >> 3) & 1, (code >> 1) & 3, code & 1
    M = (2 if e else 0) + m
    E = max(e, 1) - 1
    return (-1 if s else 1), M, E


def e4m3_value(code):
    sg, M, E = e4m3_parts(code)
    return sg * M * 2.0 ** (E - 9)


def e2m1_value(code):
    sg, M, E = e2m1_parts(code)
    return sg * M * 2.0 ** (E - 1)


def elems(word, kind):
    """The K operand codes packed in one 32-bit word."""
    if kind in (0, 1, 4):
        return [(word >> (8 * k)) & 0xFF for k in range(4)]
    return [(word >> (4 * k)) & 0xF for k in range(8)]


def dot_exact(arow, bcol, kind):
    """Exact dot product of one A row and one B column, as an integer in the
    kind's native unit (1 for s8, 2^-18 for e4m3, 2^-2 for e2m1/mxf4)."""
    a, b = elems(arow, kind), elems(bcol, kind)
    if kind == 0:
        return sum(s8(x) * s8(y) for x, y in zip(a, b))
    if kind == 4:
        return sum(s8(x) * y for x, y in zip(a, b))
    parts = e4m3_parts if kind == 1 else e2m1_parts
    tot = 0
    for x, y in zip(a, b):
        sa, ma, ea = parts(x)
        sb, mb, eb = parts(y)
        tot += sa * sb * ((ma * mb) << (ea + eb))
    return tot


MX_SHIFT_MIN, MX_SHIFT_MAX = -24, 24


def contribution(arow, bcol, kind, sa=127, sb=127):
    """What one (i, j) adds to D (an int, before the mod-2^32 wrap)."""
    d = dot_exact(arow, bcol, kind)
    if kind in (0, 4):
        return d
    if kind == 1:
        return d >> (18 - D_FRAC)            # floor into Q.8
    if kind == 2:
        return d << (D_FRAC - 2)             # exact
    sh = sa + sb - 254 + (D_FRAC - 2)        # E8M0: 2^(s-127) each
    sh = max(MX_SHIFT_MIN, min(MX_SHIFT_MAX, sh))
    return d << sh if sh >= 0 else d >> -sh


def mma(D, A, B, kind, accumulate, sa=None, sb=None):
    """D: 4x4 list of int32 (updated copy returned). A: 4 row words.
    B: 4 column words. sa/sb: 4 E8M0 bytes each (mxf4 only)."""
    sa = sa or [127] * 4
    sb = sb or [127] * 4
    out = [[0] * 4 for _ in range(4)]
    for i in range(4):
        for j in range(4):
            c = contribution(A[i], B[j], kind, sa[i], sb[j])
            out[i][j] = wrap32((D[i][j] if accumulate else 0) + c)
    return out


def tldq(d, shift):
    """TLDQ readout: clamp(D >>> shift, 0, 255) (requantize + ReLU)."""
    v = d >> shift
    return 0 if v < 0 else 255 if v > 255 else v


def pack(codes, kind):
    w = 0
    if kind in (0, 1, 4):
        for k, c in enumerate(codes):
            w |= (c & 0xFF) << (8 * k)
    else:
        for k, c in enumerate(codes):
            w |= (c & 0xF) << (4 * k)
    return w


def random_word(rng, kind):
    if kind in (0, 4):
        return pack([rng.randrange(256) for _ in range(4)], kind)
    if kind == 1:
        # bias toward moderate exponents so sums are not all floor-to-0
        return pack([rng.randrange(256) for _ in range(4)], kind)
    return pack([rng.randrange(16) for _ in range(8)], kind)


if __name__ == "__main__":
    # Self-check the float decoders against the format tables.
    assert [e2m1_value(c) for c in range(8)] == [0, 0.5, 1, 1.5, 2, 3, 4, 6]
    assert e4m3_value(0x7E) == 448 and e4m3_value(0x01) == 2.0 ** -9
    assert e4m3_value(0x38) == 1.0 and e4m3_value(0xB8) == -1.0
    rng = random.Random(0)
    for kind in (1, 2):
        val = e4m3_value if kind == 1 else e2m1_value
        unit = 2.0 ** -18 if kind == 1 else 0.25
        for _ in range(1000):
            a, b = random_word(rng, kind), random_word(rng, kind)
            exact = sum(val(x) * val(y) for x, y in zip(elems(a, kind), elems(b, kind)))
            assert dot_exact(a, b, kind) * unit == exact
    print("tc_ref self-check OK")
