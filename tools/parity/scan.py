#!/usr/bin/env python3
"""Code parity scan, evidence only. One record per upstream source file.

Upstream: Linux drivers/gpu/drm/xe, drivers/gpu/drm/i915/display, include/uapi/drm/xe_drm.h; Mesa src/intel/{vulkan,
common,isl,blorp}, src/vulkan/wsi (+ this repository's user/xemac as "ours").

Kernel statuses are COMPUTED, never asserted:
  ported      every function the upstream file defines (headers without functions: every #define) occurs by name in
              our sources (code or a comment citing it); the matches are stored with file:line (enclosing symbol)
  partial     some of them occur (matched/total stored)
  unverified  none occurs and there is no machine-checked proof of absence
  missing     map.json gives a proof that this script checks: "refuse" regexes that must match in our sources and/or
              "absent" tokens (names, register offsets) that must not occur; a failed proof gives "unverified"
  not_applicable  from map.json with a reason category (linux = Linux-only interface, hw = hardware the B580 lacks)
Mesa statuses: upstream (unchanged from the base commit and compiled), patched (changed by our series), ours (added
by our series, or user/xemac), not_built (not in compile_commands.json; a header follows its .c of the same stem).

  python3 tools/parity/scan.py --linux <linux tree> [--mesa <tree> --mesa-build <build dir>] [--html docs/parity/index.html]
Python stdlib only. --html replaces the JSON embedded in the page (script id="parity-data").
"""
import argparse, datetime, fnmatch, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC_EXT = ('.c', '.h', '.cpp', '.hpp', '.m', '.mm', '.inc')
LINUX_SETS = [('xe/', 'drivers/gpu/drm/xe'), ('display/', 'drivers/gpu/drm/i915/display')]
LINUX_FILES = [('uapi/xe_drm.h', 'include/uapi/drm/xe_drm.h')]
MESA_DIRS = ['src/intel/vulkan', 'src/intel/common', 'src/intel/isl', 'src/intel/blorp', 'src/vulkan/wsi']

FDEF = re.compile(r'^(?:static\s+)?(?:inline\s+)?(?:const\s+)?(?:struct\s+|enum\s+|unsigned\s+)?[A-Za-z_0-9]+[\s\*]+\**'
                  r'([a-z_][a-z0-9_]*)\s*\(', re.M)
MDEF = re.compile(r'^#define\s+([A-Z_][A-Z0-9_]+)', re.M)
CPP_HEAD = re.compile(r'^(?![\s#/{}])(?!(?:if|for|while|switch|return|else|do|case|typedef|using|namespace|extern)\b)'
                      r'[^;=]*?\b([A-Za-z_~][\w:~]*)\s*\(')
IDENT = re.compile(r'0[xX][0-9A-Fa-f]+|[A-Za-z_][A-Za-z0-9_]*')


def git(tree, *args):
    return subprocess.run(['git', '-C', tree] + list(args), check=True, capture_output=True, text=True).stdout


def walk(base):
    for root, dirs, files in os.walk(base):
        dirs.sort()
        for f in sorted(files):
            if f.endswith(SRC_EXT):
                yield os.path.join(root, f)


def count_lines(p):
    with open(p, 'rb') as f:
        return sum(1 for _ in f)


def norm(t):
    return t.lower() if t[:2] in ('0x', '0X') else t


class OurIndex:
    """token -> [(file, line, enclosing symbol, 'code'|'comment')] over our sources (uapi copies excluded)."""

    def __init__(self, dirs):
        self.occ, self.text = {}, {}
        for label, d in dirs:
            for p in walk(d):
                rel = os.path.relpath(p, d)
                if rel.split(os.sep)[0] in ('uapi', 'tests', 'build', 'scripts'):
                    continue
                name = label + '/' + rel
                s = open(p, errors='ignore').read()
                self.text[name] = s
                self._index(name, s)

    def _index(self, name, s):
        depth, cur, cand, in_block = 0, None, None, False
        for no, line in enumerate(s.split('\n'), 1):
            code, comment, i = '', '', 0
            while i < len(line):
                if in_block:
                    j = line.find('*/', i)
                    if j < 0:
                        comment += line[i:]
                        break
                    comment += line[i:j]
                    i, in_block = j + 2, False
                elif line.startswith('//', i):
                    comment += line[i:]
                    break
                elif line.startswith('/*', i):
                    in_block, i = True, i + 2
                else:
                    code += line[i]
                    i += 1
            if depth == 0:
                mm = CPP_HEAD.match(code)
                if mm and not code.rstrip().endswith(';'):
                    cand = mm.group(1)
            sym = cur or 'file scope'
            for kind, part in (('code', code), ('comment', comment)):
                for t in set(IDENT.findall(part)):
                    self.occ.setdefault(norm(t), []).append((name, no, sym, kind))
            for ch in code:
                if ch == '{':
                    if depth == 0:
                        cur = cand
                    depth += 1
                elif ch == '}':
                    depth = max(0, depth - 1)
                    if depth == 0:
                        cur, cand = None, None

    def find(self, tok):
        return self.occ.get(norm(tok), [])


def first_rule(rules, path):
    for r in rules:
        if any(fnmatch.fnmatchcase(path, g) for g in r['match']):
            return r
    return None


def group_of(groups, path):
    for g, name in groups:
        if fnmatch.fnmatchcase(path, g):
            return name
    return 'Other'


def upstream_items(path):
    s = open(path, errors='ignore').read()
    fns = sorted(x for x in set(FDEF.findall(s)) if '_' in x and len(x) > 6)
    if fns:
        return 'functions', fns
    return 'macros', sorted(x for x in set(MDEF.findall(s)) if len(x) > 5 and not x.startswith('__'))


def check_proof(proof, idx):
    """(ok, details): every 'refuse' regex must match in our sources, no 'absent' token may occur."""
    det, ok = [], True
    for rx in proof.get('refuse', []):
        hit = None
        for f, s in idx.text.items():
            mm = re.search(rx, s)
            if mm:
                hit = '%s:%d' % (f, s.count('\n', 0, mm.start()) + 1)
                break
        det.append({'check': 'refuse', 'pattern': rx, 'found_at': hit})
        ok = ok and hit is not None
    for tok in proof.get('absent', []):
        occ = idx.find(tok)
        det.append({'check': 'absent', 'token': tok, 'found_at': ['%s:%d' % (o[0], o[1]) for o in occ[:3]]})
        ok = ok and not occ
    return ok, det


def tree_id(path):
    try:
        top = git(path, 'rev-parse', '--show-toplevel').strip()
        return {'path': os.path.relpath(path, top), 'repo': os.path.basename(top),
                'repo_head': git(top, 'rev-parse', '--short', 'HEAD').strip(),
                'last_commit': git(path, 'log', '-1', '--format=%h %cs', '--', '.').strip(),
                'dirty': bool(git(path, 'status', '--porcelain', '--', '.').strip())}
    except Exception:
        return {'path': path, 'repo': None, 'repo_head': None, 'last_commit': None, 'dirty': None}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--linux', required=True)
    ap.add_argument('--kernel', default=os.path.join(ROOT, 'kernel/IntelXe'))
    ap.add_argument('--fb', default=os.path.join(ROOT, 'kernel/IntelXeFB'))
    ap.add_argument('--mesa')
    ap.add_argument('--mesa-base', default='f01e9b07a91f7e7ab730edfbb383b083f146067b')
    ap.add_argument('--mesa-build')
    ap.add_argument('--map', default=os.path.join(ROOT, 'tools/parity/map.json'))
    ap.add_argument('--out', default=os.path.join(ROOT, 'data/parity.json'))
    ap.add_argument('--html')
    a = ap.parse_args()

    mp = json.load(open(a.map))
    rules, groups = mp['rules'], mp['groups']
    warnings, files = [], []
    idx = OurIndex([('kernel/IntelXe', a.kernel), ('kernel/IntelXeFB', a.fb)])
    try:
        lrev, ldate = git(a.linux, 'rev-parse', 'HEAD').strip(), git(a.linux, 'log', '-1', '--format=%cs').strip()
        lver = '.'.join(l.split('=')[1].strip() for l in git(a.linux, 'show', 'HEAD:Makefile').splitlines()[1:4])
    except Exception:
        lrev, ldate, lver = 'unknown', '', ''

    todo = []
    for prefix, sub in LINUX_SETS:
        base = os.path.join(a.linux, sub)
        todo += [(prefix + os.path.relpath(p, base), p) for p in walk(base)]
    todo += [(k, os.path.join(a.linux, s)) for k, s in LINUX_FILES if os.path.exists(os.path.join(a.linux, s))]

    for key, p in todo:
        r = first_rule(rules, key) or {}
        kind, items = upstream_items(p)
        matched = []
        for it in items:
            occ = idx.find(it)
            if occ:
                code = [o for o in occ if o[3] == 'code']
                matched.append({'name': it, 'n': len(occ), 'in_code': len(code),
                                'at': ['%s:%d (%s, %s)' % o for o in (code or occ)[:3]]})
        names = {x['name'] for x in matched}
        rec = {'path': key, 'section': 'kernel', 'group': group_of(groups, key), 'lines': count_lines(p),
               'kind': kind, 'total': len(items), 'matched': len(matched), 'evidence': matched,
               'unmatched': [x for x in items if x not in names], 'na': None, 'reason': None, 'proof': None}
        if r.get('status') == 'not_applicable':
            rec.update(status='not_applicable', na=r['na'], reason=r['reason'], future=r.get('future'))
            if kind == 'functions' and len(matched) >= 3:
                warnings.append('%s is not_applicable but %d of its functions occur in our sources' % (key, len(matched)))
        elif matched:
            rec['status'] = 'ported' if len(matched) == len(items) else 'partial'
        elif r.get('status') == 'missing':
            ok, det = check_proof(r.get('proof', {}), idx)
            rec.update(proof=det, reason=r.get('reason'), status='missing' if ok else 'unverified')
            if not ok:
                warnings.append('%s: proof of absence failed -> unverified' % key)
        else:
            rec['status'] = 'unverified'
        files.append(rec)

    mesa_meta = None
    if a.mesa:
        head = git(a.mesa, 'rev-parse', '--short=12', 'HEAD').strip()
        changed = {}
        for line in git(a.mesa, 'diff', '--name-status', a.mesa_base, '--', *MESA_DIRS).splitlines():
            parts = line.split('\t')
            changed[parts[-1]] = parts[0][0]
        built = None
        if a.mesa_build:
            built = set()
            for e in json.load(open(os.path.join(a.mesa_build, 'compile_commands.json'))):
                f = e['file'] if os.path.isabs(e['file']) else os.path.join(e['directory'], e['file'])
                built.add(os.path.relpath(os.path.realpath(f), os.path.realpath(a.mesa)))
        bname = os.path.basename(os.path.normpath(a.mesa_build)) if a.mesa_build else None
        mesa_meta = {'head': head, 'base': a.mesa_base[:12], 'build': bname}
        for d in MESA_DIRS:
            for p in walk(os.path.join(a.mesa, d)):
                rel = os.path.relpath(p, a.mesa)
                if '/tests/' in rel:
                    continue
                key = 'mesa/' + rel[len('src/'):]
                ch, src_built = changed.get(rel), None
                if built is not None:
                    if rel.endswith(('.c', '.cpp', '.m')):
                        src_built = rel in built
                    else:
                        stem = rel.rsplit('.', 1)[0]
                        sib = [stem + e for e in ('.c', '.cpp', '.m') if os.path.exists(os.path.join(a.mesa, stem + e))]
                        src_built = any(s in built for s in sib) if sib else None
                if ch == 'A':
                    st, why = 'ours', 'added by our patch series'
                elif src_built is False:
                    st, why = 'not_built', 'not in compile_commands.json of ' + str(bname)
                elif ch == 'M':
                    st, why = 'patched', 'changed by our patch series (git diff vs %s)' % a.mesa_base[:12]
                else:
                    st, why = 'upstream', 'identical to upstream %s' % a.mesa_base[:12]
                files.append({'path': key, 'section': 'mesa', 'group': group_of(groups, key),
                              'lines': count_lines(p), 'status': st, 'reason': why})
        for p in walk(os.path.join(ROOT, 'user/xemac')):
            rel = os.path.relpath(p, os.path.join(ROOT, 'user'))
            files.append({'path': 'ours/' + rel, 'section': 'mesa', 'group': group_of(groups, 'ours/' + rel),
                          'lines': count_lines(p), 'status': 'ours', 'reason': 'this repository, user/' + rel})

    pct = lambda x, y: round(100.0 * x / y, 1) if y else 0.0

    def summ(section):
        fs = [f for f in files if f['section'] == section]
        out = {'files': len(fs), 'lines': sum(f['lines'] for f in fs), 'by_status': {}}
        for f in fs:
            b = out['by_status'].setdefault(f['status'], {'files': 0, 'lines': 0})
            b['files'] += 1
            b['lines'] += f['lines']
        if section == 'kernel':
            app = [f for f in fs if f['status'] != 'not_applicable']
            fn = [f for f in app if f['kind'] == 'functions']
            mc = [f for f in app if f['kind'] == 'macros']
            L = sum(f['lines'] for f in app)
            out.update({
                'applicable_files': len(app), 'applicable_lines': L,
                'functions_total': sum(f['total'] for f in fn), 'functions_matched': sum(f['matched'] for f in fn),
                'pct_functions_matched': pct(sum(f['matched'] for f in fn), sum(f['total'] for f in fn)),
                'macros_total': sum(f['total'] for f in mc), 'macros_matched': sum(f['matched'] for f in mc),
                'pct_macros_matched': pct(sum(f['matched'] for f in mc), sum(f['total'] for f in mc)),
                'pct_lines_ported': pct(sum(f['lines'] for f in app if f['status'] == 'ported'), L),
                'pct_lines_with_match': pct(sum(f['lines'] for f in app if f['matched']), L),
                'pct_lines_missing': pct(sum(f['lines'] for f in app if f['status'] == 'missing'), L),
                'pct_lines_unverified': pct(sum(f['lines'] for f in app if f['status'] == 'unverified'), L),
                'pct_files_unverified': pct(len([f for f in app if f['status'] == 'unverified']), len(app)),
            })
        return out

    data = {
        'meta': {'generated': datetime.datetime.now().strftime('%Y-%m-%d %H:%M'),
                 'linux': {'rev': lrev[:12], 'date': ldate, 'version': lver},
                 'ours': {'kernel': tree_id(a.kernel), 'fb': tree_id(a.fb)}, 'mesa': mesa_meta,
                 'method': 'upstream function names (headers: #define names) searched by name in our sources, '
                           'code and comments; tools/parity/scan.py'},
        'summary': {'kernel': summ('kernel'), 'mesa': summ('mesa') if a.mesa else None},
        'files': files,
    }
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, 'w') as f:
        json.dump(data, f, indent=1, ensure_ascii=False)
        f.write('\n')
    if a.html:
        page = open(a.html).read()
        blob = json.dumps(data, separators=(',', ':'), ensure_ascii=False).replace('</', '<\\/')
        new, n = re.subn(r'(<script id="parity-data" type="application/json">).*?(</script>)',
                         lambda mm: mm.group(1) + blob + mm.group(2), page, flags=re.S)
        if n != 1:
            sys.exit('html: parity-data script tag not found')
        open(a.html, 'w').write(new)
    k = data['summary']['kernel']
    print('kernel: %d files, %d applicable (%d lines)' % (k['files'], k['applicable_files'], k['applicable_lines']))
    print('  functions matched %d/%d = %.1f%%; header #defines matched %d/%d = %.1f%%' % (
        k['functions_matched'], k['functions_total'], k['pct_functions_matched'],
        k['macros_matched'], k['macros_total'], k['pct_macros_matched']))
    print('  lines: ported %.1f%%, >=1 match %.1f%%, missing %.1f%%, unverified %.1f%% (files unverified %.1f%%)' % (
        k['pct_lines_ported'], k['pct_lines_with_match'], k['pct_lines_missing'], k['pct_lines_unverified'],
        k['pct_files_unverified']))
    for s, b in sorted(k['by_status'].items()):
        print('  %-15s %4d files %7d lines' % (s, b['files'], b['lines']))
    if a.mesa:
        for s, b in sorted(data['summary']['mesa']['by_status'].items()):
            print('  mesa %-10s %4d files %7d lines' % (s, b['files'], b['lines']))
    for w in warnings:
        print('warning:', w, file=sys.stderr)


if __name__ == '__main__':
    main()
