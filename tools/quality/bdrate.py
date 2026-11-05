#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# bdrate.py results... : Bjontegaard delta rate (%) of every RD curve against the reference curve of the same codec
# family, from vmaf.sh lines "name frames kbps peak psnr_y psnr_avg ssim vmaf" with name
# <variant>_<codec>_<res>_<bits>_vbr<mbps>. Negative = fewer bits for the same quality.
#   bdrate.py [--ref h264=ref-x264,hevc=ref-x265,av1=ref-svt] files...
import sys, math, collections

def polyfit(x, y, deg):
    """least squares polynomial fit, coefficients highest power first (like numpy.polyfit)"""
    n = deg + 1
    A = [[sum(xi ** (i + j) for xi in x) for j in range(n)] for i in range(n)]
    b = [sum(yi * xi ** i for xi, yi in zip(x, y)) for i in range(n)]
    for c in range(n):                      # Gauss-Jordan with partial pivoting
        piv = max(range(c, n), key=lambda r: abs(A[r][c])); A[c], A[piv] = A[piv], A[c]; b[c], b[piv] = b[piv], b[c]
        for r in range(n):
            if r != c and A[c][c]:
                f = A[r][c] / A[c][c]
                A[r] = [a - f * ac for a, ac in zip(A[r], A[c])]; b[r] -= f * b[c]
    coef = [b[i] / A[i][i] for i in range(n)]   # low power first
    return coef[::-1]
def polyint(p):
    n = len(p); return [c / (n - i) for i, c in enumerate(p)] + [0.0]
def polyval(p, x):
    v = 0.0
    for c in p: v = v * x + c
    return v
class _np: pass
np = _np(); np.polyfit = polyfit; np.polyint = polyint; np.polyval = polyval; np.log = lambda a: [math.log(v) for v in a]

def bd_rate(r1, q1, r2, q2):
    """BD-rate of curve 2 against curve 1 (cubic fit of log rate over quality, Bjontegaard 2001)."""
    if len(r1) < 3 or len(r2) < 3: return float('nan')
    l1, l2 = np.log(r1), np.log(r2)
    p1, p2 = np.polyfit(q1, l1, 3 if len(q1) > 3 else 2), np.polyfit(q2, l2, 3 if len(q2) > 3 else 2)
    lo, hi = max(min(q1), min(q2)), min(max(q1), max(q2))
    if hi <= lo: return float('nan')
    i1, i2 = np.polyint(p1), np.polyint(p2)
    a1 = (np.polyval(i1, hi) - np.polyval(i1, lo)) / (hi - lo)
    a2 = (np.polyval(i2, hi) - np.polyval(i2, lo)) / (hi - lo)
    return (math.exp(a2 - a1) - 1) * 100

args = sys.argv[1:]
refs = {'h264': 'ref-x264', 'hevc': 'ref-x265', 'av1': 'ref-svt'}
if args and args[0] == '--ref':
    refs.update(dict(x.split('=') for x in args[1].split(','))); args = args[2:]
curves = collections.defaultdict(list)
for f in args:
    for line in open(f):
        p = line.split()
        if len(p) < 8 or '_' not in p[0] or p[4] == '-': continue
        n = p[0].split('_')
        var, codec, res, bits = n[0], n[1], n[2], n[3]
        curves[(var, codec, res, bits)].append((float(p[2]), float(p[4]), float(p[7])))
print('%-28s %-5s %-8s %5s  %9s %9s   %s' % ('variant', 'codec', 'res', 'bits', 'BD PSNR-Y', 'BD VMAF', 'points (kbps/PSNR/VMAF)'))
for (var, codec, res, bits), pts in sorted(curves.items()):
    pts.sort()
    suffix = '-' + var.rsplit('-', 1)[1] if var.rsplit('-', 1)[-1] in ('drive',) else ''
    ref = curves.get((refs.get(codec, '') + suffix, codec, res, bits))
    if ref: ref = sorted(ref)
    def bd(i):
        if not ref or var.startswith('ref-'): return float('nan')
        return bd_rate([x[0] for x in ref], [x[i] for x in ref], [x[0] for x in pts], [x[i] for x in pts])
    print('%-28s %-5s %-8s %5s  %8.1f%% %8.1f%%   %s' % (var, codec, res, bits, bd(1), bd(2),
          '  '.join('%d/%.2f/%.1f' % x for x in pts)))
