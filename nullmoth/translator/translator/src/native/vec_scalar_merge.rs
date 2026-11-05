use super::lex::split_top_level;
use crate::fxhash::{HashMap, HashSet};
use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet, VecDeque};

pub(super) fn lower_vector_scalar_pointer_merge(san_ll: &str) -> Cow<'_, str> {
    lower_impl(san_ll, true)
}

fn lower_impl(san_ll: &str, widen: bool) -> Cow<'_, str> {
    let lines: Vec<&str> = san_ll.lines().collect();
    let mut out: Option<Vec<String>> = None;
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        if line.starts_with("define") && line.trim_end().ends_with('{') {
            let start = i + 1;
            let mut j = start;
            while j < lines.len() && lines[j] != "}" {
                j += 1;
            }
            if let Some(rewritten) = rewrite_function_body(&lines[start..j], widen) {
                let output = out.get_or_insert_with(|| {
                    let mut prefix = Vec::with_capacity(lines.len());
                    prefix.extend(lines[..i].iter().map(|line| (*line).to_string()));
                    prefix
                });
                output.push(line.to_string());
                output.extend(rewritten);
                if j < lines.len() {
                    output.push(lines[j].to_string());
                }
            } else if let Some(output) = &mut out {
                output.extend(
                    lines[i..j.min(lines.len() - 1) + 1]
                        .iter()
                        .map(|line| (*line).to_string()),
                );
            }
            i = j + 1;
        } else {
            if let Some(output) = &mut out {
                output.push(line.to_string());
            }
            i += 1;
        }
    }
    let Some(out) = out else {
        return Cow::Borrowed(san_ll);
    };
    let mut result = out.join("\n");
    if san_ll.ends_with('\n') {
        result.push('\n');
    }
    Cow::Owned(result)
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Pointee<'a> {
    Scalar(&'a str),
    Vec(&'a str, usize),
    Unknown,
}

#[derive(Clone, Copy)]
struct Def<'a> {
    name: &'a str,
    opcode: &'a str,
    rest: &'a str,
}

fn parse_def(line: &str) -> Option<Def<'_>> {
    let line = line.trim();
    if !line.starts_with('%') {
        return None;
    }
    let eq = line.find(" = ")?;
    let name = line[..eq].trim();
    let rhs = line[eq + 3..].trim();
    let opcode = rhs.split_whitespace().next()?;
    let rest = rhs[opcode.len()..].trim();
    Some(Def { name, opcode, rest })
}

fn vec_elem_lanes(ty: &str) -> Option<(&str, usize)> {
    let ty = ty.trim();
    let inner = ty.strip_prefix('<')?.strip_suffix('>')?.trim();
    let (n, elem) = inner.split_once(" x ")?;
    let lanes: usize = n.trim().parse().ok()?;
    let elem = elem.trim();
    if !is_simple_scalar(elem) {
        return None;
    }
    Some((elem, lanes))
}

fn is_simple_scalar(ty: &str) -> bool {
    let bytes = ty.as_bytes();
    bytes.first().is_some_and(u8::is_ascii_alphabetic)
        && bytes.iter().all(u8::is_ascii_alphanumeric)
}

fn split_ptr_operand(chunk: &str) -> Option<(&str, &str)> {
    let chunk = chunk.trim();
    let name_start = chunk.rfind(char::is_whitespace)? + 1;
    let name = chunk[name_start..].trim();
    if !name.starts_with('%') {
        return None;
    }
    Some((chunk[..name_start].trim(), name))
}

fn trailing_local(chunk: &str) -> Option<&str> {
    let tok = chunk.trim().rsplit(char::is_whitespace).next()?.trim();
    tok.starts_with('%').then_some(tok)
}

struct GepInfo<'a> {
    inbounds: bool,
    src_ty: &'a str,
    base_chunk: &'a str,
    base_name: &'a str,
    indices: Vec<&'a str>,
}

fn parse_gep(rest: &str) -> Option<GepInfo<'_>> {
    let (inbounds, rest) = match rest.strip_prefix("inbounds ") {
        Some(r) => (true, r.trim()),
        None => (false, rest.trim()),
    };
    let chunks = split_top_level(rest, ',');
    if chunks.len() < 2 {
        return None;
    }
    let (_, base_name) = split_ptr_operand(chunks[1])?;
    Some(GepInfo {
        inbounds,
        src_ty: chunks[0].trim(),
        base_chunk: chunks[1].trim(),
        base_name,
        indices: chunks[2..].to_vec(),
    })
}

/// One definition with what the analyses read from it, parsed once.
struct DefInfo<'a> {
    def: Def<'a>,
    gep: Option<GepInfo<'a>>,
    neighbours: Vec<&'a str>,
}

impl<'a> DefInfo<'a> {
    fn new(def: Def<'a>) -> Self {
        let gep = (def.opcode == "getelementptr")
            .then(|| parse_gep(def.rest))
            .flatten();
        let neighbours = match def.opcode {
            "getelementptr" => gep.iter().map(|gep| gep.base_name).collect(),
            "bitcast" => bitcast_source(def.rest).into_iter().collect(),
            "phi" => phi_arm_values(def.rest),
            "select" => select_arm_values(def.rest),
            _ => Vec::new(),
        };
        Self { def, gep, neighbours }
    }
}

fn bitcast_source(rest: &str) -> Option<&str> {
    let (lhs, rhs) = rest.split_once(" to ")?;
    if !lhs.trim_start().starts_with("ptr") || !rhs.trim_start().starts_with("ptr") {
        return None;
    }
    trailing_local(lhs)
}

fn phi_arm_values(rest: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut search = rest;
    while let Some(open) = search.find('[') {
        let after = &search[open + 1..];
        let Some(close) = after.find(']') else { break };
        let inner = &after[..close];
        let val = inner.split(',').next().unwrap_or(inner).trim();
        if val.starts_with('%') {
            out.push(val);
        }
        search = &after[close + 1..];
    }
    out
}

fn select_arm_values(rest: &str) -> Vec<&str> {
    let parts = split_top_level(rest, ',');
    if parts.len() != 3 {
        return Vec::new();
    }
    parts[1..]
        .iter()
        .filter(|p| p.trim_start().starts_with("ptr"))
        .filter_map(|p| trailing_local(p))
        .collect()
}

/// `defs` in name order (the order the fixed point has always run in); the arms are indices into it.
fn classify<'a>(
    defs: &BTreeMap<&'a str, DefInfo<'a>>,
) -> (HashMap<&'a str, Pointee<'a>>, HashSet<&'a str>) {
    enum Step<'a> {
        Fixed(Pointee<'a>),
        Bitcast(Option<usize>),
        Merge(Vec<usize>),
    }
    let index: HashMap<&str, usize> = defs.keys().enumerate().map(|(i, name)| (*name, i)).collect();
    let arm_indices = |arms: &[&str]| -> Vec<usize> {
        arms.iter().filter_map(|arm| index.get(arm).copied()).collect()
    };
    let steps: Vec<Step<'a>> = defs
        .values()
        .map(|info| match info.def.opcode {
            "getelementptr" => Step::Fixed(gep_pointee(info.gep.as_ref())),
            "bitcast" => Step::Bitcast(
                info.neighbours.first().and_then(|source| index.get(source).copied()),
            ),
            "phi" | "select" => Step::Merge(arm_indices(&info.neighbours)),
            _ => Step::Fixed(Pointee::Unknown),
        })
        .collect();
    let mut pointees: Vec<Option<Pointee<'a>>> = vec![None; steps.len()];
    let mut mismatches: Vec<usize> = Vec::new();
    for _ in 0..=steps.len() {
        let mut changed = false;
        mismatches.clear();
        for (i, step) in steps.iter().enumerate() {
            let p = match step {
                Step::Fixed(p) => *p,
                Step::Bitcast(source) => source
                    .and_then(|source| pointees[source])
                    .unwrap_or(Pointee::Unknown),
                Step::Merge(arms) => merge_arms(arms, &pointees, &mut mismatches, i),
            };
            if pointees[i] != Some(p) {
                pointees[i] = Some(p);
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }
    let names: Vec<&'a str> = defs.keys().copied().collect();
    (
        mismatches.iter().filter_map(|m| Some((names[*m], pointees[*m]?))).collect(),
        mismatches.iter().map(|m| names[*m]).collect(),
    )
}

fn gep_pointee<'a>(gep: Option<&GepInfo<'a>>) -> Pointee<'a> {
    let Some(g) = gep else {
        return Pointee::Unknown;
    };
    if let Some((elem, lanes)) = vec_elem_lanes(g.src_ty) {
        if g.indices.len() == 1 {
            Pointee::Vec(elem, lanes)
        } else {
            Pointee::Scalar(elem)
        }
    } else if is_simple_scalar(g.src_ty) {
        Pointee::Scalar(g.src_ty)
    } else {
        Pointee::Unknown
    }
}

fn merge_arms<'a>(
    arms: &[usize],
    pointees: &[Option<Pointee<'a>>],
    mismatches: &mut Vec<usize>,
    index: usize,
) -> Pointee<'a> {
    let mut elem: Option<&'a str> = None;
    let mut several_elems = false;
    let mut saw_scalar = false;
    let mut vec_lanes: Option<usize> = None;
    let mut consistent_vec = true;
    for arm in arms {
        let e = match pointees[*arm] {
            Some(Pointee::Scalar(e)) => {
                saw_scalar = true;
                e
            }
            Some(Pointee::Vec(e, n)) => {
                match vec_lanes {
                    Some(prev) if prev != n => consistent_vec = false,
                    _ => vec_lanes = Some(n),
                }
                e
            }
            _ => continue,
        };
        several_elems |= elem.is_some_and(|prev| prev != e);
        elem = Some(e);
    }
    let Some(elem) = elem.filter(|_| !several_elems && consistent_vec) else {
        return Pointee::Unknown;
    };
    match (saw_scalar, vec_lanes) {
        (true, Some(_)) => {
            mismatches.push(index);
            Pointee::Scalar(elem)
        }
        (true, None) => Pointee::Scalar(elem),
        (false, Some(n)) => Pointee::Vec(elem, n),
        (false, None) => Pointee::Unknown,
    }
}

fn pointer_adjacency<'a>(defs: &BTreeMap<&'a str, DefInfo<'a>>) -> HashMap<&'a str, Vec<&'a str>> {
    let mut adj: HashMap<&'a str, Vec<&'a str>> = HashMap::default();
    for (name, info) in defs {
        for nb in &info.neighbours {
            adj.entry(*name).or_default().push(*nb);
            adj.entry(*nb).or_default().push(*name);
        }
    }
    adj
}

fn component<'a>(
    adj: &HashMap<&'a str, Vec<&'a str>>,
    seeds: &HashSet<&'a str>,
) -> HashSet<&'a str> {
    let mut seen: HashSet<&'a str> = seeds.clone();
    let mut queue: VecDeque<&'a str> = seeds.iter().copied().collect();
    while let Some(cur) = queue.pop_front() {
        if let Some(nbs) = adj.get(cur) {
            for nb in nbs {
                if seen.insert(*nb) {
                    queue.push_back(*nb);
                }
            }
        }
    }
    seen
}

#[derive(Default)]
struct UseWidths<'a> {
    scalars: Vec<&'a str>,
    vectors: Vec<&'a str>,
    other: bool,
    logical: bool,
}

fn is_word_addressable_ptr(prefix: &str) -> bool {
    prefix.contains("addrspace(1)") || prefix.contains("addrspace(2)")
}

fn scalar_byte_width(elem: &str) -> Option<usize> {
    match elem {
        "i8" => Some(1),
        "i16" | "half" | "bfloat" => Some(2),
        "i32" | "float" => Some(4),
        "i64" | "double" => Some(8),
        other => other
            .strip_prefix('i')
            .and_then(|b| b.parse::<usize>().ok())
            .map(|bits| bits.div_ceil(8)),
    }
}

fn use_widths<'a>(body: &[&'a str], line_defs: &[Option<Def<'a>>]) -> HashMap<&'a str, UseWidths<'a>> {
    fn push_new<'a>(list: &mut Vec<&'a str>, value: &'a str) {
        if !list.contains(&value) {
            list.push(value);
        }
    }
    let mut map: HashMap<&'a str, UseWidths<'a>> = HashMap::default();
    let mut observe = |name: &'a str, ty: &'a str, ptr_prefix: &'a str| {
        let entry = map.entry(name).or_default();
        if let Some((elem, _)) = vec_elem_lanes(ty) {
            push_new(&mut entry.vectors, elem);
        } else if is_simple_scalar(ty.trim()) {
            push_new(&mut entry.scalars, ty.trim());
        } else {
            entry.other = true;
        }
        entry.logical |= !is_word_addressable_ptr(ptr_prefix);
    };
    for (line, def) in body.iter().zip(line_defs) {
        if let Some(def) = def {
            match def.opcode {
                "load" => {
                    let chunks = split_top_level(def.rest, ',');
                    if chunks.len() >= 2 {
                        if let Some((prefix, ptr)) = split_ptr_operand(chunks[1]) {
                            observe(ptr, chunks[0].trim(), prefix);
                        }
                    }
                }
                "getelementptr" => {
                    if let Some(g) = parse_gep(def.rest) {
                        let prefix = split_ptr_operand(g.base_chunk).map_or("", |(p, _)| p);
                        observe(g.base_name, g.src_ty, prefix);
                    }
                }
                _ => {}
            }
            continue;
        }
        if let Some(rest) = line.trim().strip_prefix("store ") {
            let chunks = split_top_level(rest, ',');
            if chunks.len() >= 2 {
                if let (Some((ty, _)), Some((prefix, ptr))) =
                    (split_ptr_operand(chunks[0]), split_ptr_operand(chunks[1]))
                {
                    observe(ptr, ty, prefix);
                }
            }
        }
    }
    map
}

fn memory_reloaded_pointers<'a>(line_defs: &[Option<Def<'a>>]) -> HashSet<&'a str> {
    let mut out = HashSet::default();
    for def in line_defs.iter().flatten() {
        if def.opcode == "load" && split_top_level(def.rest, ',')[0].starts_with("ptr") {
            out.insert(def.name);
        }
    }
    out
}

fn widen_targets<'a>(
    body: &[&'a str],
    line_defs: &[Option<Def<'a>>],
    adj: &HashMap<&'a str, Vec<&'a str>>,
) -> Vec<(Vec<&'a str>, &'a str)> {
    let widths = use_widths(body, line_defs);
    // A target uses one pointer component at scalar and at vector width: with no use at both widths anywhere in
    // the function there is none to find.
    if !widths.values().any(|w| !w.vectors.is_empty())
        || !widths.values().any(|w| !w.scalars.is_empty())
    {
        return Vec::new();
    }
    let reloaded = memory_reloaded_pointers(line_defs);
    let mut nodes: Vec<&'a str> = adj.keys().copied().collect();
    nodes.extend(widths.keys().copied());
    nodes.sort_unstable();
    nodes.dedup();

    let mut visited: HashSet<&'a str> = HashSet::default();
    let mut targets: Vec<(Vec<&'a str>, &'a str)> = Vec::new();
    let mut members: Vec<&'a str> = Vec::new();
    for start in nodes {
        if !visited.insert(start) {
            continue;
        }
        members.clear();
        members.push(start);
        let mut next = 0;
        while next < members.len() {
            if let Some(nbs) = adj.get(members[next]) {
                for nb in nbs {
                    if visited.insert(*nb) {
                        members.push(*nb);
                    }
                }
            }
            next += 1;
        }
        let mut elem: Option<&'a str> = None;
        let mut several_elems = false;
        let (mut has_scalar, mut has_vector, mut other, mut logical) = (false, false, false, false);
        let mut memory_ptr = false;
        for m in &members {
            memory_ptr |= reloaded.contains(m);
            if let Some(w) = widths.get(m) {
                for e in w.scalars.iter().chain(&w.vectors) {
                    several_elems |= elem.is_some_and(|prev| prev != *e);
                    elem = Some(*e);
                }
                has_scalar |= !w.scalars.is_empty();
                has_vector |= !w.vectors.is_empty();
                other |= w.other;
                logical |= w.logical;
            }
        }
        if !other && !logical && !memory_ptr && has_scalar && has_vector && !several_elems {
            let Some(elem) = elem else { continue };
            if scalar_byte_width(elem).is_some_and(|w| w < 4) {
                continue;
            }
            targets.push((members.clone(), elem));
        }
    }
    targets
}

enum Index {
    Const(i128),
    Dyn { value: String, ity: String },
}

fn parse_index(operand: &str) -> Option<Index> {
    let mut it = operand.split_whitespace();
    let ity = it.next()?.to_string();
    let val = it.next()?.trim();
    if let Ok(c) = val.parse::<i128>() {
        Some(Index::Const(c))
    } else if val.starts_with('%') {
        Some(Index::Dyn {
            value: val.to_string(),
            ity,
        })
    } else {
        None
    }
}

const VSM_NAME_PREFIX: &str = ".vsm";

struct Rewriter {
    counter: usize,
}

impl Rewriter {
    fn fresh(&mut self) -> String {
        let n = self.counter;
        self.counter += 1;
        format!("%{VSM_NAME_PREFIX}{n}")
    }

    fn rewrite_gep(&mut self, name: &str, g: &GepInfo, elem: &str, lanes: usize) -> Vec<String> {
        let inbounds = if g.inbounds { "inbounds " } else { "" };
        let mut lines = Vec::new();
        let i0 = parse_index(g.indices[0]).unwrap();
        let (mut acc_const, mut acc_dyn): (i128, Option<(String, String)>) = match i0 {
            Index::Const(c) => (c * lanes as i128, None),
            Index::Dyn { value, ity } => {
                let m = self.fresh();
                lines.push(format!("  {m} = mul {ity} {value}, {lanes}"));
                (0, Some((m, ity)))
            }
        };
        if g.indices.len() >= 2 {
            if let Some(i1) = parse_index(g.indices[1]) {
                match i1 {
                    Index::Const(c) => acc_const += c,
                    Index::Dyn { value, ity } => {
                        acc_dyn = Some(match acc_dyn {
                            Some((acc, _)) => {
                                let a = self.fresh();
                                lines.push(format!("  {a} = add {ity} {acc}, {value}"));
                                (a, ity)
                            }
                            None => {
                                if acc_const == 0 {
                                    (value, ity)
                                } else {
                                    let a = self.fresh();
                                    lines.push(format!("  {a} = add {ity} {value}, {acc_const}"));
                                    acc_const = 0;
                                    (a, ity)
                                }
                            }
                        });
                    }
                }
            }
        }
        let (idx_ty, idx_val) = match acc_dyn {
            Some((v, ity)) if acc_const == 0 => (ity, v),
            Some((v, ity)) => {
                let a = self.fresh();
                lines.push(format!("  {a} = add {ity} {v}, {acc_const}"));
                (ity, a)
            }
            None => ("i64".to_string(), acc_const.to_string()),
        };
        let _ = elem;
        lines.push(format!(
            "  {name} = getelementptr {inbounds}{elem}, {base}, {idx_ty} {idx_val}",
            base = g.base_chunk
        ));
        lines
    }

    fn split_load(
        &mut self,
        name: &str,
        elem: &str,
        lanes: usize,
        ptr_prefix: &str,
        ptr_name: &str,
    ) -> Vec<String> {
        let mut lines = Vec::new();
        let mut elem_ids = Vec::with_capacity(lanes);
        for k in 0..lanes {
            let p = self.fresh();
            let l = self.fresh();
            lines.push(format!(
                "  {p} = getelementptr inbounds {elem}, {ptr_prefix} {ptr_name}, i64 {k}"
            ));
            lines.push(format!("  {l} = load {elem}, {ptr_prefix} {p}, align 4"));
            elem_ids.push(l);
        }
        let vty = format!("<{lanes} x {elem}>");
        let mut prev = "undef".to_string();
        for (k, elem_id) in elem_ids.iter().enumerate() {
            let out = if k + 1 == lanes {
                name.to_string()
            } else {
                self.fresh()
            };
            lines.push(format!(
                "  {out} = insertelement {vty} {prev}, {elem} {elem_id}, i32 {k}"
            ));
            prev = out;
        }
        lines
    }

    fn split_store(
        &mut self,
        value: &str,
        elem: &str,
        lanes: usize,
        ptr_prefix: &str,
        ptr_name: &str,
    ) -> Vec<String> {
        let vty = format!("<{lanes} x {elem}>");
        let mut lines = Vec::new();
        for k in 0..lanes {
            let x = self.fresh();
            let p = self.fresh();
            lines.push(format!("  {x} = extractelement {vty} {value}, i32 {k}"));
            lines.push(format!(
                "  {p} = getelementptr inbounds {elem}, {ptr_prefix} {ptr_name}, i64 {k}"
            ));
            lines.push(format!("  store {elem} {x}, {ptr_prefix} {p}, align 4"));
        }
        lines
    }
}

fn rewrite_function_body(body: &[&str], widen: bool) -> Option<Vec<String>> {
    let line_defs: Vec<Option<Def<'_>>> = body.iter().map(|line| parse_def(line)).collect();
    let defs: BTreeMap<&str, DefInfo<'_>> = line_defs
        .iter()
        .flatten()
        .map(|def| (def.name, DefInfo::new(*def)))
        .collect();

    let mut comp_elem: HashMap<&str, &str> = HashMap::default();
    let adj = pointer_adjacency(&defs);

    let (pointees, mismatches) = classify(&defs);
    if let Some(elem) = unify_mismatch_elem(&mismatches, &pointees) {
        for m in component(&adj, &mismatches) {
            comp_elem.entry(m).or_insert(elem);
        }
    }
    if widen {
        for (members, elem) in widen_targets(body, &line_defs, &adj) {
            for m in members {
                comp_elem.entry(m).or_insert(elem);
            }
        }
    }

    if comp_elem.is_empty() {
        return None;
    }
    if body.iter().any(|l| l.contains(VSM_NAME_PREFIX)) {
        return None;
    }
    let mut rw = Rewriter { counter: 0 };
    let mut out: Vec<String> = Vec::with_capacity(body.len());
    for line in body {
        if let Some(rewritten) = rewrite_line(line, &comp_elem, &mut rw) {
            out.extend(rewritten);
        } else {
            out.push(line.to_string());
        }
    }
    Some(out)
}

fn unify_mismatch_elem<'a>(
    mismatches: &HashSet<&'a str>,
    pointees: &HashMap<&'a str, Pointee<'a>>,
) -> Option<&'a str> {
    let mut elem: Option<&'a str> = None;
    for m in mismatches {
        if let Some(Pointee::Scalar(e)) = pointees.get(m) {
            match elem {
                Some(prev) if prev != *e => return None,
                _ => elem = Some(*e),
            }
        }
    }
    elem
}

fn rewrite_line(
    line: &str,
    comp_elem: &HashMap<&str, &str>,
    rw: &mut Rewriter,
) -> Option<Vec<String>> {
    let trimmed = line.trim();
    if let Some(def) = parse_def(line) {
        match def.opcode {
            "getelementptr" => {
                let elem = comp_elem.get(def.name)?;
                let g = parse_gep(def.rest)?;
                let (e, lanes) = vec_elem_lanes(g.src_ty)?;
                if e != *elem {
                    return None;
                }
                return Some(rw.rewrite_gep(def.name, &g, e, lanes));
            }
            "load" => {
                let chunks = split_top_level(def.rest, ',');
                if chunks.len() < 2 {
                    return None;
                }
                let (e, lanes) = vec_elem_lanes(chunks[0].trim())?;
                let (ptr_prefix, ptr_name) = split_ptr_operand(chunks[1])?;
                let elem = comp_elem.get(ptr_name)?;
                if e != *elem {
                    return None;
                }
                return Some(rw.split_load(def.name, e, lanes, ptr_prefix, ptr_name));
            }
            _ => return None,
        }
    }
    if let Some(rest) = trimmed.strip_prefix("store ") {
        let chunks = split_top_level(rest, ',');
        if chunks.len() < 2 {
            return None;
        }
        let (ty, value) = split_ptr_operand(chunks[0])?;
        let (e, lanes) = vec_elem_lanes(ty)?;
        let (ptr_prefix, ptr_name) = split_ptr_operand(chunks[1])?;
        let elem = comp_elem.get(ptr_name)?;
        if e != *elem {
            return None;
        }
        return Some(rw.split_store(value, e, lanes, ptr_prefix, ptr_name));
    }
    None
}

#[cfg(test)]
pub(in crate::native) fn lower_with_widen_for_test(san_ll: &str) -> String {
    lower_impl(san_ll, true).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_cyclic_scalar_vector_merge_resolves_the_same_way_every_run() {
        let src = "\
define void @k(ptr addrspace(1) %fp, ptr addrspace(1) %ip, i64 %n) {
entry:
  %sf = getelementptr inbounds float, ptr addrspace(1) %fp, i64 %n
  %si = getelementptr inbounds i32, ptr addrspace(1) %ip, i64 %n
  %vf = getelementptr inbounds <4 x float>, ptr addrspace(1) %fp, i64 %n
  br label %loop
loop:
  %a = phi ptr addrspace(1) [ %vf, %entry ], [ %b, %loop ]
  %b = phi ptr addrspace(1) [ %si, %entry ], [ %a, %loop ]
  %c = phi ptr addrspace(1) [ %sf, %entry ], [ %a, %loop ]
  %v = load <4 x float>, ptr addrspace(1) %c, align 16
  store <4 x float> %v, ptr addrspace(1) %c, align 16
  br label %loop
}
";
        let out = lower_vector_scalar_pointer_merge(src);
        assert!(
            !out.contains("load <4 x float>"),
            "the mismatch fixpoint was not the one reached:\n{out}"
        );
        assert!(
            !out.contains("store <4 x float>"),
            "the mismatch fixpoint was not the one reached:\n{out}"
        );
        assert!(
            !out.contains("getelementptr inbounds <4 x float>"),
            "the mismatch fixpoint was not the one reached:\n{out}"
        );
    }

    #[test]
    fn scalar_vector_pointer_merge_is_scalarized() {
        let src = "\
define void @k(ptr addrspace(1) %src, ptr addrspace(1) %dst, i64 %n) {
entry:
  %s0 = getelementptr inbounds float, ptr addrspace(1) %src, i64 %n
  %d0 = getelementptr inbounds float, ptr addrspace(1) %dst, i64 %n
  br label %loop
loop:
  %p = phi ptr addrspace(1) [ %pn, %loop ], [ %s0, %entry ]
  %q = phi ptr addrspace(1) [ %qn, %loop ], [ %d0, %entry ]
  %v = load <4 x float>, ptr addrspace(1) %p, align 16
  store <4 x float> %v, ptr addrspace(1) %q, align 16
  %pn = getelementptr inbounds <4 x float>, ptr addrspace(1) %p, i64 %n
  %qn = getelementptr inbounds <4 x float>, ptr addrspace(1) %q, i64 %n
  br label %loop
}
";
        let out = lower_vector_scalar_pointer_merge(src);
        assert!(
            !out.contains("load <4 x float>"),
            "vector load not split:\n{out}"
        );
        assert!(
            !out.contains("store <4 x float>"),
            "vector store not split:\n{out}"
        );
        assert!(
            !out.contains("getelementptr inbounds <4 x float>"),
            "vector gep not scalarized:\n{out}"
        );
        assert!(out.contains("mul i64 %n, 4"), "stride not scaled:\n{out}");
        assert_eq!(
            out.matches("load float,").count(),
            4,
            "want 4 loads:\n{out}"
        );
        assert!(
            out.contains("%v = insertelement <4 x float>"),
            "vector not rebuilt into %v:\n{out}"
        );
        assert_eq!(
            out.matches("extractelement <4 x float>").count(),
            4,
            "want 4 extracts:\n{out}"
        );
    }

    #[test]
    fn unrelated_module_is_untouched() {
        let src = "\
define void @k(ptr addrspace(1) %src) {
entry:
  %p = getelementptr inbounds <4 x float>, ptr addrspace(1) %src, i64 0
  %v = load <4 x float>, ptr addrspace(1) %p, align 16
  ret void
}
";
        assert_eq!(lower_vector_scalar_pointer_merge(src), src);
    }

    #[test]
    fn use_width_whole_vs_part_phi_is_scalarized_only_when_widen() {
        let src = "\
define void @k(ptr addrspace(1) %m, ptr addrspace(1) %n, i1 %c, i64 %i) {
entry:
  %a = getelementptr inbounds float, ptr addrspace(1) %m, i64 %i
  %b = getelementptr inbounds float, ptr addrspace(1) %n, i64 %i
  br label %loop
loop:
  %p = phi ptr addrspace(1) [ %a, %entry ], [ %b, %loop ]
  %v = load <4 x float>, ptr addrspace(1) %p, align 16
  br label %loop
}
";
        assert_eq!(lower_impl(src, false), src);

        let out = lower_impl(src, true);
        assert!(
            !out.contains("load <4 x float>"),
            "vector load not split under widen:\n{out}"
        );
        assert_eq!(
            out.matches("load float,").count(),
            4,
            "want 4 scalar loads:\n{out}"
        );
        assert!(
            out.contains("%v = insertelement <4 x float>"),
            "vector not rebuilt into %v:\n{out}"
        );
        assert!(out.contains("%a = getelementptr inbounds float"), "{out}");
        assert!(out.contains("%b = getelementptr inbounds float"), "{out}");
    }

    #[test]
    fn use_width_single_pointer_mixed_width_is_scalarized() {
        let src = "\
define void @k(ptr addrspace(1) %buf) {
entry:
  %v = load <4 x float>, ptr addrspace(1) %buf, align 16
  %s = load float, ptr addrspace(1) %buf, align 4
  ret void
}
";
        assert_eq!(lower_impl(src, false), src);
        let out = lower_impl(src, true);
        assert!(!out.contains("load <4 x float>"), "{out}");
        assert_eq!(out.matches("load float,").count(), 5, "{out}");
    }

    #[test]
    fn use_width_reinterpret_mix_is_not_widened() {
        let src = "\
define void @k(ptr addrspace(1) %buf) {
entry:
  %v = load <4 x float>, ptr addrspace(1) %buf, align 16
  %w = load i32, ptr addrspace(1) %buf, align 4
  ret void
}
";
        assert_eq!(lower_impl(src, true), src);
    }

    #[test]
    fn use_width_logical_workgroup_pointer_is_not_widened() {
        let src = "\
define void @k(ptr addrspace(3) %tg) {
entry:
  %v = load <4 x float>, ptr addrspace(3) %tg, align 16
  %s = load float, ptr addrspace(3) %tg, align 4
  ret void
}
";
        assert_eq!(lower_impl(src, true), src);
    }

    #[test]
    fn use_width_aggregate_gep_component_is_excluded() {
        let src = "\
define void @k(ptr addrspace(1) %buf) {
entry:
  %p = getelementptr inbounds [16 x float], ptr addrspace(1) %buf, i64 0, i64 0
  %v = load <4 x float>, ptr addrspace(1) %p, align 16
  %q = getelementptr inbounds [16 x float], ptr addrspace(1) %buf, i64 0, i64 4
  %s = load float, ptr addrspace(1) %q, align 4
  ret void
}
";
        assert_eq!(lower_impl(src, true), src);
    }

    #[test]
    fn use_width_memory_reloaded_pointer_component_is_excluded() {
        let src = "\
define void @k(ptr addrspace(1) %slot, i64 %i) {
entry:
  %p = load ptr addrspace(1), ptr addrspace(1) %slot, align 8
  %s = load float, ptr addrspace(1) %p, align 4
  %g = getelementptr inbounds <4 x float>, ptr addrspace(1) %p, i64 %i
  %v = load <4 x float>, ptr addrspace(1) %g, align 16
  ret void
}
";
        assert_eq!(lower_impl(src, true), src);
        let ssa = src.replace(
            "  %p = load ptr addrspace(1), ptr addrspace(1) %slot, align 8\n",
            "",
        );
        let ssa = ssa.replace("%slot, i64 %i", "%p, i64 %i");
        assert!(
            !lower_impl(&ssa, true).contains("load <4 x float>"),
            "SSA-visible whole-vs-part should still widen:\n{}",
            lower_impl(&ssa, true)
        );
    }

    #[test]
    fn use_width_subword_component_is_excluded() {
        let i8_src = "\
define void @k(ptr addrspace(1) %b, i64 %i) {
entry:
  %v = load <4 x i8>, ptr addrspace(1) %b, align 4
  %p = getelementptr inbounds i8, ptr addrspace(1) %b, i64 4
  %s = load i8, ptr addrspace(1) %p, align 1
  ret void
}
";
        assert_eq!(lower_impl(i8_src, true), i8_src);
        let f32_src = i8_src
            .replace("<4 x i8>", "<4 x float>")
            .replace("inbounds i8", "inbounds float")
            .replace("load i8", "load float")
            .replace("align 4", "align 16");
        assert!(
            !lower_impl(&f32_src, true).contains("load <4 x float>"),
            "float whole-vs-part should still widen:\n{}",
            lower_impl(&f32_src, true)
        );
    }

    #[test]
    fn scalar_byte_width_recognizes_primitive_tokens() {
        assert_eq!(scalar_byte_width("i8"), Some(1));
        assert_eq!(scalar_byte_width("half"), Some(2));
        assert_eq!(scalar_byte_width("i16"), Some(2));
        assert_eq!(scalar_byte_width("float"), Some(4));
        assert_eq!(scalar_byte_width("i32"), Some(4));
        assert_eq!(scalar_byte_width("i64"), Some(8));
        assert_eq!(scalar_byte_width("i24"), Some(3));
        assert_eq!(scalar_byte_width("ptr"), None);
    }

    #[test]
    fn pure_vector_merge_is_untouched() {
        let src = "\
define void @k(ptr addrspace(1) %a, ptr addrspace(1) %b, i1 %c) {
entry:
  %pa = getelementptr inbounds <4 x float>, ptr addrspace(1) %a, i64 0
  %pb = getelementptr inbounds <4 x float>, ptr addrspace(1) %b, i64 0
  %m = select i1 %c, ptr addrspace(1) %pa, ptr addrspace(1) %pb
  %v = load <4 x float>, ptr addrspace(1) %m, align 16
  ret void
}
";
        assert!(matches!(
            lower_vector_scalar_pointer_merge(src),
            Cow::Borrowed(value) if std::ptr::eq(value, src)
        ));
    }
}
