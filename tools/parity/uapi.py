#!/usr/bin/env python3
"""xe uAPI coverage: every ioctl, query, property, extension and flag of include/uapi/drm/xe_drm.h is one cell.

Each token (#define or enum member named DRM_IOCTL_XE_* / DRM_XE_*; the bare ioctl numbers DRM_XE_<IOCTL> are folded
into their DRM_IOCTL_XE_* cell) gets a status from the CODE of our kernel (comments ignored, uapi copies excluded):
  implemented  used in code outside a rejection (switch case with a body, value produced, flag honoured, or a
               "!= token -> error" check that accepts it)
  noop         a case label whose body is only "return 0;" (accepted, does nothing)
  rejected     every code use is a rejection: the line returns/sets an error (EINVAL, EOPNOTSUPP, ...) and the token
               is tested with == or & (not !=, not inside ~(...))
  absent       no code use at all (an unknown value then falls into a default: error path)
Every cell keeps the file:line of the uses. Python stdlib only.
"""
import argparse, json, os, re, sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scan  # noqa: E402

ERR = re.compile(r'\b(EINVAL|EOPNOTSUPP|ENOTSUP|ENODEV|ENOTTY|EPERM|ENOSYS)\b')
DEF = re.compile(r'^[ \t]*#define\s+((?:DRM_IOCTL_XE_|DRM_XE_)[A-Z0-9_]+)', re.M)
ENUM_MEM = re.compile(r'^\s*((?:DRM_XE_)[A-Z0-9_]+)\s*(?:=[^,\n]*)?,?\s*(?:/\*.*)?$', re.M)

AREAS = [  # (prefix, area) first match wins
    ('DRM_IOCTL_XE_', 'ioctls'),
    ('DRM_XE_DEVICE_QUERY_', 'DEVICE_QUERY types'), ('DRM_XE_QUERY_', 'DEVICE_QUERY contents'),
    ('DRM_XE_TOPO_', 'DEVICE_QUERY contents'), ('DRM_XE_ENGINE_CLASS_', 'engine classes'),
    ('DRM_XE_MEM_REGION_CLASS_', 'DEVICE_QUERY contents'),
    ('DRM_XE_GEM_', 'GEM_CREATE / MMAP_OFFSET'), ('DRM_XE_MMAP_', 'GEM_CREATE / MMAP_OFFSET'),
    ('DRM_XE_VM_CREATE_', 'VM_CREATE'), ('DRM_XE_VM_BIND_', 'VM_BIND'), ('DRM_XE_VM_GET_PROPERTY', 'VM_GET_PROPERTY'),
    ('DRM_XE_EXEC_QUEUE_', 'EXEC_QUEUE'), ('DRM_XE_MULTI_GROUP', 'EXEC_QUEUE'),
    ('DRM_XE_SYNC_', 'syncs (EXEC / VM_BIND)'), ('DRM_XE_MAX_SYNCS', 'syncs (EXEC / VM_BIND)'),
    ('DRM_XE_UFENCE_', 'WAIT_USER_FENCE'),
    ('DRM_XE_OBSERVATION', 'OBSERVATION: OA / EU stall'), ('DRM_XE_OA', 'OBSERVATION: OA / EU stall'),
    ('DRM_XE_EU_STALL', 'OBSERVATION: OA / EU stall'),
    ('DRM_XE_PXP', 'PXP'),
    ('DRM_XE_MEM_RANGE', 'MADVISE / memory ranges'), ('DRM_XE_VMA_', 'MADVISE / memory ranges'),
    ('DRM_XE_PREFERRED_', 'MADVISE / memory ranges'), ('DRM_XE_MIGRATE_', 'MADVISE / memory ranges'),
    ('DRM_XE_ATOMIC_', 'MADVISE / memory ranges'), ('DRM_XE_CONSULT_', 'MADVISE / memory ranges'),
    ('DRM_XE_MEM_', 'MADVISE / memory ranges'),
    ('DRM_XE_RAS', 'RAS'),
    ('DRM_XE_', 'other'),
]


def area_of(tok):
    for p, a in AREAS:
        if tok.startswith(p):
            return a
    return 'other'


def tokens(header):
    s = open(header).read()
    toks = list(dict.fromkeys(DEF.findall(s)))
    for m in re.finditer(r'enum\s+\w*\s*\{(.*?)\};', s, re.S):
        toks += [t for t in ENUM_MEM.findall(m.group(1)) if t not in toks]
    ioctls = {t[len('DRM_IOCTL_'):] for t in toks if t.startswith('DRM_IOCTL_XE_')}
    # DRM_XE_DEVICE_QUERY (ioctl number) duplicates DRM_IOCTL_XE_DEVICE_QUERY
    return [t for t in toks if not (t.startswith('DRM_XE_') and 'XE_' + t[len('DRM_XE_'):] in ioctls)]


def code_lines(text):
    """[(lineno, code part)] with // and /* */ comments removed."""
    out, in_block = [], False
    for no, line in enumerate(text.split('\n'), 1):
        code, i = '', 0
        while i < len(line):
            if in_block:
                j = line.find('*/', i)
                if j < 0:
                    break
                i, in_block = j + 2, False
            elif line.startswith('//', i):
                break
            elif line.startswith('/*', i):
                in_block, i = True, i + 2
            else:
                code += line[i]
                i += 1
        out.append((no, code))
    return out


def classify_use(tok, lines, k):
    """'use' | 'reject' | 'noop' for the token on lines[k]."""
    code = lines[k][1]
    pos = [m.start() for m in re.finditer(r'\b%s\b' % tok, code)]
    if re.search(r'\bcase\s+%s\s*:' % tok, code):
        nxt = next((c.strip() for _, c in lines[k + 1:k + 6] if c.strip() and not c.strip().startswith('case ')), '')
        body = code.split(':', 1)[1].strip()
        first = body or nxt
        if re.match(r'^(return|err\s*=)\s*E[A-Z]+', first):
            return 'reject'
        if first == 'return 0;':
            return 'noop'
        return 'use'
    if ERR.search(code):
        for p in pos:
            before = code[:p]
            if re.search(r'!=\s*$', before):
                return 'use'                     # "x != TOKEN -> error" accepts TOKEN
            depth_tilde = before.rfind('~(')
            if depth_tilde >= 0 and before.count('(', depth_tilde) > before.count(')', depth_tilde):
                return 'use'                     # inside a ~(known flags) mask
        return 'reject'
    return 'use'


# ------------------------------------------------------------------------------ values, switches, second pass

def values(header_text, extra=()):
    """name -> int for #defines and enum members that evaluate to plain integers (ioctl macros: their nr)."""
    vals, raw = {}, {}
    for m in re.finditer(r'^[ \t]*#define\s+([A-Z_][A-Z0-9_]*)\s+(.+?)\s*$', header_text, re.M):
        raw[m.group(1)] = re.sub(r'/\*.*?\*/', '', m.group(2)).strip()
    for m in re.finditer(r'enum\s+\w*\s*\{(.*?)\};', header_text, re.S):
        nxt = 0
        for mm in re.finditer(r'^\s*([A-Z_][A-Z0-9_]*)\s*(?:=\s*([^,\n]+))?,?', m.group(1), re.M):
            if mm.group(2):
                raw[mm.group(1)] = mm.group(2).strip()
                v = ev(mm.group(2), vals, raw)
                nxt = v if v is not None else nxt
            else:
                raw[mm.group(1)] = str(nxt)
            vals[mm.group(1)] = ev(raw[mm.group(1)], vals, raw)
            nxt = (vals[mm.group(1)] if vals[mm.group(1)] is not None else nxt) + 1
    for k in raw:
        if k not in vals:
            vals[k] = ev(raw[k], vals, raw)
    return vals


def ev(expr, vals, raw, depth=0):
    if depth > 8:
        return None
    m = re.match(r'DRM_IO\w*\(\s*DRM_COMMAND_BASE\s*\+\s*([A-Z_0-9]+)', expr)
    if m:   # ioctl: its command number
        v = ev(raw.get(m.group(1), ''), vals, raw, depth + 1)
        return None if v is None else 0x40 + v
    e = re.sub(r'(?<=[0-9a-fA-F])[uUlL]+\b', '', expr)
    for name in set(re.findall(r'\b[A-Z_][A-Z0-9_]+\b', e)):
        v = vals.get(name)
        if v is None and name in raw:
            v = ev(raw[name], vals, raw, depth + 1)
        if v is None:
            return None
        e = re.sub(r'\b%s\b' % name, str(v), e)
    if not re.fullmatch(r'[0-9xXa-fA-F\s()<>|&+\-*~]+', e):
        return None
    try:
        return int(eval(e, {'__builtins__': {}}))
    except Exception:
        return None


def switches(parsed):
    """All switch statements: {file, line, cases: [(label, line)], default: (line, first statement)}."""
    out = []
    for f, lines in parsed.items():
        depth, stack, pending = 0, [], None
        for k, (no, code) in enumerate(lines):
            st = code.strip()
            if stack and depth == stack[-1]['depth']:
                for lab in re.findall(r'\bcase\s+([^:]+?)\s*:(?!:)', code):
                    stack[-1]['cases'].append((lab.strip(), no))
                if re.match(r'default\s*:', st):
                    body = st.split(':', 1)[1].strip()
                    nxt = body or next((c.strip() for _, c in lines[k + 1:k + 6] if c.strip()), '')
                    stack[-1]['default'] = (no, nxt)
            if re.search(r'\bswitch\s*\(', code):
                pending = {'file': f, 'line': no, 'cases': [], 'default': None}
            for ch in code:
                if ch == '{':
                    depth += 1
                    if pending is not None:
                        pending['depth'] = depth
                        stack.append(pending)
                        pending = None
                elif ch == '}':
                    if stack and depth == stack[-1]['depth']:
                        out.append(stack.pop())
                    depth -= 1
    return out


VALUE_HINTS = [  # (token regex, code regex with {v} = the token's value, what a match means)
    (r'^DRM_XE_ENGINE_CLASS_', r'(?:gEngines|gMediaEngines)\[[^\]]*\]\s*=\s*\{{\s*{v}\s*,', 'implemented'),   # engine table entry
    (r'^DRM_XE_ENGINE_CLASS_', r'(?:drmClass|engine_class)\s*==\s*{v}\b', 'implemented'),
    (r'^DRM_XE_MAX_SYNCS$', r'\bnum\w*\s*>\s*{v}\)\s*return\s+EINVAL', 'implemented'),
]
EXT_PROPS = r'^DRM_XE_(EXEC_QUEUE_EXTENSION_SET_PROPERTY|EXEC_QUEUE_SET_PROPERTY_\w+|EXEC_QUEUE_SET_HANG_REPLAY_STATE|' \
            r'EXEC_QUEUE_SET_DISABLE_STATE_CACHE_PERF_FIX|GEM_CREATE_EXTENSION_SET_PROPERTY|GEM_CREATE_SET_PROPERTY_\w+)$'
PARENT = {'WAIT_USER_FENCE': ['DRM_IOCTL_XE_WAIT_USER_FENCE'], 'OBSERVATION: OA / EU stall': ['DRM_IOCTL_XE_OBSERVATION'],
          'MADVISE / memory ranges': ['DRM_IOCTL_XE_MADVISE', 'DRM_IOCTL_XE_VM_QUERY_MEM_RANGE_ATTRS'],
          'VM_GET_PROPERTY': ['DRM_IOCTL_XE_VM_GET_PROPERTY']}


def family(tok):
    """The enumeration a token belongs to: switch/default reasoning only compares tokens of the same family."""
    if tok.startswith('DRM_IOCTL_XE_'):
        return 'DRM_IOCTL_XE_'
    m = re.match(r'^(.*?_(?:OP|FLAG|TYPE|CLASS|PROPERTY|QUERY|CAPS|ATTR|STATE|LOC)_)', tok)
    return m.group(1) if m else tok


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--linux', required=True)
    ap.add_argument('--kernel', default=os.path.join(scan.ROOT, 'kernel/IntelXe'))
    ap.add_argument('--fb', default=os.path.join(scan.ROOT, 'kernel/IntelXeFB'))
    ap.add_argument('--out', default=os.path.join(scan.ROOT, 'data/uapi.json'))
    a = ap.parse_args()
    header = os.path.join(a.linux, 'include/uapi/drm/xe_drm.h')
    htext = open(header).read()
    vals = values(htext)
    ours_uapi = ''
    for fn in ('intelxe_drm.h', 'xe_drm.h', 'drm.h'):
        p = os.path.join(a.kernel, 'uapi', fn)
        if os.path.exists(p):
            ours_uapi += open(p).read() + '\n'
    our_vals = values(ours_uapi)
    idx = scan.OurIndex([('kernel/IntelXe', a.kernel), ('kernel/IntelXeFB', a.fb)])
    parsed = {f: code_lines(t) for f, t in idx.text.items()}
    sws = switches(parsed)
    alltext = {f: '\n'.join(c for _, c in lines) for f, lines in parsed.items()}

    def find(rx):
        for f, lines in parsed.items():
            for no, code in lines:
                if re.search(rx, code):
                    return '%s:%d' % (f, no), code.strip()[:160]
        return None, None

    cells = []
    for tok in tokens(header):
        uses = []
        for f, lines in parsed.items():
            for k, (no, code) in enumerate(lines):
                if re.search(r'\b%s\b' % tok, code):
                    uses.append({'at': '%s:%d' % (f, no), 'kind': classify_use(tok, lines, k), 'code': code.strip()[:160]})
        kinds = {u['kind'] for u in uses}
        st = None if not uses else 'implemented' if 'use' in kinds else 'noop' if 'noop' in kinds else 'rejected'
        cells.append({'token': tok, 'area': area_of(tok), 'value': vals.get(tok), 'status': st, 'by': 'name' if uses else None,
                      'uses': uses, 'why': ''})
    byname = {c['token']: c for c in cells}

    # same value under our own name (kernel/IntelXe/uapi), used in code
    for c in cells:
        if c['status'] or c['value'] is None:
            continue
        twins = [n for n, v in our_vals.items() if v == c['value'] and n != c['token'] and n.startswith(c['token'].rsplit('_', 1)[0])]
        for n in twins:
            at, code = find(r'\b%s\b' % n)
            if at:
                c.update(status='implemented', by='value (our name %s)' % n, uses=[{'at': at, 'kind': 'use', 'code': code}])
                break
    # value in a known field context
    for c in cells:
        if c['status'] or c['value'] is None:
            continue
        for trx, crx, st in VALUE_HINTS:
            if not c['status'] and re.search(trx, c['token']):
                at, code = find(crx.format(v=c['value']))
                if at:
                    c.update(status=st, by='value %d' % c['value'], uses=[{'at': at, 'kind': 'use', 'code': code}])
    # a switch that dispatches this area: covered by a case value, or falls into an error default
    for c in cells:
        if c['status']:
            continue
        fam = family(c['token'])
        sib = [x['token'] for x in cells if family(x['token']) == fam and x['token'] != c['token']]
        for sw in sws:
            labels = [l for l, _ in sw['cases']]
            if not any(l in sib for l in labels):
                continue
            lv = {vals.get(l, ev(l, vals, {})) for l in labels}
            if c['value'] is not None and c['value'] in lv:
                ln = next(n for l, n in sw['cases'] if vals.get(l, ev(l, vals, {})) == c['value'])
                c.update(status='implemented', by='value %d (case label)' % c['value'],
                         uses=[{'at': '%s:%d' % (sw['file'], ln), 'kind': 'use', 'code': 'case with the same value'}])
            elif c['value'] is not None and sw['default'] and re.match(r'(return|err\s*=)\s*E[A-Z]+', sw['default'][1]):
                c.update(status='rejected', by='switch default',
                         uses=[{'at': '%s:%d' % (sw['file'], sw['default'][0]), 'kind': 'reject', 'code': 'default: ' + sw['default'][1]}],
                         why='no case for value %d in the switch at %s:%d; its default returns an error' % (c['value'], sw['file'], sw['line']))
            break
    # parameters of an ioctl that is itself rejected
    for c in cells:
        if c['status'] or c['area'] not in PARENT:
            continue
        par = [byname.get(p) for p in PARENT[c['area']]]
        if par and all(p and p['status'] == 'rejected' for p in par):
            c.update(status='rejected', by='parent ioctl', uses=par[0]['uses'],
                     why='only reachable through %s, which our dispatch rejects' % ', '.join(PARENT[c['area']]))
    # extension properties: the extension chain is never read
    reads_ext = any(re.search(r'(->|\.)extensions\b', t) for t in alltext.values())
    for c in cells:
        if not c['status'] and re.search(EXT_PROPS, c['token']) and not reads_ext:
            c.update(status='noop', by='extension chain never read',
                     why="no code in our kernel reads an 'extensions' field: the set-property extension is accepted and ignored")
    # device-query contents our handlers do not report (their handlers write named values only)
    for c in cells:
        if c['status'] or c['area'] != 'DEVICE_QUERY contents':
            continue
        fam = c['token'].rsplit('_', 1)[0] if 'FLAG' not in c['token'] else 'DRM_XE_QUERY_CONFIG_FLAG'
        fam = 'DRM_XE_TOPO' if c['token'].startswith('DRM_XE_TOPO') else fam
        at, code = find(r'\b%s\w*' % fam)
        if at:
            c.update(status='absent', by='not reported', uses=[{'at': at, 'kind': 'use', 'code': code}],
                     why='the handler that reports %s* values does not set this one' % fam)
    for c in cells:
        c['comments'] = ['%s:%d (%s)' % (o[0], o[1], o[2]) for o in idx.find(c['token']) if o[3] == 'comment'][:3]
        if not c['status']:
            c['status'] = 'unverified'
            c['why'] = 'no use by name%s; no dispatch switch, field match or proof decides it' % (
                ' or by value %d' % c['value'] if c['value'] is not None else ' (value not resolvable)')

    tot = len(cells)
    order = ('implemented', 'noop', 'rejected', 'absent', 'unverified')
    cnt = {s: sum(1 for c in cells if c['status'] == s) for s in order}
    ioc = [c for c in cells if c['area'] == 'ioctls']
    data = {'meta': {'header': 'include/uapi/drm/xe_drm.h', 'linux': scan.git(a.linux, 'rev-parse', '--short=12', 'HEAD').strip(),
                     'ours': {'kernel': scan.tree_id(a.kernel), 'fb': scan.tree_id(a.fb)},
                     'method': 'by name, then by value (our uapi names, field contexts, switch case labels/defaults, '
                               'rejected parent ioctls, unread extension chains); see tools/parity/uapi.py'},
            'summary': {'cells': tot, **cnt, 'pct_implemented': round(100.0 * cnt['implemented'] / tot, 1),
                        'ioctls': len(ioc), 'ioctls_implemented': sum(1 for c in ioc if c['status'] == 'implemented')},
            'cells': cells}
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    json.dump(data, open(a.out, 'w'), indent=1)
    s = data['summary']
    print('xe uAPI: %d cells: implemented %d (%.1f%%), no-op %d, rejected %d, absent (proven) %d, unverified %d; ioctls %d/%d' % (
        tot, s['implemented'], s['pct_implemented'], s['noop'], s['rejected'], s['absent'], s['unverified'],
        s['ioctls_implemented'], s['ioctls']))


if __name__ == '__main__':
    main()
