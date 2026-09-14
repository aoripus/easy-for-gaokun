#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
#
# easy-for-gaokun -- Plymouth boot-splash mark generator.
#
# Renders an ORIGINAL, vendor-neutral geometric "G3" monogram inside a rounded
# square frame as a 512x512 RGBA PNG with a transparent background.
#
#   * no third-party library: the PNG is written by hand with zlib + struct
#   * no font is used: every stroke is an analytic geometric primitive, so the
#     rasterised result matches logo.svg exactly and cannot suffer from a
#     missing/broken font inside an initramfs
#   * antialiasing: the geometry is point-sampled on an ss x ss sub-grid per
#     pixel (default 4x4 = 16 samples/pixel) and divided back down
#
# Usage:
#     python3 make-logo.py
#     python3 make-logo.py --size 256 --ss 6
#     python3 make-logo.py --accent 4EC9B0 --mark FFFFFF --outdir /tmp/out
#
# The single source of truth for the geometry is the block of constants below;
# logo.svg is the human-editable vector master of exactly the same shapes.
#
# This file is intentionally pure ASCII.

import argparse
import hashlib
import math
import os
import struct
import sys
import zlib

# --------------------------------------------------------------------------
# Design canvas.  Every coordinate below lives in a 512 x 512 space; --size
# only changes the output resolution, never the proportions.
# --------------------------------------------------------------------------
DESIGN = 512.0
CX = DESIGN / 2.0                      # 256.0 -- canvas centre
CY = DESIGN / 2.0

# Outer frame: a stroked rounded square given by its *centreline*.
FRAME_HALF = 190.0                     # centreline half extent -> 66 .. 446
FRAME_RADIUS = 78.0                    # centreline corner radius
FRAME_STROKE = 28.0                    # -> outer 52..460 (r=92), hole 80..432 (r=64)

# "G": an open ring plus a horizontal bar running from the centre to the
# outer edge (the bar sits in the ring's opening, at 3 o'clock).
G_CX = 189.0
G_CY = CY
G_R = 70.0                             # centreline radius
G_STROKE = 30.0                        # -> outer radius 85, inner radius 55
G_GAP_DEG = 34.0                       # half opening, centred on 3 o'clock
G_BAR_X0 = G_CX                        # bar starts at the ring centre
G_BAR_X1 = G_CX + G_R + G_STROKE / 2.0  # 274.0 -- flush with the outer radius

# "3": two stacked circular arcs, each sweeping 250 degrees, meeting at the
# waist.  This yields a 96.98 x 170.0 digit -- the same height as the "G".
T3_AX = 358.0                          # x of both arc centres
T3_AY = CY
T3_R = 35.0                            # centreline radius of each arc
T3_STROKE = 30.0
T3_TOP_A0, T3_TOP_A1 = -160.0, 90.0    # degrees, screen space (y grows down)
T3_BOT_A0, T3_BOT_A1 = -90.0, 160.0

DEFAULT_ACCENT = '4EC9B0'              # teal -- the frame
DEFAULT_MARK = 'FFFFFF'                # white -- the monogram


# --------------------------------------------------------------------------
# Rasteriser
# --------------------------------------------------------------------------
def _bounds(lo, hi, step, n):
    """Pixel index range that can possibly cover the design-space span."""
    i0 = int(math.floor(lo / step))
    i1 = int(math.ceil(hi / step))
    if i0 < 0:
        i0 = 0
    if i1 > n:
        i1 = n
    return i0, i1


def _raster_rounded_ring(cov, size, ss, step, ccx, ccy, half, radius, stroke):
    """Stroked rounded square centred on (ccx, ccy) -- the outer frame."""
    oh = half + stroke * 0.5
    ih = half - stroke * 0.5
    orr = radius + stroke * 0.5
    irr = radius - stroke * 0.5
    if irr < 0.0:
        irr = 0.0
    olo, ohi = -oh + orr, oh - orr
    ilo, ihi = -ih + irr, ih - irr
    orr2 = orr * orr
    irr2 = irr * irr
    inv = 1.0 / (ss * ss)
    sub = step / ss
    i0, i1 = _bounds(ccx - oh, ccx + oh, step, size)
    j0, j1 = _bounds(ccy - oh, ccy + oh, step, size)
    for j in range(j0, j1):
        row = j * size
        yb = j * step - ccy
        for b in range(ss):
            py = yb + (b + 0.5) * sub
            oyc = olo if py < olo else (ohi if py > ohi else py)
            oy2 = (py - oyc) * (py - oyc)
            iyc = ilo if py < ilo else (ihi if py > ihi else py)
            iy2 = (py - iyc) * (py - iyc)
            for i in range(i0, i1):
                xb = i * step - ccx
                acc = 0.0
                for a in range(ss):
                    px = xb + (a + 0.5) * sub
                    oxc = olo if px < olo else (ohi if px > ohi else px)
                    dx = px - oxc
                    if dx * dx + oy2 > orr2:
                        continue
                    ixc = ilo if px < ilo else (ihi if px > ihi else px)
                    dx = px - ixc
                    if dx * dx + iy2 <= irr2:
                        continue
                    acc += inv
                if acc:
                    cov[row + i] += acc


def _raster_disc_ring(cov, size, ss, step, ccx, ccy, ro, ri, gap_tan):
    """Open circular ring: |r-R| <= strokewidth/2, minus a wedge on +x.

    gap_tan is None for a full ring, otherwise tan(half opening angle) and the
    wedge |dy| < dx*tan is removed for dx > 0.
    """
    ro2 = ro * ro
    ri2 = ri * ri
    inv = 1.0 / (ss * ss)
    sub = step / ss
    i0, i1 = _bounds(ccx - ro, ccx + ro, step, size)
    j0, j1 = _bounds(ccy - ro, ccy + ro, step, size)
    for j in range(j0, j1):
        row = j * size
        yb = j * step - ccy
        for b in range(ss):
            dy = yb + (b + 0.5) * sub
            dy2 = dy * dy
            ady = -dy if dy < 0.0 else dy
            for i in range(i0, i1):
                xb = i * step - ccx
                acc = 0.0
                for a in range(ss):
                    dx = xb + (a + 0.5) * sub
                    d2 = dx * dx + dy2
                    if d2 > ro2 or d2 < ri2:
                        continue
                    if gap_tan is not None and dx > 0.0 and ady < dx * gap_tan:
                        continue
                    acc += inv
                if acc:
                    cov[row + i] += acc


def _raster_rect(cov, size, ss, step, x0, x1, y0, y1):
    """Axis-aligned filled rectangle."""
    inv = 1.0 / (ss * ss)
    sub = step / ss
    i0, i1 = _bounds(x0, x1, step, size)
    j0, j1 = _bounds(y0, y1, step, size)
    for j in range(j0, j1):
        row = j * size
        yb = j * step
        for b in range(ss):
            py = yb + (b + 0.5) * sub
            if py < y0 or py > y1:
                continue
            for i in range(i0, i1):
                xb = i * step
                acc = 0.0
                for a in range(ss):
                    px = xb + (a + 0.5) * sub
                    if x0 <= px <= x1:
                        acc += inv
                if acc:
                    cov[row + i] += acc


def _raster_arc(cov, size, ss, step, ccx, ccy, radius, stroke, a0, a1):
    """Circular ring restricted to a sweep [a0, a1] in degrees (y grows down)."""
    ro = radius + stroke * 0.5
    ri = radius - stroke * 0.5
    ro2 = ro * ro
    ri2 = ri * ri
    span = a1 - a0
    inv = 1.0 / (ss * ss)
    sub = step / ss
    i0, i1 = _bounds(ccx - ro, ccx + ro, step, size)
    j0, j1 = _bounds(ccy - ro, ccy + ro, step, size)
    for j in range(j0, j1):
        row = j * size
        yb = j * step - ccy
        for b in range(ss):
            dy = yb + (b + 0.5) * sub
            dy2 = dy * dy
            for i in range(i0, i1):
                xb = i * step - ccx
                acc = 0.0
                for a in range(ss):
                    dx = xb + (a + 0.5) * sub
                    d2 = dx * dx + dy2
                    if d2 > ro2 or d2 < ri2:
                        continue
                    ang = math.degrees(math.atan2(dy, dx))
                    if (ang - a0) % 360.0 <= span:
                        acc += inv
                if acc:
                    cov[row + i] += acc


# --------------------------------------------------------------------------
# Compositing + PNG
# --------------------------------------------------------------------------
def _u8(v):
    """Clamp a 0..255 float colour component to a byte."""
    if v <= 0.0:
        return 0
    if v >= 255.0:
        return 255
    return int(v + 0.5)


def _a8(v):
    """Clamp a 0..1 float alpha to a byte."""
    if v <= 0.0:
        return 0
    if v >= 1.0:
        return 255
    return int(v * 255.0 + 0.5)


def _composite(cov_accent, cov_mark, accent, mark, n):
    """Source-over compositing of both coverage layers onto transparency."""
    out = bytearray(n * 4)
    ar, ag, ab = accent
    mr, mg, mb = mark
    for k in range(n):
        fa = cov_accent[k]
        fm = cov_mark[k]
        if fa == 0.0 and fm == 0.0:
            continue
        a = fa
        r, g, b = ar, ag, ab
        if fm > 0.0:
            na = fm + a * (1.0 - fm)
            if na > 0.0:
                w1 = fm / na
                w2 = (a * (1.0 - fm)) / na
                r = mr * w1 + r * w2
                g = mg * w1 + g * w2
                b = mb * w1 + b * w2
            a = na
        o = k * 4
        out[o] = _u8(r)
        out[o + 1] = _u8(g)
        out[o + 2] = _u8(b)
        out[o + 3] = _a8(a)
    return out


def _png_encode(rgba, w, h, level=9):
    """Encode straight-alpha RGBA8 pixels as a PNG (filter type 0 per row)."""
    stride = w * 4
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += rgba[y * stride:(y + 1) * stride]

    def chunk(tag, payload):
        return (struct.pack('>I', len(payload)) + tag + payload +
                struct.pack('>I', zlib.crc32(tag + payload) & 0xFFFFFFFF))

    ihdr = struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n' +
            chunk(b'IHDR', ihdr) +
            chunk(b'IDAT', zlib.compress(bytes(raw), level)) +
            chunk(b'IEND', b''))


def _png_decode(data):
    """Independent read-back: verify CRCs, inflate and unfilter the image."""
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('not a PNG file')
    pos = 8
    idat = bytearray()
    info = {}
    seen = []
    while pos < len(data):
        if pos + 12 > len(data):
            raise ValueError('truncated chunk header')
        ln = struct.unpack('>I', data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + ln]
        crc = struct.unpack('>I', data[pos + 8 + ln:pos + 12 + ln])[0]
        if zlib.crc32(tag + payload) & 0xFFFFFFFF != crc:
            raise ValueError('bad CRC in %r' % tag)
        seen.append(tag.decode('ascii'))
        if tag == b'IHDR':
            (info['w'], info['h'], info['depth'], info['ctype'],
             comp, filt, info['interlace']) = struct.unpack('>IIBBBBB', payload)
            if comp != 0 or filt != 0:
                raise ValueError('unsupported compression/filter method')
        elif tag == b'IDAT':
            idat += payload
        pos += 12 + ln
    if seen[-1] != 'IEND':
        raise ValueError('missing IEND')
    w, h, depth, ctype = info['w'], info['h'], info['depth'], info['ctype']
    if depth != 8 or ctype != 6:
        raise ValueError('expected 8-bit RGBA (color type 6)')
    bpp = 4
    stride = w * bpp
    raw = zlib.decompress(bytes(idat))
    if len(raw) != h * (stride + 1):
        raise ValueError('unexpected IDAT payload size')
    out = bytearray(h * stride)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        ft = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if ft == 0:
            pass
        elif ft == 1:
            for x in range(bpp, stride):
                line[x] = (line[x] + line[x - bpp]) & 0xFF
        elif ft == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 0xFF
        elif ft == 3:
            for x in range(stride):
                left = line[x - bpp] if x >= bpp else 0
                line[x] = (line[x] + ((left + prev[x]) >> 1)) & 0xFF
        elif ft == 4:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                pp = a + b - c
                pa = pp - a
                pb = pp - b
                pc = pp - c
                if pa < 0:
                    pa = -pa
                if pb < 0:
                    pb = -pb
                if pc < 0:
                    pc = -pc
                if pa <= pb and pa <= pc:
                    pr = a
                elif pb <= pc:
                    pr = b
                else:
                    pr = c
                line[x] = (line[x] + pr) & 0xFF
        else:
            raise ValueError('unsupported filter type %d' % ft)
        out[y * stride:(y + 1) * stride] = line
        prev = line
    info['pixels'] = out
    info['chunks'] = seen
    return info


def _rotate_cw(src, n, quarter_turns):
    """Rotate an n x n RGBA8 buffer clockwise by quarter_turns (1 or 3)."""
    dst = bytearray(len(src))
    if quarter_turns % 4 == 1:
        for sy in range(n):
            srow = sy * n
            for sx in range(n):
                si = (srow + sx) * 4
                di = (sx * n + (n - 1 - sy)) * 4
                dst[di:di + 4] = src[si:si + 4]
    else:
        for sy in range(n):
            srow = sy * n
            for sx in range(n):
                si = (srow + sx) * 4
                di = ((n - 1 - sx) * n + sy) * 4
                dst[di:di + 4] = src[si:si + 4]
    return dst


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------
def _parse_hex(text, what):
    t = text.strip().lstrip('#')
    if len(t) == 3:
        t = t[0] * 2 + t[1] * 2 + t[2] * 2
    if len(t) != 6:
        raise SystemExit('%s must be RRGGBB, got %r' % (what, text))
    try:
        return tuple(int(t[i:i + 2], 16) for i in (0, 2, 4))
    except ValueError:
        raise SystemExit('%s must be RRGGBB, got %r' % (what, text))


def render(size, ss, accent, mark):
    n = size * size
    step = DESIGN / size
    cov_accent = [0.0] * n
    cov_mark = [0.0] * n

    # teal layer: the outer frame
    _raster_rounded_ring(cov_accent, size, ss, step,
                         CX, CY, FRAME_HALF, FRAME_RADIUS, FRAME_STROKE)
    # white layer: "G" ring, "G" bar, then the two arcs of the "3"
    _raster_disc_ring(cov_mark, size, ss, step,
                      G_CX, G_CY,
                      G_R + G_STROKE * 0.5, G_R - G_STROKE * 0.5,
                      math.tan(math.radians(G_GAP_DEG)))
    _raster_rect(cov_mark, size, ss, step,
                 G_BAR_X0, G_BAR_X1,
                 G_CY - G_STROKE * 0.5, G_CY + G_STROKE * 0.5)
    _raster_arc(cov_mark, size, ss, step, T3_AX, T3_AY - T3_R,
                T3_R, T3_STROKE, T3_TOP_A0, T3_TOP_A1)
    _raster_arc(cov_mark, size, ss, step, T3_AX, T3_AY + T3_R,
                T3_R, T3_STROKE, T3_BOT_A0, T3_BOT_A1)

    return _composite(cov_accent, cov_mark, accent, mark, n)


def _stats(info):
    px = info['pixels']
    n = info['w'] * info['h']
    opaque = 0
    any_alpha = 0
    total = 0
    for k in range(n):
        a = px[k * 4 + 3]
        if a:
            any_alpha += 1
            total += a
            if a == 255:
                opaque += 1
    return {
        'pixels': n,
        'any_alpha': any_alpha,
        'opaque': opaque,
        'mean_alpha': (total / float(n * 255)) if n else 0.0,
    }


def _report(path, label):
    with open(path, 'rb') as fh:
        data = fh.read()
    info = _png_decode(data)
    st = _stats(info)
    print('  %-22s %dx%d RGBA depth=%d interlace=%d  %8d bytes'
          % (label, info['w'], info['h'], info['depth'], info['interlace'],
             len(data)))
    print('  %-22s sha256 %s' % ('', hashlib.sha256(data).hexdigest()))
    print('  %-22s alpha>0 %d px (%.2f%%), fully opaque %d px (%.2f%%), '
          'mean alpha %.4f'
          % ('', st['any_alpha'], 100.0 * st['any_alpha'] / st['pixels'],
             st['opaque'], 100.0 * st['opaque'] / st['pixels'],
             st['mean_alpha']))
    return info


def main(argv=None):
    ap = argparse.ArgumentParser(
        description='Render the easy-for-gaokun Plymouth splash mark (RGBA PNG).')
    ap.add_argument('--size', type=int, default=512,
                    help='output edge length in pixels (default 512)')
    ap.add_argument('--ss', type=int, default=4,
                    help='supersampling factor per axis (default 4 -> 16 samples/px)')
    ap.add_argument('--outdir', default=None,
                    help='output directory (default: the directory of this script)')
    ap.add_argument('--accent', default=DEFAULT_ACCENT,
                    help='frame colour RRGGBB (default %s)' % DEFAULT_ACCENT)
    ap.add_argument('--mark', default=DEFAULT_MARK,
                    help='monogram colour RRGGBB (default %s)' % DEFAULT_MARK)
    ap.add_argument('--no-rotate', action='store_true',
                    help='do not emit the rot90/rot270 variants')
    args = ap.parse_args(argv)

    if args.size < 16 or args.size > 4096:
        raise SystemExit('--size must be within 16..4096')
    if args.ss < 1 or args.ss > 16:
        raise SystemExit('--ss must be within 1..16')

    accent = _parse_hex(args.accent, '--accent')
    mark = _parse_hex(args.mark, '--mark')
    outdir = args.outdir or os.path.dirname(os.path.abspath(__file__))
    if outdir and not os.path.isdir(outdir):
        os.makedirs(outdir)

    print('easy-for-gaokun splash mark')
    print('  canvas     : %gx%g design units -> %d px, %dx%d supersampling '
          '(%d samples/px)' % (DESIGN, DESIGN, args.size, args.ss, args.ss,
                               args.ss * args.ss))
    print('  colours    : frame #%02X%02X%02X, monogram #%02X%02X%02X'
          % (accent + mark))

    rgba = render(args.size, args.ss, accent, mark)
    png = _png_encode(rgba, args.size, args.size)

    outs = []
    main_path = os.path.join(outdir, 'logo.png')
    with open(main_path, 'wb') as fh:
        fh.write(png)
    outs.append((main_path, 'logo.png'))

    if not args.no_rotate:
        for turns, name in ((1, 'logo-rot90.png'), (3, 'logo-rot270.png')):
            rot = _rotate_cw(rgba, args.size, turns)
            p = os.path.join(outdir, name)
            with open(p, 'wb') as fh:
                fh.write(_png_encode(rot, args.size, args.size))
            outs.append((p, name))

    print('  wrote      :')
    for path, label in outs:
        print('  %s' % path)
        _report(path, label)

    print('  self-check : header, CRC32, IDAT inflate and unfilter all OK')
    return 0


if __name__ == '__main__':
    sys.exit(main())
