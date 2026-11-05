#!/usr/bin/env python3
"""What Intel's own Linux media stack (intel/media-driver, VA-API) offers per platform: data/caps.json.

Reads a checkout of github.com/intel/media-driver and records, for each platform this driver targets, every codec x
direction it exposes with profiles, bit depths, chroma formats and the largest picture, each with the source line.

Two kinds of platform code exist upstream, and both are read as written (no estimates, nothing filled in by hand):
- "capstable" (media_softlet/linux/<ip>_r0: MTL/ARL, LNL, BMG, PTL): the ProfileMap of the platform's
  capstable_data_<ip>_specific.h lists each VA profile with its entrypoints; each entrypoint's AttribList (in the codec's
  capstable_data_<codec>_<dir>_<ip>_specific.h) gives VAConfigAttribRTFormat (-> bit depth, chroma) and
  VAConfigAttribMaxPictureWidth/Height.
- "sku" (media_driver/linux, Gen12 TGL/RKL/ADL/RPL/DG1 and DG2): the legacy caps code exposes a VA profile when its media
  feature flag is set; the flags are set by the platform's Init<...>MediaSku function (MEDIA_WR_SKU, LinuxCodecInfo
  fields for the codec switches). The functions are walked in order, including the base function they call; values
  under SET_STATUS_BY_FULL_OPEN_SOURCE(a, b) take a (the default build: ENABLE_KERNELS and ENABLE_NONFREE_KERNELS on).
  The legacy code computes the largest picture in C++ per profile; it is not extracted (max = null).
Device IDs per platform come from the RegisterDevice(0x...) calls of media-driver's media_sysinfo_*.cpp.

  tools/parity/caps.py --media-driver /path/media-driver [--out data/caps.json]

Python stdlib only.
"""
import argparse, json, os, re, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Our platform ids -> media-driver code. 'ids' = (sysinfo file, GfxDeviceInfo variable names).
PLATFORMS = [
    {'id': 'bmg', 'name': 'Battlemage (Arc B580/B570)', 'model': 'capstable', 'dir': 'media_softlet/linux/xe2_hpm_r0',
     'ip': 'xe2_hpm_r0', 'ids': ('media_softlet/linux/xe2_hpm/ddi/media_sysinfo_bmg.cpp', ['bmgInfo'])},
    {'id': 'lnl', 'name': 'Lunar Lake', 'model': 'capstable', 'dir': 'media_softlet/linux/xe2_lpm_r0', 'ip': 'xe2_lpm_r0',
     'ids': ('media_softlet/linux/xe2_lpm/ddi/media_sysinfo_lnl.cpp', ['lnlInfo'])},
    {'id': 'ptl', 'name': 'Panther Lake', 'model': 'capstable', 'dir': 'media_softlet/linux/xe3_lpm_r0', 'ip': 'xe3_lpm_r0',
     'ids': ('media_softlet/linux/xe3_lpm/ddi/media_sysinfo_ptl.cpp', ['ptlInfo'])},
    {'id': 'mtl', 'name': 'Meteor Lake / Arrow Lake', 'model': 'capstable', 'dir': 'media_softlet/linux/xe_lpm_plus_r0',
     'ip': 'xe_lpm_plus_r0', 'ids': ('media_softlet/linux/Xe_M_plus/ddi/media_sysinfo_mtl.cpp', ['mtlInfo', 'arlInfo'])},
    {'id': 'dg2', 'name': 'Alchemist (DG2)', 'model': 'sku', 'file': 'media_driver/linux/Xe_M/ddi/media_sku_wa_xe.cpp',
     'init': 'InitDg2MediaSku', 'ids': ('media_driver/linux/Xe_M/ddi/media_sysinfo_xe.cpp', ['dg2Gt4Info'])},
    {'id': 'tgl', 'name': 'Tiger Lake', 'model': 'sku', 'file': 'media_driver/linux/gen12/ddi/media_sku_wa_g12.cpp',
     'init': 'InitTglMediaSku', 'ids': ('media_driver/linux/gen12/ddi/media_sysinfo_g12.cpp', ['tgllpGt1Info', 'tgllpGt2Info'])},
    {'id': 'rkl', 'name': 'Rocket Lake', 'model': 'sku', 'file': 'media_driver/linux/gen12/ddi/media_sku_wa_g12.cpp',
     'init': 'InitRKLMediaSku', 'ids': ('media_driver/linux/gen12/ddi/media_sysinfo_g12.cpp', ['rklGt1Info', 'rklGt1fInfo'])},
    {'id': 'adls', 'name': 'Alder Lake-S / Raptor Lake-S', 'model': 'sku', 'file': 'media_driver/linux/gen12/ddi/media_sku_wa_g12.cpp',
     'init': 'InitAdlsMediaSku', 'ids': ('media_driver/linux/gen12/ddi/media_sysinfo_g12.cpp', ['adlsGt1Info', 'adlsGt1fInfo'])},
    {'id': 'adlp', 'name': 'Alder Lake-P / Raptor Lake-P/U', 'model': 'sku', 'file': 'media_driver/linux/gen12/ddi/media_sku_wa_g12.cpp',
     'init': 'InitAdlpMediaSku', 'ids': ('media_driver/linux/gen12/ddi/media_sysinfo_g12.cpp', ['adlpGt2Info'])},
    {'id': 'adln', 'name': 'Alder Lake-N', 'model': 'sku', 'file': 'media_driver/linux/gen12/ddi/media_sku_wa_g12.cpp',
     'init': 'InitAdlnMediaSku', 'ids': ('media_driver/linux/gen12/ddi/media_sysinfo_g12.cpp', ['adlnGt1Info'])},
    {'id': 'dg1', 'name': 'DG1', 'model': 'sku', 'file': 'media_driver/linux/gen12/ddi/media_sku_wa_g12.cpp',
     'init': 'InitDG1MediaSku', 'ids': ('media_driver/linux/gen12/ddi/media_sysinfo_g12.cpp', ['dg1Gt2Info'])},
]

CODEC_OF = [('VAProfileH264', 'h264'), ('VAProfileHEVC', 'hevc'), ('VAProfileVP9', 'vp9'), ('VAProfileAV1', 'av1'),
            ('VAProfileVP8', 'vp8'), ('VAProfileMPEG2', 'mpeg2'), ('VAProfileJPEG', 'jpeg'), ('VAProfileVVC', 'vvc'),
            ('VAProfileVC1', 'vc1')]
DIR_OF = {'VAEntrypointVLD': 'decode', 'VAEntrypointEncSlice': 'encode', 'VAEntrypointEncSliceLP': 'encode',
          'VAEntrypointEncPicture': 'encode', 'VAEntrypointFEI': 'encode'}
# VA_RT_FORMAT_* -> (bits, chroma); RGB formats are encoder inputs, not coded formats, and are left out
RT = {'YUV420': (8, '420'), 'YUV420_10': (10, '420'), 'YUV420_10BPP': (10, '420'), 'YUV420_12': (12, '420'),
      'YUV422': (8, '422'), 'YUV422_10': (10, '422'), 'YUV422_12': (12, '422'), 'YUV444': (8, '444'),
      'YUV444_10': (10, '444'), 'YUV444_12': (12, '444'), 'YUV400': (8, '400'), 'YUV411': (8, '411')}
# legacy media feature flags -> (codec, dir, bits, chroma)
FTR = {
    'FtrAVCVLDLongDecoding': ('h264', 'decode', 8, '420'),
    'FtrIntelHEVCVLDMainDecoding': ('hevc', 'decode', 8, '420'), 'FtrIntelHEVCVLDMain10Decoding': ('hevc', 'decode', 10, '420'),
    'FtrIntelHEVCVLD42210bitDecoding': ('hevc', 'decode', 10, '422'), 'FtrIntelHEVCVLD4448bitDecoding': ('hevc', 'decode', 8, '444'),
    'FtrIntelHEVCVLD44410bitDecoding': ('hevc', 'decode', 10, '444'), 'FtrIntelHEVCVLDMain12bit420Decoding': ('hevc', 'decode', 12, '420'),
    'FtrIntelHEVCVLDMain12bit422Decoding': ('hevc', 'decode', 12, '422'), 'FtrIntelHEVCVLDMain12bit444Decoding': ('hevc', 'decode', 12, '444'),
    'FtrIntelVP9VLDProfile0Decoding8bit420': ('vp9', 'decode', 8, '420'), 'FtrIntelVP9VLDProfile2Decoding': ('vp9', 'decode', 10, '420'),
    'FtrIntelVP9VLDProfile1Decoding8bit444': ('vp9', 'decode', 8, '444'), 'FtrIntelVP9VLDProfile3Decoding10bit444': ('vp9', 'decode', 10, '444'),
    'FtrIntelVP9VLDProfile2Decoding12bit420': ('vp9', 'decode', 12, '420'), 'FtrIntelVP9VLDProfile3Decoding12bit444': ('vp9', 'decode', 12, '444'),
    'FtrIntelAV1VLDDecoding8bit420': ('av1', 'decode', 8, '420'), 'FtrIntelAV1VLDDecoding10bit420': ('av1', 'decode', 10, '420'),
    'FtrIntelVP8VLDDecoding': ('vp8', 'decode', 8, '420'), 'FtrMPEG2VLDDecoding': ('mpeg2', 'decode', 8, '420'),
    'FtrIntelJPEGDecoding': ('jpeg', 'decode', 8, None), 'FtrVC1VLDDecoding': ('vc1', 'decode', 8, '420'),
    'FtrEncodeAVC': ('h264', 'encode', 8, '420'), 'FtrEncodeAVCVdenc': ('h264', 'encode', 8, '420'),
    'FtrEncodeHEVC': ('hevc', 'encode', 8, '420'), 'FtrEncodeHEVC10bit': ('hevc', 'encode', 10, '420'),
    'FtrEncodeHEVCVdencMain': ('hevc', 'encode', 8, '420'), 'FtrEncodeHEVCVdencMain10': ('hevc', 'encode', 10, '420'),
    'FtrEncodeHEVCVdencMain444': ('hevc', 'encode', 8, '444'), 'FtrEncodeHEVCVdencMain10bit444': ('hevc', 'encode', 10, '444'),
    'FtrEncodeHEVCVdencMain422': ('hevc', 'encode', 8, '422'), 'FtrEncodeHEVCVdencMain10bit422': ('hevc', 'encode', 10, '422'),
    'FtrEncodeVP9Vdenc': ('vp9', 'encode', 8, '420'), 'FtrEncodeVP9Vdenc10bit420': ('vp9', 'encode', 10, '420'),
    'FtrEncodeVP9Vdenc8bit444': ('vp9', 'encode', 8, '444'), 'FtrEncodeVP9Vdenc10bit444': ('vp9', 'encode', 10, '444'),
    'FtrEncodeAV1Vdenc': ('av1', 'encode', 8, '420'), 'FtrEncodeAV1Vdenc10bit420': ('av1', 'encode', 10, '420'),
    'FtrEncodeVP8': ('vp8', 'encode', 8, '420'), 'FtrEncodeMPEG2': ('mpeg2', 'encode', 8, '420'), 'FtrEncodeJPEG': ('jpeg', 'encode', 8, None),
}


def strip_comments(s):
    s = re.sub(r'/\*.*?\*/', lambda m: '\n' * m.group(0).count('\n'), s, flags=re.S)
    return re.sub(r'//[^\n]*', '', s)


def blocks(path, kind):
    """{name: (body, line)} of every top-level `[static] [const] <kind> name [=] { ... };` in a file."""
    s = strip_comments(open(path, errors='replace').read())
    out = {}
    for m in re.finditer(r'(?:static\s+)?(?:const\s+)?%s\s+(\w+)\s*=?\s*\{' % kind, s):
        i, depth = m.end(), 1
        while depth and i < len(s):
            depth += {'{': 1, '}': -1}.get(s[i], 0)
            i += 1
        out[m.group(1)] = (s[m.end():i - 1], s.count('\n', 0, m.start()) + 1)
    return out


def constants(md):
    c = {}
    for rel in ('media_common/agnostic/common/codec/shared/codec_def_common.h',
                'media_common/agnostic/common/codec/shared/codec_def_decode_vvc.h',
                'media_common/agnostic/common/codec/shared/codec_def_encode_jpeg.h'):
        p = os.path.join(md, rel)
        if os.path.exists(p):
            for m in re.finditer(r'#define\s+(\w+)\s+(\d+)', open(p, errors='replace').read()):
                c[m.group(1)] = int(m.group(2))
    return c


def capstable(md, plat, consts):
    d = os.path.join(md, plat['dir'])
    files = [os.path.join(r, f) for r, _, fs in os.walk(d) for f in fs if f.startswith('capstable_data_') and f.endswith('.h')]
    top = [f for f in files if os.path.basename(f) == 'capstable_data_%s_specific.h' % plat['ip']][0]
    attribs, eps = {}, {}
    for f in files:
        for n, (b, l) in blocks(f, 'AttribList').items():
            attribs[n] = (b, os.path.relpath(f, md), l)
        for n, (b, l) in blocks(f, 'EntrypointData').items():
            eps[n] = (b, os.path.relpath(f, md), l)
    emaps = blocks(top, 'EntrypointMap')
    pmap = blocks(top, 'ProfileMap')
    # the base table; an "_ext" table (another media IP stepping, IP_VERSION_<..>_EXT) only adds profiles, listed apart
    base = [n for n in pmap if '_ext' not in n.lower()]
    assert len(base) == 1, 'one base ProfileMap in %s: %s' % (top, list(pmap))
    pbody, _ = pmap[base[0]]
    ext = {}
    for n, (b, _) in pmap.items():
        if n != base[0]:
            extra = sorted(set(re.findall(r'VAProfile(\w+)\s*\)?\s*,', b)) - set(re.findall(r'VAProfile(\w+)\s*\)?\s*,', pbody)))
            if extra:
                ext[n] = extra
    entries = []
    for prof, emap in re.findall(r'\{\s*(?:\(VAProfile\))?(VAProfile\w+)\s*,\s*&(\w+)\s*\}', pbody):
        codec = next((c for pre, c in CODEC_OF if prof.startswith(pre)), None)
        if not codec:
            continue
        for ep, data in re.findall(r'\{\s*(VAEntrypoint\w+)\s*,\s*&(\w+)\s*\}', emaps[emap][0]):
            if ep not in DIR_OF or data not in eps:
                continue
            al = re.search(r'&(\w+)', eps[data][0]).group(1)
            ab, af, alin = attribs[al]
            rt = re.search(r'VAConfigAttribRTFormat\s*,\s*([^}]+)\}', ab)
            fmts = [t for t in re.findall(r'VA_RT_FORMAT_(\w+)', rt.group(1))] if rt else []
            wv = re.search(r'VAConfigAttribMaxPictureWidth\s*,\s*(\w+)', ab)
            hv = re.search(r'VAConfigAttribMaxPictureHeight\s*,\s*(\w+)', ab)
            entries.append({'codec': codec, 'dir': DIR_OF[ep], 'profile': prof[len('VAProfile'):], 'entrypoint': ep[len('VAEntrypoint'):],
                            'formats': fmts, 'coded': sorted({RT[f] for f in fmts if f in RT}),
                            'max_w': consts.get(wv.group(1)) if wv else None, 'max_h': consts.get(hv.group(1)) if hv else None,
                            'src': '%s:%d' % (af, alin)})
    return entries, os.path.relpath(top, md), ext


def sku(md, plat):
    path = os.path.join(md, plat['file'])
    raw = strip_comments(open(path, errors='replace').read())
    infos = {n: {k: v.rstrip(', ') for k, v in re.findall(r'\.(\w+)\s*=\s*(.+?)\s*$', b, re.M)}
             for n, (b, _) in blocks(path, 'struct LinuxCodecInfo').items()}

    def val(v, ci):
        v = v.strip()
        m = re.match(r'SET_STATUS_BY_FULL_OPEN_SOURCE\((\w+)\s*,\s*(\w+)\)', v)
        if m:
            v = m.group(1)
        if re.match(r'^\d+$', v):
            return int(v)
        m = re.match(r'codecInfo->(\w+)$', v)
        if m and ci and m.group(1) in ci:
            return val(ci[m.group(1)], None)
        return None

    def func(name):
        m = re.search(r'static bool %s\s*\([^)]*\)\s*\{' % name, raw)
        i, depth = m.end(), 1
        while depth:
            depth += {'{': 1, '}': -1}.get(raw[i], 0)
            i += 1
        return raw[m.end():i - 1], raw.count('\n', 0, m.start()) + 1

    flags = {}

    def walk(name, ci):
        body, line0 = func(name)
        local = re.search(r'LinuxCodecInfo\s*\*\s*codecInfo\s*=\s*&(\w+)', body)
        if local:
            ci = infos[local.group(1)]
        for m in re.finditer(r'(InitTglMediaSku(?:Ext)?)\s*\(([^;]*)\)|MEDIA_WR_SKU\(\s*skuTable\s*,\s*(\w+)\s*,\s*([^;]+?)\)\s*;', body):
            if m.group(1) and m.group(1) != name:
                arg = re.search(r'&(\w+CodecInfo)', m.group(2))
                walk(m.group(1), infos[arg.group(1)] if arg else ci)
            elif m.group(3):
                flags[m.group(3)] = (val(m.group(4), ci), '%s:%d' % (plat['file'], line0 + body.count('\n', 0, m.start())))

    walk(plat['init'], None)
    entries = []
    for f, (v, src) in sorted(flags.items()):
        if f in FTR and v:
            c, d, b, ch = FTR[f]
            entries.append({'codec': c, 'dir': d, 'flag': f, 'coded': [(b, ch)] if ch else [], 'max_w': None, 'max_h': None, 'src': src})
    unknown = sorted(f for f, (v, _) in flags.items() if f in FTR and v is None)
    return entries, unknown


def device_ids(md, plat):
    rel, names = plat['ids']
    s = open(os.path.join(md, rel), errors='replace').read()
    return sorted({m.group(1).lower() for m in re.finditer(r'RegisterDevice\((0x[0-9A-Fa-f]+)\s*,\s*&(\w+)\)', s) if m.group(2) in names}), rel


def summarize(entries):
    out = {}
    for e in entries:
        s = out.setdefault(e['codec'], {}).setdefault(e['dir'], {'coded': set(), 'profiles': set(), 'max_w': None, 'max_h': None, 'src': []})
        s['coded'] |= {tuple(x) for x in e['coded']}
        if e.get('profile'):
            s['profiles'].add(e['profile'])
        if e['max_w']:
            s['max_w'] = max(s['max_w'] or 0, e['max_w'])
            s['max_h'] = max(s['max_h'] or 0, e['max_h'] or 0)
        if e['src'] not in s['src']:
            s['src'].append(e['src'])
    for c in out.values():
        for s in c.values():
            s['bits'] = sorted({b for b, _ in s['coded']})
            s['chroma'] = sorted({ch for _, ch in s['coded']})
            s['coded'] = ['%d-bit %s' % (b, ch) for b, ch in sorted(s['coded'])]
            s['profiles'] = sorted(s['profiles'])
    return out


def supports(caps, platform, codec, d, bits, w, h, chroma='420'):
    """(True/False/None, reason) for one combination; None when the platform is not in caps.json."""
    p = next((x for x in caps['platforms'] if x['id'] == platform), None)
    if not p:
        return None, 'platform %s not in caps.json' % platform
    s = p['summary'].get(codec, {}).get(d)
    where = p['source']
    if not s:
        return False, 'Intel media-driver offers no %s %s entrypoint on %s (%s)' % (codec, d, p['name'], where)
    if '%d-bit %s' % (bits, chroma) not in s['coded']:
        return False, 'Intel media-driver offers %s %s on %s as %s only, not %d-bit %s (%s)' % (
            codec, d, p['name'], ', '.join(s['coded']), bits, chroma, ', '.join(s['src']))
    if s['max_w'] and (w > s['max_w'] or h > (s['max_h'] or s['max_w'])):
        return False, 'beyond Intel media-driver on %s: %s %s up to %dx%d (VAConfigAttribMaxPictureWidth/Height, %s)' % (
            p['name'], codec, d, s['max_w'], s['max_h'], ', '.join(s['src']))
    return True, 'offered by Intel media-driver on %s (%s)' % (p['name'], ', '.join(s['src']))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--media-driver', required=True)
    ap.add_argument('--out', default=os.path.join(ROOT, 'data/caps.json'))
    a = ap.parse_args()
    md = a.media_driver
    git = lambda *x: subprocess.run(['git', '-C', md] + list(x), capture_output=True, text=True).stdout.strip()
    consts = constants(md)
    plats = []
    for p in PLATFORMS:
        if p['model'] == 'capstable':
            entries, src, ext = capstable(md, p, consts)
            unknown = []
        else:
            entries, unknown = sku(md, p)
            src, ext = '%s %s()' % (p['file'], p['init']), {}
        ids, ids_src = device_ids(md, p)
        q = {'id': p['id'], 'name': p['name'], 'model': p['model'], 'source': src, 'device_ids': ids, 'device_ids_source': ids_src,
             'entries': entries, 'summary': summarize(entries)}
        if unknown:
            q['unresolved_flags'] = unknown
        if ext:
            q['ext_tables'] = ext
        plats.append(q)
    data = {'meta': {'source': 'https://github.com/intel/media-driver', 'commit': git('rev-parse', 'HEAD'),
                     'date': git('log', '-1', '--format=%cd', '--date=short'), 'subject': git('log', '-1', '--format=%s'),
                     'build': 'default (ENABLE_KERNELS, ENABLE_NONFREE_KERNELS on): SET_STATUS_BY_FULL_OPEN_SOURCE(a, b) = a',
                     'method': __doc__.split('\n\n')[1].replace('\n', ' ')},
            'platforms': plats}
    json.dump(data, open(a.out, 'w'), indent=1)
    for p in plats:
        print('caps %-5s %-9s %3d entries: %s' % (p['id'], p['model'], len(p['entries']), ' '.join(
            '%s[%s]' % (c, '/'.join('%s %s%s' % (d[:3], ','.join(map(str, s['bits'])), ' <=%dx%d' % (s['max_w'], s['max_h']) if s['max_w'] else '')
                                    for d, s in sorted(v.items()))) for c, v in sorted(p['summary'].items()) if c in ('h264', 'hevc', 'vp9', 'av1'))))


if __name__ == '__main__':
    main()
