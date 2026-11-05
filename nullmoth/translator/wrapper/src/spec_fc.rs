// Metal function constants as SPIR-V specialization constants.
//
// A module translated without constant values keeps each function constant as a Private variable named
// `<name>.MTL_FC_INIT_<index>_<abi>`, zero-initialized and only ever loaded (the static initializer loads it once at
// the top of the entry point), and each `is_function_constant_defined(<index>)` as `OpCopyObject %bool %false` named
// `__metal2vulkan.MTL_FC_DEFINED_<index>`. This pass gives every such variable a specialization constant as its
// initializer and every such marker a boolean specialization constant as its operand, so one translation of the
// function serves every set of constant values: the values reach the driver as specialization constants, which it
// folds before it compiles (dead branches, unused inputs and resources go with them), as Metal's own compiler does.
//
// SpecId layout (the plugin reads it back from the decorations):
//   0x0080_0000 | (index << 3) | lane    value of constant `index`, lane `lane` (0 for scalars, 0..3 for vectors)
//   0x0100_0000 | index                  1 when constant `index` has a value (is_function_constant_defined)
// (clear of the SpecIds the translator gives a kernel's workgroup size, 0-3)
// A variable whose type is not a scalar or vector of int/float/bool, that has another use than OpLoad, or a module
// with a function constant this pass cannot carry is refused, and the caller translates with the values baked in.

use std::collections::{HashMap, HashSet};

pub const SPEC_ID_DEFINED: u32 = 0x0100_0000;
pub const SPEC_ID_VALUE: u32 = 0x0080_0000;

const OP_NAME: u32 = 5;
const OP_TYPE_BOOL: u32 = 20;
const OP_TYPE_INT: u32 = 21;
const OP_TYPE_FLOAT: u32 = 22;
const OP_TYPE_VECTOR: u32 = 23;
const OP_TYPE_POINTER: u32 = 32;
const OP_CONSTANT_TRUE: u32 = 41;
const OP_CONSTANT_FALSE: u32 = 42;
const OP_SPEC_CONSTANT_FALSE: u32 = 49;
const OP_SPEC_CONSTANT: u32 = 50;
const OP_SPEC_CONSTANT_COMPOSITE: u32 = 51;
const OP_FUNCTION: u32 = 54;
const OP_VARIABLE: u32 = 59;
const OP_LOAD: u32 = 61;
const OP_DECORATE: u32 = 71;
const OP_COPY_OBJECT: u32 = 83;
const DECORATION_SPEC_ID: u32 = 1;
const STORAGE_PRIVATE: u32 = 6;

#[derive(Clone, Copy)]
enum Scalar { Bool, Int(u32), Float(u32) }

struct Inst { start: usize, len: usize, op: u32 }

fn decode_string(words: &[u32]) -> String {
    let mut bytes = Vec::new();
    'w: for w in words {
        for b in w.to_le_bytes() {
            if b == 0 { break 'w; }
            bytes.push(b);
        }
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

fn fc_init_index(name: &str) -> Option<u32> {
    let rest = name.split(".MTL_FC_INIT_").nth(1)?;
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

fn fc_defined_index(name: &str) -> Option<u32> {
    name.strip_prefix("__metal2vulkan.MTL_FC_DEFINED_")?.parse().ok()
}

fn is_annotation(op: u32) -> bool {
    matches!(op, 71 | 72 | 73 | 74 | 75 | 332 | 5632 | 5633)
}

/// Rewrites `spv` (little-endian bytes); returns the new module and the number of constants it now specializes.
pub fn function_constants_to_spec_constants(spv: &[u8]) -> Result<(Vec<u8>, usize), String> {
    if spv.len() < 20 || spv.len() % 4 != 0 {
        return Err("not a SPIR-V module".into());
    }
    let words: Vec<u32> = spv.chunks_exact(4).map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect();
    if words[0] != 0x0723_0203 {
        return Err("not a SPIR-V module (magic)".into());
    }
    let mut insts = Vec::new();
    let mut i = 5;
    while i < words.len() {
        let len = (words[i] >> 16) as usize;
        if len == 0 || i + len > words.len() {
            return Err(format!("malformed instruction at word {i}"));
        }
        insts.push(Inst { start: i, len, op: words[i] & 0xffff });
        i += len;
    }
    let w = |inst: &Inst, k: usize| words[inst.start + k];

    let mut names: HashMap<u32, String> = HashMap::new();
    let mut scalars: HashMap<u32, Scalar> = HashMap::new();
    let mut vectors: HashMap<u32, (u32, u32)> = HashMap::new();
    let mut pointers: HashMap<u32, (u32, u32)> = HashMap::new();
    let mut const_bool: HashMap<u32, bool> = HashMap::new();
    for inst in &insts {
        match inst.op {
            OP_NAME if inst.len >= 3 => {
                names.insert(w(inst, 1), decode_string(&words[inst.start + 2..inst.start + inst.len]));
            }
            OP_TYPE_BOOL => { scalars.insert(w(inst, 1), Scalar::Bool); }
            OP_TYPE_INT => { scalars.insert(w(inst, 1), Scalar::Int(w(inst, 2))); }
            OP_TYPE_FLOAT => { scalars.insert(w(inst, 1), Scalar::Float(w(inst, 2))); }
            OP_TYPE_VECTOR => { vectors.insert(w(inst, 1), (w(inst, 2), w(inst, 3))); }
            OP_TYPE_POINTER => { pointers.insert(w(inst, 1), (w(inst, 2), w(inst, 3))); }
            OP_CONSTANT_TRUE => { const_bool.insert(w(inst, 2), true); }
            OP_CONSTANT_FALSE => { const_bool.insert(w(inst, 2), false); }
            _ => {}
        }
    }

    // the function-constant variables and the definedness markers
    let mut fc_vars: HashMap<u32, (u32, u32)> = HashMap::new(); // var id -> (index, pointee type)
    let mut markers: Vec<(usize, u32)> = Vec::new(); // instruction position, index
    for (pos, inst) in insts.iter().enumerate() {
        if inst.op == OP_VARIABLE && inst.len >= 4 {
            let id = w(inst, 2);
            let Some(index) = names.get(&id).and_then(|n| fc_init_index(n)) else { continue };
            let (storage, pointee) = *pointers.get(&w(inst, 1)).ok_or("function constant variable of unknown type")?;
            if storage != STORAGE_PRIVATE || w(inst, 3) != STORAGE_PRIVATE {
                return Err(format!("function constant {index} is not a Private variable"));
            }
            if fc_vars.values().any(|(i, _)| *i == index) {
                return Err(format!("function constant {index} has two variables"));
            }
            fc_vars.insert(id, (index, pointee));
        } else if inst.op == OP_COPY_OBJECT && inst.len == 4 {
            let Some(index) = names.get(&w(inst, 2)).and_then(|n| fc_defined_index(n)) else { continue };
            if const_bool.get(&w(inst, 3)) != Some(&false) {
                return Err(format!("definedness of function constant {index} is not a plain false"));
            }
            markers.push((pos, index));
        }
    }
    if fc_vars.is_empty() && markers.is_empty() {
        return Ok((spv.to_vec(), 0));
    }

    // Every use of a function-constant variable in the functions must be the pointer of an OpLoad. (At module scope a
    // pointer can only appear in the entry point's interface, names and decorations.) Operand kinds come from the
    // grammar (rspirv), so a literal that equals a variable's id is not taken for a use.
    let parsed = rspirv::dr::load_words(&words).map_err(|e| format!("SPIR-V parse: {e}"))?;
    for f in &parsed.functions {
        for b in &f.blocks {
            for inst in &b.instructions {
                for (k, op) in inst.operands.iter().enumerate() {
                    let rspirv::dr::Operand::IdRef(id) = op else { continue };
                    if fc_vars.contains_key(id) && !(inst.class.opcode as u32 == OP_LOAD && k == 0) {
                        return Err(format!(
                            "function constant {} is used by {:?} (not a load)",
                            fc_vars[id].0, inst.class.opcode
                        ));
                    }
                }
            }
        }
    }

    let mut bound = words[3];
    let mut fresh = || { let id = bound; bound += 1; id };
    let mut decorations: Vec<u32> = Vec::new();
    let mut before: HashMap<usize, Vec<u32>> = HashMap::new(); // instructions to insert before instruction #pos
    let mut new_init: HashMap<u32, u32> = HashMap::new(); // var id -> spec constant id
    let mut specialized = 0usize;
    let push = |out: &mut Vec<u32>, op: u32, ops: &[u32]| {
        out.push(((ops.len() as u32 + 1) << 16) | op);
        out.extend_from_slice(ops);
    };
    let scalar_spec = |out: &mut Vec<u32>, decs: &mut Vec<u32>, ty: u32, s: Scalar, id: u32, spec_id: u32| -> Result<(), String> {
        match s {
            Scalar::Bool => push(out, OP_SPEC_CONSTANT_FALSE, &[ty, id]),
            Scalar::Int(bits) | Scalar::Float(bits) => match bits {
                8 | 16 | 32 => push(out, OP_SPEC_CONSTANT, &[ty, id, 0]),
                64 => push(out, OP_SPEC_CONSTANT, &[ty, id, 0, 0]),
                _ => return Err(format!("{bits}-bit function constant")),
            },
        }
        push(decs, OP_DECORATE, &[id, DECORATION_SPEC_ID, spec_id]);
        Ok(())
    };
    for (pos, inst) in insts.iter().enumerate() {
        if inst.op != OP_VARIABLE || !fc_vars.contains_key(&w(inst, 2)) {
            continue;
        }
        let var = w(inst, 2);
        let (index, ty) = fc_vars[&var];
        if index >= SPEC_ID_VALUE >> 3 {
            return Err(format!("function constant index {index} is out of range"));
        }
        let mut out = Vec::new();
        let id = if let Some(s) = scalars.get(&ty).copied() {
            let id = fresh();
            scalar_spec(&mut out, &mut decorations, ty, s, id, SPEC_ID_VALUE | (index << 3))?;
            id
        } else if let Some(&(comp, count)) = vectors.get(&ty) {
            let s = *scalars.get(&comp).ok_or_else(|| format!("function constant {index}: vector of a non-scalar"))?;
            if count > 4 {
                return Err(format!("function constant {index}: {count}-lane vector"));
            }
            let mut lanes = Vec::new();
            for lane in 0..count {
                let lid = fresh();
                scalar_spec(&mut out, &mut decorations, comp, s, lid, SPEC_ID_VALUE | (index << 3) | lane)?;
                lanes.push(lid);
            }
            let id = fresh();
            let mut ops = vec![ty, id];
            ops.extend(lanes);
            push(&mut out, OP_SPEC_CONSTANT_COMPOSITE, &ops);
            id
        } else {
            return Err(format!("function constant {index} is neither a scalar nor a vector"));
        };
        before.entry(pos).or_default().extend(out);
        new_init.insert(var, id);
        specialized += 1;
    }
    // one boolean specialization constant per constant whose definedness is asked, placed before the first function
    let first_fn = insts.iter().position(|i| i.op == OP_FUNCTION).ok_or("module has no function")?;
    let bool_ty = scalars.iter().find(|(_, s)| matches!(s, Scalar::Bool)).map(|(id, _)| *id);
    let mut defined_ids: HashMap<u32, u32> = HashMap::new();
    let mut seen: HashSet<u32> = HashSet::new();
    for (_, index) in &markers {
        if !seen.insert(*index) {
            continue;
        }
        let bool_ty = bool_ty.ok_or("definedness marker without a bool type")?;
        let id = fresh();
        let mut out = Vec::new();
        push(&mut out, OP_SPEC_CONSTANT_FALSE, &[bool_ty, id]);
        push(&mut decorations, OP_DECORATE, &[id, DECORATION_SPEC_ID, SPEC_ID_DEFINED | index]);
        before.entry(first_fn).or_default().extend(out);
        defined_ids.insert(*index, id);
    }
    let marker_at: HashMap<usize, u32> = markers.iter().map(|(p, i)| (*p, defined_ids[i])).collect();

    // annotations go after the last annotation (or before the first type if there is none)
    let annot_at = match insts.iter().rposition(|i| is_annotation(i.op)) {
        Some(p) => p + 1,
        None => insts.iter().position(|i| (19..=39).contains(&i.op)).ok_or("module has no types")?,
    };

    let mut out: Vec<u32> = Vec::with_capacity(words.len() + decorations.len() + 64);
    out.extend_from_slice(&words[..5]);
    for (pos, inst) in insts.iter().enumerate() {
        if pos == annot_at {
            out.extend_from_slice(&decorations);
        }
        if let Some(extra) = before.get(&pos) {
            out.extend_from_slice(extra);
        }
        let body = &words[inst.start..inst.start + inst.len];
        if inst.op == OP_VARIABLE && new_init.contains_key(&body[2]) {
            // OpVariable %ptr %id Private [%init]: the initializer is now the specialization constant
            out.push((5u32 << 16) | OP_VARIABLE);
            out.extend_from_slice(&[body[1], body[2], body[3], new_init[&body[2]]]);
        } else if let Some(&spec) = marker_at.get(&pos) {
            out.extend_from_slice(&[body[0], body[1], body[2], spec]);
        } else {
            out.extend_from_slice(body);
        }
    }
    if annot_at == insts.len() {
        out.extend_from_slice(&decorations);
    }
    out[3] = bound;
    Ok((out.iter().flat_map(|w| w.to_le_bytes()).collect(), specialized + defined_ids.len()))
}

/// The function constants a module's shape depends on: those the static initializer (`section "air.static_init"`)
/// folds into a `[[function_constant]]` predicate (`__metal_implicit_fc_pred_<n>`: which arguments, stage inputs and
/// outputs exist). Their values are baked into the translation (so the interface and resource bindings are those of
/// the variant); every other function constant is carried as a specialization constant. Text analysis of the static
/// initializer's SSA (loads of `.MTL_FC_INIT_<index>` globals flowing into stores of the predicate globals).
pub fn structural_function_constants(ll: &str) -> Vec<u32> {
    let fc_index = |s: &str| -> Vec<u32> {
        s.match_indices(".MTL_FC_INIT_")
            .filter_map(|(at, m)| {
                let digits: String = s[at + m.len()..].chars().take_while(|c| c.is_ascii_digit()).collect();
                digits.parse().ok()
            })
            .collect()
    };
    let tokens = |s: &str, sigil: char| -> Vec<String> {
        let mut out = Vec::new();
        let b = s.as_bytes();
        let mut i = 0;
        while i < b.len() {
            if b[i] as char == sigil {
                let mut j = i + 1;
                while j < b.len() && (b[j].is_ascii_alphanumeric() || b[j] == b'_' || b[j] == b'.' || b[j] == b'$') { j += 1; }
                if j > i + 1 { out.push(s[i..j].to_string()); }
                i = j;
            } else {
                i += 1;
            }
        }
        out
    };
    let mut local: HashMap<String, HashSet<u32>> = HashMap::new();
    let mut global: HashMap<String, HashSet<u32>> = HashMap::new();
    let mut in_init = false;
    for raw in ll.lines() {
        let line = raw.trim();
        if line.starts_with("define ") {
            in_init = line.contains("section \"air.static_init\"");
            local.clear();
            continue;
        }
        if !in_init { continue; }
        if line == "}" { in_init = false; continue; }
        if let Some(rest) = line.strip_prefix("store ") {
            let (value, ptr) = rest.split_once(", ptr").unwrap_or((rest, ""));
            let mut deps: HashSet<u32> = fc_index(value).into_iter().collect();
            for t in tokens(value, '%') { if let Some(d) = local.get(&t) { deps.extend(d); } }
            for t in tokens(value, '@') { if let Some(d) = global.get(&t) { deps.extend(d); } }
            if let Some(target) = tokens(ptr, '@').into_iter().next() {
                global.entry(target).or_default().extend(deps);
            }
            continue;
        }
        let Some((name, rhs)) = line.split_once(" = ") else { continue };
        if !name.starts_with('%') { continue; }
        let mut deps: HashSet<u32> = fc_index(rhs).into_iter().collect();
        for t in tokens(rhs, '%') { if let Some(d) = local.get(&t) { deps.extend(d); } }
        for t in tokens(rhs, '@') { if let Some(d) = global.get(&t) { deps.extend(d); } }
        local.insert(name.to_string(), deps);
    }
    let mut set: HashSet<u32> = global
        .iter()
        .filter(|(g, _)| g.starts_with("@__metal_implicit_fc_pred_"))
        .flat_map(|(_, d)| d.iter().copied())
        .collect();
    // Boolean constants are baked too: with one unknown, the translator still folded `icmp ne i8 %c, 0` of it into
    // false where the static initializer derives a field from it (fixed_frag_lph_cph's FragmentShaderConfig flags), so
    // a variant whose boolean was 1 rendered as 0. Their values are few (2 each).
    for raw in ll.lines() {
        let t = raw.trim_start();
        if !t.starts_with('@') || !t.contains("air.fc_initializer") { continue; }
        let Some((name, _)) = t.split_once(" = ") else { continue };
        if let Some(rest) = name.split(".MTL_FC_INIT_").nth(1) {
            let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
            if rest[digits.len()..] == *"_b" { if let Ok(i) = digits.parse() { set.insert(i); } }
        }
    }
    let mut out: Vec<u32> = set.into_iter().collect();
    out.sort_unstable();
    out
}

/// `is_function_constant_defined(<index>)` is `true` for each index in `defined` (the constants a variant supplies),
/// as specialize_air_function_constants writes it for the constants it bakes.
pub fn mark_function_constants_defined(ll: &str, defined: &[u32]) -> String {
    if defined.is_empty() {
        return ll.to_string();
    }
    let set: HashSet<u32> = defined.iter().copied().collect();
    let mut out = String::with_capacity(ll.len());
    for line in ll.split_inclusive('\n') {
        if line.contains("@air.is_function_constant_defined(") && !line.trim_start().starts_with("declare ") {
            if let (Some(index), Some((result, _))) = (fc_init_index(line), line.split_once(" = ")) {
                if set.contains(&index) {
                    out.push_str(result);
                    out.push_str(" = icmp eq i32 0, 0");
                    if line.ends_with('\n') { out.push('\n'); }
                    continue;
                }
            }
        }
        out.push_str(line);
    }
    out
}

/// Each function constant still `undef` (not baked) is declared a mutable `global` instead of a `constant`: the
/// translator folds a load of a constant global to its initializer, and an `undef` one to 0 (`icmp ne i8 %c, 0` of a
/// boolean constant became `false`, so a variant whose boolean was 1 rendered as if it were 0). It is only ever loaded,
/// and becomes a specialization constant afterwards.
pub fn unfold_unbaked_function_constants(ll: &str) -> String {
    let mut out = String::with_capacity(ll.len() + 1024);
    for line in ll.split_inclusive('\n') {
        let t = line.trim_start();
        if t.starts_with('@') && t.contains(".MTL_FC_INIT_") && t.contains("air.fc_initializer") && t.contains(" undef") {
            if let Some(at) = line.find(" externally_initialized constant ") {
                out.push_str(&line[..at]);
                out.push_str(" externally_initialized global ");
                out.push_str(&line[at + " externally_initialized constant ".len()..]);
                continue;
            }
        }
        out.push_str(line);
    }
    out
}
