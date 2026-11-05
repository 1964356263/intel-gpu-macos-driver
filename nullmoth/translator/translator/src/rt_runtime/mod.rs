//! rtopt4: ray tracing through the Metal acceleration structure's header (the plugin's nvmtl_rt_layout.h), as an
//! LLVM-text pass before the native emitter (ray_query.rs lowers what it leaves):
//! - `air.intersect.*curve_data*` calls become intersection query loops (ift_runtime::rewrite_curve_intersects): curve
//!   geometry is bounding boxes in the Vulkan structure, nvmtl_rt_curve intersects the segment
//! - intersection queries with curve_data keep per-query state (candidate t / u / is-curve, committed u / is-curve):
//!   next() runs the curve intersection for curve boxes (skipping misses), the curve getters and commit read it
//! - user instance IDs (32-bit) and primitive data come from the header for every intersect result and query getter
//! - the curve_data tag is dropped from every AIR name (ray_query.rs never sees it)
//! The runtime functions (runtime_ll.rs, generated from nvmtl_rt_runtime.metal) are appended when used.
pub mod runtime_ll;

use crate::ift_runtime::{append_rt_runtime, entry_body, query_tags, splice_inline};

use std::collections::{HashMap, HashSet};

fn split_top(s: &str) -> Vec<String> {
    let (mut depth, mut cur, mut out) = (0i32, String::new(), Vec::new());
    for c in s.chars() {
        match c {
            '(' | '{' | '<' | '[' => depth += 1,
            ')' | '}' | '>' | ']' => depth -= 1,
            _ => {}
        }
        if c == ',' && depth == 0 {
            out.push(cur.trim().to_string());
            cur.clear();
        } else {
            cur.push(c);
        }
    }
    if !cur.trim().is_empty() {
        out.push(cur.trim().to_string());
    }
    out
}

fn last_token(a: &str) -> String {
    a.split_whitespace().last().unwrap_or("").to_string()
}

/// `%7` -> `nvrt7`: a named-value stem for values derived from an LLVM value
fn stem(v: &str) -> String {
    let s: String = v.trim_start_matches('%').chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect();
    format!("nvrt{s}")
}

struct Call {
    res: Option<String>,
    ret_ty: String,
    callee: String,
    args: Vec<String>,
}

fn parse_call(line: &str) -> Option<Call> {
    let t = line.trim_start();
    let (res, rest) = match t.split_once(" = ") {
        Some((r, rest)) if r.starts_with('%') && !r.contains(' ') => (Some(r.to_string()), rest),
        _ => (None, t),
    };
    let call_at = rest.find("call ")?;
    let at = rest.find("@air.")?;
    let open = at + rest[at..].find('(')?;
    let close = rest.rfind(')')?;
    let ret_ty = rest[call_at + 5..at]
        .split_whitespace()
        .filter(|w| !matches!(*w, "fast" | "nnan" | "ninf" | "nsz" | "arcp" | "contract" | "afn" | "reassoc" | "noundef" | "zeroext"))
        .collect::<Vec<_>>()
        .join(" ");
    Some(Call { res, ret_ty, callee: rest[at + 1..open].to_string(), args: split_top(&rest[open + 1..close]) })
}

/// the query intrinsic `air.<op>_intersection_query<tags>`: (op, tags with their leading dot)
fn query_op(callee: &str) -> Option<(String, String)> {
    let stem = callee.strip_prefix("air.")?;
    let at = stem.find("_intersection_query")?;
    Some((stem[..at].to_string(), stem[at + "_intersection_query".len()..].to_string()))
}

struct CurveQuery {
    st: String, // state stem
    tq: String, // query tags without curve_data
}

/// The pass on a module's text as the native pre-lowering sees it (no stage at hand: the module's one AIR entry).
/// Errors leave the text as it was (the downstream lowering then refuses what is not carried) and are logged.
pub(crate) fn rewrite_text(ll: &str) -> Option<String> {
    if !ll.contains("@air.intersect.") && !ll.contains("_intersection_query") {
        return None;
    }
    let entry = ["kernel", "vertex", "fragment"].iter().find_map(|s| crate::meta::entry_name(ll, s));
    match rewrite(ll, entry.as_deref()) {
        Ok(out) => {
            if let (Some(t), Some(dir)) = (out.as_ref(), std::env::var_os("METAL2VULKAN_RT_DUMP")) {
                let _ = std::fs::write(std::path::Path::new(&dir).join(format!("{}.rt.ll", entry.as_deref().unwrap_or("entry"))), t);
            }
            out
        }
        Err(e) => {
            eprintln!("nvmtl rt_runtime: {e}");
            None
        }
    }
}

pub(crate) fn rewrite(ll: &str, entry: Option<&str>) -> Result<Option<String>, String> {
    if !ll.contains("@air.intersect.") && !ll.contains("_intersection_query") {
        return Ok(None);
    }
    let Some(entry) = entry else { return Ok(None) };
    let mut out = ll.to_string();
    let mut runtime = false;
    if out.lines().any(|l| l.contains("call ") && l.contains("@air.intersect.")) {
        let rewritten = crate::ift_runtime::rewrite_curve_intersects(&out, entry)?;
        runtime = rewritten.len() != out.len();
        out = rewritten;
    }
    let (a, b) = entry_body(&out, entry)?;
    let mut lines: Vec<String> = out[a..b].lines().map(str::to_string).collect();
    let mut declares: Vec<String> = Vec::new();
    let mut n = 0usize;

    // 1. curve intersects and table-less intersects whose user ID or primitive data is read are query loops by now
    let _ = (&mut runtime, &mut n);
    // 2. queries: curve state, user IDs and primitive data
    let mut curves: HashMap<String, CurveQuery> = HashMap::new();
    let mut allocas: Vec<String> = Vec::new();
    for l in &lines {
        let Some(c) = parse_call(l) else { continue };
        let Some((op, tags)) = query_op(&c.callee) else { continue };
        if op == "allocate" && tags.split('.').any(|t| t == "curve_data") {
            let res = c.res.clone().ok_or("intersection query allocate without a result")?;
            let st = format!("nvrq{}", curves.len());
            for (v, ty) in [("ct", "float"), ("cu", "float"), ("cc", "i32"), ("mu", "float"), ("mc", "i32"), ("tm", "float")] {
                allocas.push(format!("  %{st}.{v} = alloca {ty}, align 4"));
            }
            curves.insert(res, CurveQuery { st, tq: query_tags(tags.trim_start_matches('.')) });
        }
    }
    let mut i = 1;
    while i < lines.len() {
        let line = lines[i].clone();
        if !line.contains("_intersection_query") || !line.contains("call ") {
            i += 1;
            continue;
        }
        let Some(c) = parse_call(&line) else { i += 1; continue };
        let Some((op, tags)) = query_op(&c.callee) else { i += 1; continue };
        if op == "allocate" || op == "deallocate" || op == "get_nvmtl_as_base" {
            i += 1;
            continue;
        }
        let qv = c.args.first().map(|a| last_token(a)).unwrap_or_default();
        let tq = query_tags(tags.trim_start_matches('.'));
        let instancing = tags.split('.').any(|t| t == "instancing");
        let g = |what: &str, ty: &str, decl: &mut Vec<String>| -> String {
            let name = format!("@air.{what}_intersection_query{tq}");
            decl.push(format!("declare {ty} {name}(ptr)"));
            format!("call {ty} {name}(ptr {qv})")
        };
        let cq = curves.get(&qv);
        let res = c.res.clone().unwrap_or_default();
        let x = stem(&res);
        // user IDs and primitive data: any query
        if op == "get_committed_user_instance_id" || op == "get_candidate_user_instance_id" {
            let which = if op.contains("committed") { "committed" } else { "candidate" };
            let mut t = format!("  %{x}.b = {}\n", g("get_nvmtl_as_base", "i64", &mut declares));
            if instancing {
                t.push_str(&format!("  %{x}.i = {}\n", g(&format!("get_{which}_instance_id"), "i32", &mut declares)));
            } else {
                t.push_str(&format!("  %{x}.i = add i32 0, 0\n"));
            }
            t.push_str(&format!("  {res} = call i32 @nvmtl_rt_user_id(i64 %{x}.b, i32 %{x}.i)"));
            lines[i] = t;
            runtime = true;
            i += 1;
            continue;
        }
        if op == "get_committed_primitive_data" || op == "get_candidate_primitive_data" {
            let which = if op.contains("committed") { "committed" } else { "candidate" };
            let mut t = format!("  %{x}.b = {}\n", g("get_nvmtl_as_base", "i64", &mut declares));
            if instancing {
                t.push_str(&format!("  %{x}.i = {}\n", g(&format!("get_{which}_instance_id"), "i32", &mut declares)));
            } else {
                t.push_str(&format!("  %{x}.i = add i32 0, 0\n"));
            }
            t.push_str(&format!("  %{x}.g = {}\n", g(&format!("get_{which}_geometry_id"), "i32", &mut declares)));
            t.push_str(&format!("  %{x}.p = {}\n", g(&format!("get_{which}_primitive_id"), "i32", &mut declares)));
            t.push_str(&format!(
                "  %{x}.a = call i64 @nvmtl_rt_primitive_data(i64 %{x}.b, i32 {}, i32 %{x}.i, i32 %{x}.g, i32 %{x}.p)\n  {res} = inttoptr i64 %{x}.a to {}",
                u32::from(instancing),
                c.ret_ty
            ));
            lines[i] = t;
            runtime = true;
            i += 1;
            continue;
        }
        let Some(cq) = cq else {
            if op.contains("curve") {
                return Err(format!("ray tracing: {} on a query without curve_data", c.callee));
            }
            i += 1;
            continue;
        };
        let st = cq.st.clone();
        let _ = &cq.tq;
        match op.as_str() {
            "reset" => {
                let tmax = c.args.get(4).map(|a| last_token(a)).ok_or("reset without a max distance")?;
                lines.insert(i + 1, format!(
                    "  store i32 0, ptr %{st}.cc, align 4\n  store i32 0, ptr %{st}.mc, align 4\n  store float {tmax}, ptr %{st}.tm, align 4"
                ));
                i += 2;
            }
            "next" => {
                let p = format!("nvrn{n}");
                n += 1;
                let mut t = format!("{p}.entry:\n  br label %{p}.head\n{p}.head:\n");
                t.push_str(&format!("  %{p}.m = {}\n  br i1 %{p}.m, label %{p}.cand, label %{p}.out\n", g("next", "i1", &mut declares)));
                t.push_str(&format!("{p}.cand:\n  %{p}.ty = {}\n", g("get_candidate_intersection_type", "i32", &mut declares)));
                t.push_str(&format!("  %{p}.isb = icmp eq i32 %{p}.ty, 2\n  br i1 %{p}.isb, label %{p}.box, label %{p}.other\n"));
                t.push_str(&format!("{p}.other:\n  store i32 0, ptr %{st}.cc, align 4\n  br label %{p}.out\n"));
                t.push_str(&format!("{p}.box:\n  %{p}.b = {}\n", g("get_nvmtl_as_base", "i64", &mut declares)));
                if instancing {
                    t.push_str(&format!("  %{p}.i = {}\n", g("get_candidate_instance_id", "i32", &mut declares)));
                } else {
                    t.push_str(&format!("  %{p}.i = add i32 0, 0\n"));
                }
                t.push_str(&format!("  %{p}.g = {}\n", g("get_candidate_geometry_id", "i32", &mut declares)));
                t.push_str(&format!("  %{p}.p = {}\n", g("get_candidate_primitive_id", "i32", &mut declares)));
                t.push_str(&format!("  %{p}.o = {}\n", g("get_candidate_ray_origin", "<3 x float>", &mut declares)));
                t.push_str(&format!("  %{p}.d = {}\n", g("get_candidate_ray_direction", "<3 x float>", &mut declares)));
                t.push_str(&format!("  %{p}.lo = {}\n", g("get_ray_min_distance", "float", &mut declares)));
                t.push_str(&format!("  %{p}.cty = {}\n", g("get_committed_intersection_type", "i32", &mut declares)));
                t.push_str(&format!("  %{p}.cd = {}\n", g("get_committed_distance", "float", &mut declares)));
                t.push_str(&format!(
                    "  %{p}.tm = load float, ptr %{st}.tm, align 4\n  %{p}.none = icmp eq i32 %{p}.cty, 0\n  %{p}.hi = select i1 %{p}.none, float %{p}.tm, float %{p}.cd\n"
                ));
                t.push_str(&format!(
                    "  %{p}.r = call <4 x float> @nvmtl_rt_curve(i64 %{p}.b, i32 {}, i32 %{p}.i, i32 %{p}.g, i32 %{p}.p, <3 x float> %{p}.o, <3 x float> %{p}.d, float %{p}.lo, float %{p}.hi)\n",
                    u32::from(instancing)
                ));
                t.push_str(&format!(
                    "  %{p}.s = extractelement <4 x float> %{p}.r, i64 2\n  %{p}.hit = fcmp oeq float %{p}.s, 2.000000e+00\n  br i1 %{p}.hit, label %{p}.chit, label %{p}.cno\n"
                ));
                t.push_str(&format!(
                    "{p}.cno:\n  %{p}.notc = fcmp oeq float %{p}.s, 0.000000e+00\n  br i1 %{p}.notc, label %{p}.other, label %{p}.head\n"
                ));
                t.push_str(&format!(
                    "{p}.chit:\n  %{p}.t = extractelement <4 x float> %{p}.r, i64 0\n  %{p}.u = extractelement <4 x float> %{p}.r, i64 1\n  store float %{p}.t, ptr %{st}.ct, align 4\n  store float %{p}.u, ptr %{st}.cu, align 4\n  store i32 1, ptr %{st}.cc, align 4\n  br label %{p}.out\n"
                ));
                t.push_str(&format!(
                    "{p}.out:\n  {res} = phi i1 [ false, %{p}.head ], [ true, %{p}.other ], [ true, %{p}.chit ]\n  br label %{p}.cont\n"
                ));
                runtime = true;
                i += splice_inline(&mut lines, i, &p, &t)?;
            }
            "get_candidate_intersection_type" => {
                lines[i] = format!(
                    "  %{x}.o = {}\n  %{x}.c = load i32, ptr %{st}.cc, align 4\n  %{x}.ic = icmp ne i32 %{x}.c, 0\n  {res} = select i1 %{x}.ic, i32 3, i32 %{x}.o",
                    g("get_candidate_intersection_type", "i32", &mut declares)
                );
                i += 1;
            }
            "get_committed_intersection_type" => {
                lines[i] = format!(
                    "  %{x}.o = {}\n  %{x}.c = load i32, ptr %{st}.mc, align 4\n  %{x}.ib = icmp eq i32 %{x}.o, 2\n  %{x}.ic = icmp ne i32 %{x}.c, 0\n  %{x}.b = and i1 %{x}.ib, %{x}.ic\n  {res} = select i1 %{x}.b, i32 3, i32 %{x}.o",
                    g("get_committed_intersection_type", "i32", &mut declares)
                );
                i += 1;
            }
            "get_candidate_curve_distance" => {
                lines[i] = format!("  {res} = load float, ptr %{st}.ct, align 4");
                i += 1;
            }
            "get_candidate_curve_parameter" => {
                lines[i] = format!("  {res} = load float, ptr %{st}.cu, align 4");
                i += 1;
            }
            "get_committed_curve_parameter" => {
                lines[i] = format!("  {res} = load float, ptr %{st}.mu, align 4");
                i += 1;
            }
            "commit_curve_intersection" => {
                let name = format!("@air.commit_bounding_box_intersection_intersection_query{tq}");
                declares.push(format!("declare void {name}(ptr, float)"));
                let y = format!("nvrc{n}");
                n += 1;
                lines[i] = format!(
                    "  %{y}.t = load float, ptr %{st}.ct, align 4\n  call void {name}(ptr {qv}, float %{y}.t)\n  %{y}.u = load float, ptr %{st}.cu, align 4\n  store float %{y}.u, ptr %{st}.mu, align 4\n  store i32 1, ptr %{st}.mc, align 4"
                );
                i += 1;
            }
            "commit_triangle_intersection" | "commit_bounding_box_intersection" => {
                lines.insert(i + 1, format!("  store i32 0, ptr %{st}.mc, align 4"));
                i += 2;
            }
            other if other.contains("curve") => {
                return Err(format!("ray tracing: {} is not carried", c.callee));
            }
            _ => i += 1,
        }
    }
    if !allocas.is_empty() {
        // the entry block: right after the define line (and its label when it has one)
        let at = if lines.get(1).is_some_and(|l| l.trim_end().ends_with(':') && !l.trim_start().starts_with(';')) { 2 } else { 1 };
        for (k, l) in allocas.into_iter().enumerate() {
            lines.insert(at + k, l);
        }
    }
    let mut text = String::with_capacity(out.len() + 4096);
    text.push_str(&out[..a]);
    text.push_str(&lines.join("\n"));
    text.push('\n');
    text.push_str(&out[b..]);
    // declarations (deduplicated by symbol), the runtime, then the curve_data tag dropped from every AIR name
    let mut have: HashSet<String> = text
        .lines()
        .filter(|l| l.trim_start().starts_with("declare ") || l.trim_start().starts_with("define "))
        .filter_map(|l| l.find('@').map(|a| l[a..].split('(').next().unwrap_or("").to_string()))
        .collect();
    for d in declares {
        let g = d.find('@').map(|a| d[a..].split('(').next().unwrap_or("").to_string()).unwrap_or_default();
        if have.insert(g) {
            text.push_str(&d);
            text.push('\n');
        }
    }
    if runtime {
        append_rt_runtime(&mut text);
        text = structure_loads_as_integers(&text, entry)?;
    }
    Ok(Some(strip_curve_tags(&text)))
}

/// With the runtime in the module (its integer-to-pointer reads put the native emitter's buffers in physical-pointer
/// form) a structure loaded from an argument buffer is loaded as an integer and made a pointer (`inttoptr`), which
/// ray_query.rs takes as the structure's address; a pointer load used only by a call operand is not materialized there.
fn structure_loads_as_integers(text: &str, entry: &str) -> Result<String, String> {
    let (a, b) = entry_body(text, entry)?;
    let mut lines: Vec<String> = text[a..b].lines().map(str::to_string).collect();
    // structure operands of resets, and how each is defined (a pointer load from an argument buffer)
    let mut loads: HashMap<String, String> = HashMap::new();
    for l in &lines {
        let t = l.trim_start();
        let Some((lhs, rhs)) = t.split_once(" = ") else { continue };
        if let Some(rest) = rhs.strip_prefix("load ptr addrspace(1), ptr addrspace(1) ") {
            loads.insert(lhs.to_string(), rest.split(',').next().unwrap_or("").trim().to_string());
        }
    }
    let mut declares = Vec::new();
    let mut extra: Vec<(usize, String)> = Vec::new();
    for (j, l) in lines.iter_mut().enumerate() {
        let Some(c) = parse_call(l) else { continue };
        if !c.callee.starts_with("air.reset_intersection_query") || c.args.len() < 6 {
            continue;
        }
        let v = last_token(&c.args[5]);
        let Some(src) = loads.get(&v) else { continue };
        // the address-taking reset (ray_query.rs: an integer structure operand is the structure's address)
        let x = format!("{}.{j}", stem(&v));
        extra.push((j, format!("  %{x}.i = load i64, ptr addrspace(1) {src}, align 8")));
        let tags = c.callee["air.reset_intersection_query".len()..].to_string();
        let name = format!("@air.reset_intersection_query.nvmtladdr{tags}");
        let mut args = c.args.clone();
        args[5] = format!("i64 %{x}.i");
        let tys: Vec<String> = args.iter().map(|a| a.split_whitespace().next().map(|t| {
            if t.starts_with('<') { a[..a.find('>').map(|e| e + 1).unwrap_or(a.len())].to_string() } else if a.starts_with("ptr addrspace(1)") { "ptr addrspace(1)".to_string() } else { t.to_string() }
        }).unwrap_or_default()).collect();
        declares.push(format!("declare void {name}({})", tys.join(", ")));
        *l = format!("  call void {name}({})", args.join(", "));
    }
    for (j, t) in extra.into_iter().rev() {
        lines.insert(j, t);
    }
    let mut out = String::with_capacity(text.len() + 256);
    out.push_str(&text[..a]);
    out.push_str(&lines.join("\n"));
    out.push('\n');
    out.push_str(&text[b..]);
    for d in declares {
        let g = d.find('@').map(|a| d[a..].split('(').next().unwrap_or("").to_string()).unwrap_or_default();
        if !out.contains(&format!("declare void {g}(")) {
            out.push_str(&d);
            out.push('\n');
        }
    }
    Ok(out)
}

/// `@air.<name>.curve_data...` -> without the tag; repeated declarations that leaves are dropped
fn strip_curve_tags(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut declared = HashSet::new();
    for line in text.lines() {
        let mut l = String::with_capacity(line.len());
        let mut rest = line;
        while let Some(at) = rest.find("@air.") {
            l.push_str(&rest[..at]);
            let end = rest[at + 1..]
                .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '.'))
                .map(|e| at + 1 + e)
                .unwrap_or(rest.len());
            let ident = &rest[at..end];
            let stripped: Vec<&str> = ident.split('.').filter(|t| *t != "curve_data").collect();
            l.push_str(&stripped.join("."));
            rest = &rest[end..];
        }
        l.push_str(rest);
        if l.trim_start().starts_with("declare ") {
            let g = l.find('@').map(|a| l[a..].split('(').next().unwrap_or("").to_string()).unwrap_or_default();
            if !declared.insert(g) {
                continue;
            }
        }
        out.push_str(&l);
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_curve_tags_and_dedupes_declarations() {
        let t = "declare i1 @air.next_intersection_query.curve_data(ptr)\ndeclare i1 @air.next_intersection_query(ptr)\n  %1 = call i1 @air.next_intersection_query.instancing.curve_data(ptr %q)\n";
        let s = strip_curve_tags(t);
        assert_eq!(s, "declare i1 @air.next_intersection_query(ptr)\n  %1 = call i1 @air.next_intersection_query.instancing(ptr %q)\n");
    }

    #[test]
    fn query_ops_split() {
        assert_eq!(query_op("air.get_candidate_curve_parameter_intersection_query.curve_data"),
                   Some(("get_candidate_curve_parameter".to_string(), ".curve_data".to_string())));
        assert_eq!(query_op("air.next_intersection_query"), Some(("next".to_string(), String::new())));
    }
}
