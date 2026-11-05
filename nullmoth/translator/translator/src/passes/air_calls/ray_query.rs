use super::block_split::{labelled_block, CallSiteSplit};
use crate::fxhash::HashMap;
use crate::passes::value_queries::type_def_of;
use crate::passes::Ctx;
use crate::spirv_module::{Instruction, Operand};
use spirv::{Capability, Decoration, LoopControl, Op, SelectionControl, StorageClass, Word};

/// nvmtl_rt_layout.h: a Metal acceleration structure is [header][the Vulkan structure]
const NVMTL_AS_HEADER: u64 = 256;
const RAY_FLAG_OPAQUE: u32 = 0x1;
const RAY_FLAG_NO_OPAQUE: u32 = 0x2;
const RAY_FLAG_TERMINATE_ON_FIRST_HIT: u32 = 0x4;
const RAY_FLAG_CULL_BACK_FACING: u32 = 0x10;
const RAY_FLAG_CULL_FRONT_FACING: u32 = 0x20;
const RAY_FLAG_CULL_OPAQUE: u32 = 0x40;
const RAY_FLAG_CULL_NO_OPAQUE: u32 = 0x80;
const RAY_FLAG_SKIP_TRIANGLES: u32 = 0x100;
const RAY_FLAG_SKIP_AABBS: u32 = 0x200;

struct IntersectionParams {
    triangle_cull_mode: Word,
    geometry_cull_mode: Word,
    opacity_cull_mode: Word,
    forced_opacity: Word,
    accept_any_intersection: Word,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Family {
    Allocate,
    Deallocate,
    Reset,
    Next,
    Abort,
    CommitTriangle,
    CommitBoundingBox,
    Get,
    Intersect,
    /// `air.nvmtl_as_base(ptr addrspace(1) %structure)` (rt_runtime): the Metal structure's address (its header).
    AsBase,
}

fn classify(name: &str) -> Option<Family> {
    if name.starts_with("air.intersect.") {
        return Some(Family::Intersect);
    }
    if name == "air.nvmtl_as_base" {
        return Some(Family::AsBase);
    }
    // rt_runtime strips the curve_data tag, which leaves a tagless query name without the trailing dot
    if !name.contains("_intersection_query.") && !name.ends_with("_intersection_query") {
        return None;
    }
    let stem = name.strip_prefix("air.")?;
    Some(if stem.starts_with("allocate_") {
        Family::Allocate
    } else if stem.starts_with("deallocate_") {
        Family::Deallocate
    } else if stem.starts_with("reset_") {
        Family::Reset
    } else if stem.starts_with("next_") {
        Family::Next
    } else if stem.starts_with("abort_") {
        Family::Abort
    } else if stem.starts_with("commit_triangle_intersection_") {
        Family::CommitTriangle
    } else if stem.starts_with("commit_bounding_box_intersection_") {
        Family::CommitBoundingBox
    } else if stem.starts_with("get_") {
        Family::Get
    } else {
        return None;
    })
}

fn tags_are_carried(name: &str) -> bool {
    !(name.contains("motion") || name.contains("curve") || name.contains("intersection_function"))
}

fn air_function_names(ctx: &Ctx) -> HashMap<Word, String> {
    let mut names = HashMap::default();
    for inst in &ctx.module.debug_names {
        if inst.class.opcode != Op::Name {
            continue;
        }
        if let (Some(Operand::IdRef(id)), Some(Operand::LiteralString(name))) =
            (inst.operands.first(), inst.operands.get(1))
        {
            if name.starts_with("air.") {
                names.insert(*id, name.clone());
            }
        }
    }
    names
}

fn id_operand(inst: &Instruction, index: usize) -> Result<Word, String> {
    match inst.operands.get(index) {
        Some(Operand::IdRef(id)) => Ok(*id),
        _ => Err(format!("ray query call operand {index} is not an id")),
    }
}

struct Lowering {
    rq_ptr_ty: Word,
    as_ty: Word,
    as_ptr_ty: Word,
    uint: Word,
    bool_ty: Word,
    c0: Word,
    c1: Word,
    queries: HashMap<Word, Word>,
    structures: HashMap<Word, Word>,
    dead_chains: Vec<Word>,
    query_sides: HashMap<Word, Word>,
    side: Option<(Word, Word)>,
    /// per query: a Function variable holding the Metal structure's address (header) its reset traced
    query_bases: HashMap<Word, Word>,
    ulong: Word,
}

#[derive(Clone, Copy, Debug)]
enum Structure {
    Variable(Word),
    Address {
        root: Word,
        storage: StorageClass,
        word_index: u32,
    },
    /// A structure bound directly at Metal buffer `location` (setAccelerationStructure:atBufferIndex:): its address is
    /// read from the stage's buffer-address table, which holds the bound buffer's address + offset. The binding itself
    /// is a STORAGE_BUFFER descriptor in the plugin's set layout; declaring an acceleration-structure variable there
    /// (as before) makes the driver read a buffer descriptor as an acceleration-structure one (ANV on Xe2: dwords 0-1 of
    /// a RENDER_SURFACE_STATE taken as the BVH address).
    Table {
        root: Word,
        set: u32,
        location: u32,
    },
    /// rtopt4: a structure pointer made from a 64-bit address (`inttoptr`; rt_runtime loads an argument buffer's
    /// structure field as an integer in modules that carry its runtime): the address is that integer.
    Value(Word),
}

impl Lowering {
    fn new(ctx: &mut Ctx) -> Self {
        let rq_ty = ctx.get_or_create(Op::TypeRayQueryKHR, None, Vec::new());
        let rq_ptr_ty = ctx.ty_ptr(StorageClass::Function, rq_ty);
        let as_ty = ctx.get_or_create(Op::TypeAccelerationStructureKHR, None, Vec::new());
        let as_ptr_ty = ctx.ty_ptr(StorageClass::UniformConstant, as_ty);
        let uint = ctx.ty_uint();
        let bool_ty = ctx.ty_bool();
        let c0 = ctx.const_uint(0);
        let c1 = ctx.const_uint(1);
        let _ = 0;
        Self {
            rq_ptr_ty,
            as_ty,
            as_ptr_ty,
            uint,
            bool_ty,
            c0,
            c1,
            queries: HashMap::default(),
            structures: HashMap::default(),
            dead_chains: Vec::new(),
            query_sides: HashMap::default(),
            side: None,
            query_bases: HashMap::default(),
            ulong: 0,
        }
    }

    fn new_query_variable(&self, ctx: &mut Ctx, entry_idx: usize) -> Word {
        let var = ctx.module.fresh_id();
        let entry = &mut ctx.module.functions[entry_idx].blocks[0];
        let at = entry
            .instructions
            .iter()
            .position(|inst| inst.class.opcode != Op::Variable)
            .unwrap_or(entry.instructions.len());
        entry.instructions.insert(
            at,
            Instruction::new(
                Op::Variable,
                Some(self.rq_ptr_ty),
                Some(var),
                vec![Operand::StorageClass(StorageClass::Function)],
            ),
        );
        var
    }

    fn structure_for_operand(
        &mut self,
        ctx: &mut Ctx,
        entry_idx: usize,
        operand: Word,
    ) -> Result<Structure, String> {
        // rtopt4 (rt_runtime): an integer operand is the structure's address itself
        if let Some(def) = defining_instruction(ctx, entry_idx, operand) {
            let ulong = ctx.ty_ulong();
            if def.result_type == Some(ulong) {
                return Ok(Structure::Value(operand));
            }
        }
        let mut cursor = operand;
        let mut chain = Vec::new();
        for _ in 0..16 {
            let def = match defining_instruction(ctx, entry_idx, cursor) {
                Some(def) => def,
                None => {
                    // A DEVICE POINTER THE EMITTER REPLACED WITH ITS ADDRESS. Logical SPIR-V
                    //    cannot hold `load ptr addrspace(1), ptr addrspace(1) %q`, so the emitter emits a
                    //    ulong load for the address and leaves the pointer-typed id defined by nothing.
                    //    The game's acceleration structure arrives exactly that way, and every RT pipeline
                    //    was refused here. The sidecar records which address stands for the pointer; the
                    //    address IS a real instruction, so the walk continues and lands on
                    //    Structure::Value below (rtopt4: the address is the Metal structure header), which is already what this pass wants.
                    // PICK A FACT WHOSE ADDRESS STILL EXISTS. Inlining adds a remapped CLONE and leaves
                    //    the original in the list (clone_inlined_facts keys the clone on the address,
                    //    because the pointer is a placeholder that is never in the remap), so one pointer
                    //    can have several facts and the stale one's address was removed with the function
                    //    it came from. Following the first match landed on an id defined by nothing and
                    //    reported the same refusal one step further along.
                    let resolved = ctx
                        .emit_sidecar
                        .bda_pointer_addresses
                        .iter()
                        .filter(|fact| fact.pointer == cursor)
                        .map(|fact| fact.address)
                        .find(|address| defining_instruction(ctx, entry_idx, *address).is_some());
                    if let Some(address) = resolved {
                        cursor = address;
                        continue;
                    }
                    return Err(format!(
                        "ray query: the acceleration structure operand %{operand} has no definition in the entry function or the globals ({}); bda facts: {} [{}]",
                        where_defined(ctx, cursor),
                        ctx.emit_sidecar.bda_pointer_addresses.len(),
                        ctx.emit_sidecar
                            .bda_pointer_addresses
                            .iter()
                            .take(6)
                            .map(|f| format!("{}->{}", f.pointer, f.address))
                            .collect::<Vec<_>>()
                            .join(" ")
                    ));
                }
            };
            match def.class.opcode {
                Op::Variable => {
                    if def.operands.first() == Some(&Operand::StorageClass(StorageClass::Private)) {
                        return self.address_behind_placeholder(ctx, entry_idx, cursor, operand, chain);
                    }
                    if def.operands.first() != Some(&Operand::StorageClass(StorageClass::StorageBuffer)) {
                        return Err(format!(
                            "ray query: the acceleration structure root %{cursor} is not a StorageBuffer parameter (it is an OpVariable of {:?}, chain {:?})",
                            def.operands.first(),
                            chain
                        ));
                    }
                    let root = cursor;
                    if let Some(table) = self.table_structure(ctx, root) {
                        self.structures.entry(root).or_insert(root);
                        self.dead_chains.extend(chain);
                        return Ok(table);
                    }
                    if let Some(&var) = self.structures.get(&root) {
                        self.dead_chains.extend(chain);
                        return Ok(Structure::Variable(var));
                    }
                    let var = ctx.module.fresh_id();
                    ctx.new_globals.push(Instruction::new(
                        Op::Variable,
                        Some(self.as_ptr_ty),
                        Some(var),
                        vec![Operand::StorageClass(StorageClass::UniformConstant)],
                    ));
                    let copied: Vec<Instruction> = ctx
                        .module
                        .annotations
                        .iter()
                        .filter(|d| {
                            d.class.opcode == Op::Decorate
                                && d.operands.first() == Some(&Operand::IdRef(root))
                                && matches!(
                                    d.operands.get(1),
                                    Some(Operand::Decoration(Decoration::DescriptorSet))
                                        | Some(Operand::Decoration(Decoration::Binding))
                                )
                        })
                        .cloned()
                        .collect();
                    if copied.len() != 2 {
                        return Err(format!(
                            "ray query: the acceleration structure root %{root} carries {} of the 2 set/binding decorations",
                            copied.len()
                        ));
                    }
                    for mut d in copied {
                        d.operands[0] = Operand::IdRef(var);
                        ctx.module.annotations.push(d);
                    }
                    ctx.interface.push(var);
                    self.structures.insert(root, var);
                    self.dead_chains.extend(chain);
                    return Ok(Structure::Variable(var));
                }
                Op::AccessChain | Op::InBoundsAccessChain | Op::Bitcast | Op::CopyObject | Op::PtrAccessChain => {
                    chain.push(cursor);
                    cursor = id_operand(&def, 0)?;
                }
                Op::ConvertUToPtr => {
                    self.dead_chains.extend(chain);
                    self.dead_chains.push(cursor);
                    return Ok(Structure::Value(id_operand(&def, 0)?));
                }
                other => {
                    // An operand that is already the structure's 64-bit device address, not a pointer to it.
                    if is_ulong(ctx, &def) {
                        self.dead_chains.extend(chain);
                        return Ok(Structure::Value(cursor));
                    }
                    return Err(format!(
                        "ray query: the acceleration structure operand comes through {other:?}, which this pass does not follow"
                    ));
                }
            }
        }
        Err(
            "ray query: the acceleration structure operand's pointer chain is deeper than 16"
                .to_string(),
        )
    }

    fn table_structure(&self, ctx: &mut Ctx, root: Word) -> Option<Structure> {
        let deco = |d: Decoration| {
            ctx.module.annotations.iter().find_map(|a| match a.operands.as_slice() {
                [Operand::IdRef(t), Operand::Decoration(x), Operand::LiteralBit32(v)]
                    if *t == root && *x == d && a.class.opcode == Op::Decorate =>
                {
                    Some(*v)
                }
                _ => None,
            })
        };
        let (set, binding) = (deco(Decoration::DescriptorSet)?, deco(Decoration::Binding)?);
        let layout = ctx.descriptor_layout;
        if set != layout.set || !layout.buffers.contains(binding) {
            return None;
        }
        let location = binding - layout.buffers.start;
        (location < crate::passes::resources::ADDRESS_TABLE_SELF_BASE
            && crate::passes::resources::address_table_usable(ctx))
        .then_some(Structure::Table { root, set, location })
    }

    fn address_behind_placeholder(
        &mut self,
        ctx: &mut Ctx,
        entry_idx: usize,
        placeholder: Word,
        operand: Word,
        chain: Vec<Word>,
    ) -> Result<Structure, String> {
        let fact = ctx
            .emit_sidecar
            .buffer_pointer_field_loads
            .iter()
            .find(|fact| fact.id == placeholder)
            .cloned();
        let Some(fact) = fact else {
            let dynamic = ctx
                .emit_sidecar
                .buffer_pointer_dynamic_field_loads
                .iter()
                .any(|fact| fact.id == placeholder);
            let heap = ctx
                .emit_sidecar
                .buffer_pointer_heap_loads
                .iter()
                .any(|fact| fact.id == placeholder);
            return Err(format!(
                "ray query: the acceleration structure operand %{operand} is the Private placeholder %{placeholder} of a load this pass cannot address (constant-offset argument-buffer field: no, dynamically indexed field: {dynamic}, heap load: {heap})"
            ));
        };
        let Some(root_def) = defining_instruction(ctx, entry_idx, fact.root) else {
            return Err(format!(
                "ray query: the argument buffer %{} behind placeholder %{placeholder} has no definition",
                fact.root
            ));
        };
        let storage = match (root_def.class.opcode, root_def.operands.first()) {
            (
                Op::Variable,
                Some(Operand::StorageClass(sc @ (StorageClass::StorageBuffer | StorageClass::Uniform))),
            ) => *sc,
            (op, sc) => {
                return Err(format!(
                    "ray query: the argument buffer %{} behind placeholder %{placeholder} is {op:?} of {sc:?}, not a StorageBuffer/Uniform block variable",
                    fact.root
                ))
            }
        };
        let block = root_def
            .result_type
            .and_then(|ptr| type_def_of(ctx, ptr))
            .and_then(|ptr_def| match ptr_def.operands.get(1) {
                Some(Operand::IdRef(pointee)) => type_def_of(ctx, *pointee),
                _ => None,
            });
        let member0 = match &block {
            Some(b) if b.class.opcode == Op::TypeStruct && b.operands.len() == 1 => {
                match b.operands.first() {
                    Some(Operand::IdRef(m)) => Some(*m),
                    _ => None,
                }
            }
            _ => None,
        };
        let element = member0
            .and_then(|m| type_def_of(ctx, m))
            .filter(|arr| matches!(arr.class.opcode, Op::TypeRuntimeArray | Op::TypeArray))
            .and_then(|arr| match arr.operands.first() {
                Some(Operand::IdRef(e)) => Some(*e),
                _ => None,
            });
        if element != Some(self.uint) {
            return Err(format!(
                "ray query: the argument buffer %{} behind placeholder %{placeholder} is not a raw uint word block (block {:?}); its field at byte {} cannot be addressed as words",
                fact.root,
                block.map(|b| b.class.opcode),
                fact.byte_offset
            ));
        }
        if fact.byte_offset % 4 != 0 {
            return Err(format!(
                "ray query: the structure field at byte {} of %{} is not word aligned",
                fact.byte_offset, fact.root
            ));
        }
        let word_index = u32::try_from(fact.byte_offset / 4).map_err(|_| {
            format!(
                "ray query: the structure field at byte {} of %{} is beyond the u32 word index",
                fact.byte_offset, fact.root
            )
        })?;
        self.dead_chains.extend(chain);
        Ok(Structure::Address {
            root: fact.root,
            storage,
            word_index,
        })
    }

    /// The Metal structure's address (its rtopt4 header, nvmtl_rt_layout.h) as a u64, for the table and argument-buffer
    /// forms; None for a descriptor-typed structure variable (no address).
    fn structure_base(
        &self,
        out: &mut Vec<Instruction>,
        ctx: &mut Ctx,
        structure: Structure,
    ) -> Option<Word> {
        match structure {
            Structure::Variable(_) => None,
            Structure::Value(v) => {
                ctx.add_capability(Capability::Int64);
                let ulong = ctx.ty_ulong();
                let is_u64 = type_def_of(ctx, ulong).is_some() && {
                    let ty = ctx.module.functions.iter().flat_map(|f| f.blocks.iter()).flat_map(|b| b.instructions.iter())
                        .find(|i| i.result_id == Some(v)).and_then(|i| i.result_type);
                    ty == Some(ulong) || ty.is_none()
                };
                Some(if is_u64 { v } else {
                    let w = ctx.module.fresh_id();
                    out.push(Instruction::new(Op::UConvert, Some(ulong), Some(w), vec![Operand::IdRef(v)]));
                    w
                })
            }
            Structure::Table { location, .. } => {
                let (table, word_ptr_ty, wide) = crate::passes::resources::ensure_address_table(ctx)
                    .expect("address table checked usable when the structure was resolved");
                let index = ctx.const_uint(location);
                ctx.add_capability(Capability::Int64);
                Some(if let Some(u64_ty) = wide {
                    let ptr = ctx.module.fresh_id();
                    out.push(Instruction::new(Op::AccessChain, Some(word_ptr_ty), Some(ptr),
                        vec![Operand::IdRef(table), Operand::IdRef(self.c0), Operand::IdRef(index)]));
                    let v = ctx.module.fresh_id();
                    out.push(Instruction::new(Op::Load, Some(u64_ty), Some(v), vec![Operand::IdRef(ptr)]));
                    v
                } else {
                    let mut words = [0; 2];
                    for (k, c) in [self.c0, self.c1].into_iter().enumerate() {
                        let ptr = ctx.module.fresh_id();
                        out.push(Instruction::new(Op::AccessChain, Some(word_ptr_ty), Some(ptr),
                            vec![Operand::IdRef(table), Operand::IdRef(self.c0), Operand::IdRef(index), Operand::IdRef(c)]));
                        let w = ctx.module.fresh_id();
                        out.push(Instruction::new(Op::Load, Some(self.uint), Some(w), vec![Operand::IdRef(ptr)]));
                        words[k] = w;
                    }
                    self.join_words(out, ctx, words[0], words[1])
                })
            }
            Structure::Address { root, storage, word_index } => {
                let word_ptr_ty = ctx.ty_ptr(storage, self.uint);
                let low = self.load_word(out, ctx, root, word_ptr_ty, word_index);
                let high = self.load_word(out, ctx, root, word_ptr_ty, word_index + 1);
                Some(self.join_words(out, ctx, low, high))
            }
        }
    }

    /// The Vulkan structure of a Metal one: `base + NVMTL_AS_HEADER` (0 stays 0: a null structure), or the variable.
    fn load_structure(
        &self,
        out: &mut Vec<Instruction>,
        ctx: &mut Ctx,
        structure: Structure,
    ) -> Word {
        self.load_structure_with_base(out, ctx, structure).0
    }

    fn load_structure_with_base(
        &self,
        out: &mut Vec<Instruction>,
        ctx: &mut Ctx,
        structure: Structure,
    ) -> (Word, Option<Word>) {
        if let Structure::Variable(var) = structure {
            let id = ctx.module.fresh_id();
            out.push(Instruction::new(Op::Load, Some(self.as_ty), Some(id), vec![Operand::IdRef(var)]));
            return (id, None);
        }
        let base = self.structure_base(out, ctx, structure).expect("table / address structures have a base");
        ctx.add_capability(Capability::Int64);
        let ulong = ctx.ty_ulong();
        let header = ctx.const_ulong(NVMTL_AS_HEADER);
        let zero = ctx.const_ulong(0);
        let vk = ctx.module.fresh_id();
        out.push(Instruction::new(Op::IAdd, Some(ulong), Some(vk), vec![Operand::IdRef(base), Operand::IdRef(header)]));
        let null = ctx.module.fresh_id();
        out.push(Instruction::new(Op::IEqual, Some(self.bool_ty), Some(null), vec![Operand::IdRef(base), Operand::IdRef(zero)]));
        let address = ctx.module.fresh_id();
        out.push(Instruction::new(Op::Select, Some(ulong), Some(address),
            vec![Operand::IdRef(null), Operand::IdRef(zero), Operand::IdRef(vk)]));
        let id = ctx.module.fresh_id();
        out.push(Instruction::new(Op::ConvertUToAccelerationStructureKHR, Some(self.as_ty), Some(id), vec![Operand::IdRef(address)]));
        (id, Some(base))
    }

    fn load_word(
        &self,
        out: &mut Vec<Instruction>,
        ctx: &mut Ctx,
        root: Word,
        word_ptr_ty: Word,
        word_index: u32,
    ) -> Word {
        let index = ctx.const_uint(word_index);
        let ptr = ctx.module.fresh_id();
        out.push(Instruction::new(
            Op::AccessChain,
            Some(word_ptr_ty),
            Some(ptr),
            vec![
                Operand::IdRef(root),
                Operand::IdRef(self.c0),
                Operand::IdRef(index),
            ],
        ));
        let word = ctx.module.fresh_id();
        out.push(Instruction::new(
            Op::Load,
            Some(self.uint),
            Some(word),
            vec![Operand::IdRef(ptr)],
        ));
        word
    }

    fn join_words(&self, out: &mut Vec<Instruction>, ctx: &mut Ctx, low: Word, high: Word) -> Word {
        ctx.add_capability(Capability::Int64);
        let ulong = ctx.ty_ulong();
        let low64 = ctx.module.fresh_id();
        out.push(Instruction::new(Op::UConvert, Some(ulong), Some(low64), vec![Operand::IdRef(low)]));
        let high64 = ctx.module.fresh_id();
        out.push(Instruction::new(Op::UConvert, Some(ulong), Some(high64), vec![Operand::IdRef(high)]));
        let thirty_two = ctx.const_uint(32);
        let shifted = ctx.module.fresh_id();
        out.push(Instruction::new(Op::ShiftLeftLogical, Some(ulong), Some(shifted),
            vec![Operand::IdRef(high64), Operand::IdRef(thirty_two)]));
        let address = ctx.module.fresh_id();
        out.push(Instruction::new(Op::BitwiseOr, Some(ulong), Some(address),
            vec![Operand::IdRef(low64), Operand::IdRef(shifted)]));
        address
    }

    fn query_base_var(&mut self, ctx: &mut Ctx, entry_idx: usize, query: Word) -> Word {
        if let Some(&v) = self.query_bases.get(&query) {
            return v;
        }
        ctx.add_capability(Capability::Int64);
        let ulong = ctx.ty_ulong();
        let ptr_ty = ctx.ty_ptr(StorageClass::Function, ulong);
        let var = ctx.module.fresh_id();
        let entry = &mut ctx.module.functions[entry_idx].blocks[0];
        let at = entry.instructions.iter().position(|i| i.class.opcode != Op::Variable).unwrap_or(entry.instructions.len());
        entry.instructions.insert(at, Instruction::new(Op::Variable, Some(ptr_ty), Some(var),
            vec![Operand::StorageClass(StorageClass::Function)]));
        self.query_bases.insert(query, var);
        self.ulong = ulong;
        var
    }

    fn query_of(&self, operand: Word) -> Result<Word, String> {
        self.queries.get(&operand).copied().ok_or_else(|| {
            format!("ray query: operand %{operand} is not an allocated intersection query (flows through a phi or a select?)")
        })
    }

    fn or_flag(
        &self,
        out: &mut Vec<Instruction>,
        ctx: &mut Ctx,
        flags: Word,
        cond: Word,
        bit: u32,
    ) -> Word {
        let bit = ctx.const_uint(bit);
        let sel = ctx.module.fresh_id();
        out.push(Instruction::new(
            Op::Select,
            Some(self.uint),
            Some(sel),
            vec![
                Operand::IdRef(cond),
                Operand::IdRef(bit),
                Operand::IdRef(self.c0),
            ],
        ));
        let ored = ctx.module.fresh_id();
        out.push(Instruction::new(
            Op::BitwiseOr,
            Some(self.uint),
            Some(ored),
            vec![Operand::IdRef(flags), Operand::IdRef(sel)],
        ));
        ored
    }

    fn equals(&self, out: &mut Vec<Instruction>, ctx: &mut Ctx, value: Word, imm: u32) -> Word {
        let c = ctx.const_uint(imm);
        let id = ctx.module.fresh_id();
        out.push(Instruction::new(
            Op::IEqual,
            Some(self.bool_ty),
            Some(id),
            vec![Operand::IdRef(value), Operand::IdRef(c)],
        ));
        id
    }

    fn bit_set(&self, out: &mut Vec<Instruction>, ctx: &mut Ctx, value: Word, mask: u32) -> Word {
        let c = ctx.const_uint(mask);
        let anded = ctx.module.fresh_id();
        out.push(Instruction::new(
            Op::BitwiseAnd,
            Some(self.uint),
            Some(anded),
            vec![Operand::IdRef(value), Operand::IdRef(c)],
        ));
        let id = ctx.module.fresh_id();
        out.push(Instruction::new(
            Op::INotEqual,
            Some(self.bool_ty),
            Some(id),
            vec![Operand::IdRef(anded), Operand::IdRef(self.c0)],
        ));
        id
    }

    fn ray_flags(&self, out: &mut Vec<Instruction>, ctx: &mut Ctx, p: &IntersectionParams) -> Word {
        let mut flags = self.c0;
        let forced_opaque = self.equals(out, ctx, p.forced_opacity, 1);
        flags = self.or_flag(out, ctx, flags, forced_opaque, RAY_FLAG_OPAQUE);
        let forced_non_opaque = self.equals(out, ctx, p.forced_opacity, 2);
        flags = self.or_flag(out, ctx, flags, forced_non_opaque, RAY_FLAG_NO_OPAQUE);
        flags = self.or_flag(
            out,
            ctx,
            flags,
            p.accept_any_intersection,
            RAY_FLAG_TERMINATE_ON_FIRST_HIT,
        );
        let cull_front = self.equals(out, ctx, p.triangle_cull_mode, 1);
        flags = self.or_flag(out, ctx, flags, cull_front, RAY_FLAG_CULL_FRONT_FACING);
        let cull_back = self.equals(out, ctx, p.triangle_cull_mode, 2);
        flags = self.or_flag(out, ctx, flags, cull_back, RAY_FLAG_CULL_BACK_FACING);
        let cull_opaque = self.equals(out, ctx, p.opacity_cull_mode, 1);
        flags = self.or_flag(out, ctx, flags, cull_opaque, RAY_FLAG_CULL_OPAQUE);
        let cull_non_opaque = self.equals(out, ctx, p.opacity_cull_mode, 2);
        flags = self.or_flag(out, ctx, flags, cull_non_opaque, RAY_FLAG_CULL_NO_OPAQUE);
        let skip_triangles = self.bit_set(out, ctx, p.geometry_cull_mode, 1);
        flags = self.or_flag(out, ctx, flags, skip_triangles, RAY_FLAG_SKIP_TRIANGLES);
        let skip_boxes = self.bit_set(out, ctx, p.geometry_cull_mode, 2);
        flags = self.or_flag(out, ctx, flags, skip_boxes, RAY_FLAG_SKIP_AABBS);
        flags
    }

    fn initialize(
        &self,
        out: &mut Vec<Instruction>,
        ctx: &mut Ctx,
        query: Word,
        structure: Word,
        p: &IntersectionParams,
        mask: Word,
        origin: Word,
        tmin: Word,
        dir: Word,
        tmax: Word,
    ) {
        let flags = self.ray_flags(out, ctx, p);
        out.push(Instruction::new(
            Op::RayQueryInitializeKHR,
            None,
            None,
            vec![
                Operand::IdRef(query),
                Operand::IdRef(structure),
                Operand::IdRef(flags),
                Operand::IdRef(mask),
                Operand::IdRef(origin),
                Operand::IdRef(tmin),
                Operand::IdRef(dir),
                Operand::IdRef(tmax),
            ],
        ));
    }

    fn get(
        &self,
        out: &mut Vec<Instruction>,
        ctx: &mut Ctx,
        op: Op,
        rty: Word,
        query: Word,
        committed: bool,
    ) -> Word {
        let id = ctx.module.fresh_id();
        let which = if committed { self.c1 } else { self.c0 };
        out.push(Instruction::new(
            op,
            Some(rty),
            Some(id),
            vec![Operand::IdRef(query), Operand::IdRef(which)],
        ));
        id
    }

    fn side_table_for(
        &mut self,
        ctx: &mut Ctx,
        structure: Structure,
    ) -> Result<Option<Word>, String> {
        let (root, set) = match structure {
            Structure::Table { root, set, .. } => (root, Some(set)),
            Structure::Variable(var) => {
                let root = self
                    .structures
                    .iter()
                    .find(|(_, v)| **v == var)
                    .map(|(r, _)| *r);
                let Some(root) = root else { return Ok(None) };
                let set = ctx.module.annotations.iter().find_map(|d| match d.operands.as_slice() {
                    [Operand::IdRef(t), Operand::Decoration(Decoration::DescriptorSet), Operand::LiteralBit32(v)] if *t == var => Some(*v),
                    _ => None,
                });
                (root, set)
            }
            Structure::Address { .. } | Structure::Value(_) => return Ok(None),
        };
        if let Some((served, block)) = self.side {
            return Ok((served == root).then_some(block));
        }
        let Some(set) = set else { return Ok(None) };
        let reserved = crate::reflect::RAY_INSTANCE_USER_ID_TABLE_BINDING;
        for d in &ctx.module.annotations {
            if let [Operand::IdRef(var), Operand::Decoration(Decoration::Binding), Operand::LiteralBit32(binding)] =
                d.operands.as_slice()
            {
                if *binding == reserved && ctx.module.annotations.iter().any(|a| matches!(a.operands.as_slice(), [Operand::IdRef(v), Operand::Decoration(Decoration::DescriptorSet), Operand::LiteralBit32(s)] if v == var && *s == set)) {
                    return Err(format!("ray instance user-ID table reserved binding {reserved} collides with an existing descriptor in set {set}"));
                }
            }
        }
        let rta = ctx.module.fresh_id();
        ctx.new_globals.push(Instruction::new(
            Op::TypeRuntimeArray,
            None,
            Some(rta),
            vec![Operand::IdRef(self.uint)],
        ));
        let block = ctx.module.fresh_id();
        ctx.new_globals.push(Instruction::new(
            Op::TypeStruct,
            None,
            Some(block),
            vec![Operand::IdRef(rta)],
        ));
        let ptr = ctx.module.fresh_id();
        ctx.new_globals.push(Instruction::new(
            Op::TypePointer,
            None,
            Some(ptr),
            vec![
                Operand::StorageClass(StorageClass::StorageBuffer),
                Operand::IdRef(block),
            ],
        ));
        let side = ctx.module.fresh_id();
        ctx.new_globals.push(Instruction::new(
            Op::Variable,
            Some(ptr),
            Some(side),
            vec![Operand::StorageClass(StorageClass::StorageBuffer)],
        ));
        for (target, deco) in [
            (
                rta,
                vec![
                    Operand::Decoration(Decoration::ArrayStride),
                    Operand::LiteralBit32(4),
                ],
            ),
            (block, vec![Operand::Decoration(Decoration::Block)]),
            (
                side,
                vec![
                    Operand::Decoration(Decoration::DescriptorSet),
                    Operand::LiteralBit32(set),
                ],
            ),
            (
                side,
                vec![
                    Operand::Decoration(Decoration::Binding),
                    Operand::LiteralBit32(reserved),
                ],
            ),
        ] {
            let mut ops = vec![Operand::IdRef(target)];
            ops.extend(deco);
            ctx.module
                .annotations
                .push(Instruction::new(Op::Decorate, None, None, ops));
        }
        ctx.module.annotations.push(Instruction::new(
            Op::MemberDecorate,
            None,
            None,
            vec![
                Operand::IdRef(block),
                Operand::LiteralBit32(0),
                Operand::Decoration(Decoration::Offset),
                Operand::LiteralBit32(0),
            ],
        ));
        ctx.interface.push(side);
        self.side = Some((root, side));
        ctx.ray_instance_user_id_table = Some(side);
        Ok(Some(side))
    }

    fn user_id(
        &self,
        out: &mut Vec<Instruction>,
        ctx: &mut Ctx,
        rty: Word,
        query: Word,
        committed: bool,
        side: Option<Word>,
        res: Word,
    ) {
        let which = if committed { self.c1 } else { self.c0 };
        let Some(side) = side else {
            out.push(Instruction::new(
                Op::RayQueryGetIntersectionInstanceCustomIndexKHR,
                Some(rty),
                Some(res),
                vec![Operand::IdRef(query), Operand::IdRef(which)],
            ));
            return;
        };
        let iid = self.get(
            out,
            ctx,
            Op::RayQueryGetIntersectionInstanceIdKHR,
            self.uint,
            query,
            committed,
        );
        let word_ptr_ty = ctx.ty_ptr(StorageClass::StorageBuffer, self.uint);
        let ptr = ctx.module.fresh_id();
        out.push(Instruction::new(
            Op::AccessChain,
            Some(word_ptr_ty),
            Some(ptr),
            vec![
                Operand::IdRef(side),
                Operand::IdRef(self.c0),
                Operand::IdRef(iid),
            ],
        ));
        if rty == self.uint {
            out.push(Instruction::new(
                Op::Load,
                Some(rty),
                Some(res),
                vec![Operand::IdRef(ptr)],
            ));
        } else {
            let w = ctx.module.fresh_id();
            out.push(Instruction::new(
                Op::Load,
                Some(self.uint),
                Some(w),
                vec![Operand::IdRef(ptr)],
            ));
            out.push(Instruction::new(
                Op::Bitcast,
                Some(rty),
                Some(res),
                vec![Operand::IdRef(w)],
            ));
        }
    }

    fn getter(&self, name: &str) -> Result<(Op, bool, bool), String> {
        let stem = name.strip_prefix("air.get_").unwrap_or(name);
        let (committed, prop) = if let Some(p) = stem.strip_prefix("committed_") {
            (true, p)
        } else if let Some(p) = stem.strip_prefix("candidate_") {
            (false, p)
        } else if stem.starts_with("world_space_ray_origin") {
            return Ok((Op::RayQueryGetWorldRayOriginKHR, true, false));
        } else if stem.starts_with("world_space_ray_direction") {
            return Ok((Op::RayQueryGetWorldRayDirectionKHR, true, false));
        } else if stem.starts_with("ray_min_distance") {
            return Ok((Op::RayQueryGetRayTMinKHR, true, false));
        } else {
            return Err(format!("ray query: getter {name} is not carried yet (object-space rays and transforms are v2)"));
        };
        let prop = prop.split("_intersection_query").next().unwrap_or(prop);
        let op = match prop {
            "intersection_type" => return Ok((Op::RayQueryGetIntersectionTypeKHR, committed, true)),
            "distance" | "triangle_distance" | "bounding_box_distance" => Op::RayQueryGetIntersectionTKHR,
            "triangle_barycentric_coord" => Op::RayQueryGetIntersectionBarycentricsKHR,
            "primitive_id" => Op::RayQueryGetIntersectionPrimitiveIndexKHR,
            "geometry_id" => Op::RayQueryGetIntersectionGeometryIndexKHR,
            "instance_id" => Op::RayQueryGetIntersectionInstanceIdKHR,
            "user_instance_id" => Op::RayQueryGetIntersectionInstanceCustomIndexKHR,
            "nvmtl_sbt_offset" => Op::RayQueryGetIntersectionInstanceShaderBindingTableRecordOffsetKHR,
            "triangle_front_facing" => Op::RayQueryGetIntersectionFrontFaceKHR,
            "ray_origin" => Op::RayQueryGetIntersectionObjectRayOriginKHR,
            "ray_direction" => Op::RayQueryGetIntersectionObjectRayDirectionKHR,
            "object_to_world_transform" => Op::RayQueryGetIntersectionObjectToWorldKHR,
            "world_to_object_transform" => Op::RayQueryGetIntersectionWorldToObjectKHR,
            other => {
                return Err(format!(
                    "ray query: getter {name} ({other}) is not carried yet (transforms and object-space rays are v2)"
                ))
            }
        };
        Ok((op, committed, false))
    }

    fn lower_get(
        &self,
        ctx: &mut Ctx,
        name: &str,
        call: &Instruction,
    ) -> Result<Vec<Instruction>, String> {
        let res = call.result_id.ok_or("ray query getter without a result")?;
        let rty = call
            .result_type
            .ok_or("ray query getter without a result type")?;
        let (op, committed, is_type) = self.getter(name)?;
        let mut out = Vec::new();
        if matches!(
            op,
            Op::RayQueryGetIntersectionObjectToWorldKHR
                | Op::RayQueryGetIntersectionWorldToObjectKHR
        ) {
            let query = self.query_of(id_operand(call, 0)?)?;
            let def = type_def_of(ctx, rty).ok_or("ray query: transform result type undefined")?;
            let column = match (def.class.opcode, def.operands.len(), def.operands.first()) {
                (Op::TypeStruct, 4, Some(Operand::IdRef(v))) => *v,
                _ => {
                    return Err(format!(
                        "ray query: {name} result is not AIR's four-column struct"
                    ))
                }
            };
            let mat = ctx.get_or_create(
                Op::TypeMatrix,
                None,
                vec![Operand::IdRef(column), Operand::LiteralBit32(4)],
            );
            let m = self.get(&mut out, ctx, op, mat, query, committed);
            let mut cols = Vec::with_capacity(4);
            for k in 0..4u32 {
                let c = ctx.module.fresh_id();
                out.push(Instruction::new(
                    Op::CompositeExtract,
                    Some(column),
                    Some(c),
                    vec![Operand::IdRef(m), Operand::LiteralBit32(k)],
                ));
                cols.push(Operand::IdRef(c));
            }
            out.push(Instruction::new(
                Op::CompositeConstruct,
                Some(rty),
                Some(res),
                cols,
            ));
            return Ok(out);
        }
        if matches!(
            op,
            Op::RayQueryGetWorldRayOriginKHR
                | Op::RayQueryGetWorldRayDirectionKHR
                | Op::RayQueryGetRayTMinKHR
        ) {
            let query = self.query_of(id_operand(call, 0)?)?;
            out.push(Instruction::new(
                op,
                Some(rty),
                Some(res),
                vec![Operand::IdRef(query)],
            ));
            return Ok(out);
        }
        let query = self.query_of(id_operand(call, 0)?)?;
        if op == Op::RayQueryGetIntersectionInstanceCustomIndexKHR {
            self.user_id(
                &mut out,
                ctx,
                rty,
                query,
                committed,
                self.query_sides.get(&query).copied(),
                res,
            );
            return Ok(out);
        }
        if is_type && !committed {
            let raw = self.get(&mut out, ctx, op, rty, query, false);
            out.push(Instruction::new(
                Op::IAdd,
                Some(rty),
                Some(res),
                vec![Operand::IdRef(raw), Operand::IdRef(self.c1)],
            ));
        } else {
            let which = if committed { self.c1 } else { self.c0 };
            out.push(Instruction::new(
                op,
                Some(rty),
                Some(res),
                vec![Operand::IdRef(query), Operand::IdRef(which)],
            ));
        }
        Ok(out)
    }

    fn params_from(&self, call: &Instruction, first: usize) -> Result<IntersectionParams, String> {
        let n = call.operands.len();
        if n < first + 8 {
            return Err(format!(
                "ray query: reset/intersect call has {n} operands, fewer than the {} expected",
                first + 8
            ));
        }
        Ok(IntersectionParams {
            triangle_cull_mode: id_operand(call, first + 1)?,
            geometry_cull_mode: id_operand(call, first + 2)?,
            opacity_cull_mode: id_operand(call, first + 3)?,
            forced_opacity: id_operand(call, first + 4)?,
            accept_any_intersection: id_operand(call, n - 1)?,
        })
    }
}

/// Whether an instruction produces a 64-bit integer.
fn is_ulong(ctx: &Ctx, def: &Instruction) -> bool {
    def.result_type
        .and_then(|rty| type_def_of(ctx, rty))
        .is_some_and(|ty| {
            ty.class.opcode == Op::TypeInt
                && ty.operands.first() == Some(&Operand::LiteralBit32(64))
        })
}

/// Where an id IS defined, for a message that would otherwise only say it is not where we looked.
fn where_defined(ctx: &Ctx, id: Word) -> String {
    for (idx, function) in ctx.module.functions.iter().enumerate() {
        if function
            .parameters
            .iter()
            .any(|p| p.result_id == Some(id))
        {
            return format!("it is parameter of function #{idx}");
        }
        for block in &function.blocks {
            if let Some(inst) = block.instructions.iter().find(|i| i.result_id == Some(id)) {
                return format!("it is {:?} in function #{idx}", inst.class.opcode);
            }
        }
    }
    // "nowhere" is not enough to act on. The acceleration structure arrives as
    //    `%as = load ptr addrspace(1), ptr addrspace(1) %p` — a device pointer loaded out of device
    //    memory, which Logical SPIR-V cannot hold as a pointer, so the emitter turns it into a 64-bit
    //    address. If the id handed to this pass is the pointer-typed value the emitter replaced, it was
    //    never emitted and no amount of searching finds it. Say whether the id was ever ALLOCATED (is it
    //    inside the module's id range) and whether anything else references it: an id above the bound is
    //    a fresh id someone allocated and never defined, which names the culprit instead of the symptom.
    let bound = ctx.module.header.as_ref().map_or(0, |h| h.bound);
    let referenced = ctx
        .module
        .functions
        .iter()
        .flat_map(|f| f.blocks.iter())
        .flat_map(|b| b.instructions.iter())
        .filter(|i| i.operands.contains(&Operand::IdRef(id)))
        .count();
    format!(
        "it is defined nowhere in the module (id {id}, module id bound {bound}, referenced by \
         {referenced} instruction(s)){}",
        if id >= bound { " - ABOVE THE BOUND: allocated but never emitted" } else { "" }
    )
}

fn defining_instruction(ctx: &Ctx, entry_idx: usize, id: Word) -> Option<Instruction> {
    for block in &ctx.module.functions[entry_idx].blocks {
        for inst in &block.instructions {
            if inst.result_id == Some(id) {
                return Some(inst.clone());
            }
        }
    }
    ctx.module
        .types_global_values
        .iter()
        .chain(ctx.new_globals.iter())
        .find(|inst| inst.result_id == Some(id))
        .cloned()
}

pub(crate) const PRIMITIVE_DATA_REFUSAL: &str =
    "ray tracing: intersection_result::primitive_data is read, and per-primitive data is not supported on this device (supportsRayTracingPerPrimitiveData NO)";

/// Whether member `index` of the aggregate `res` is extracted anywhere in the entry (directly, or as the whole value
/// passed on: a store, a call argument or a phi of the aggregate counts as a read).
fn result_member_is_read(ctx: &Ctx, entry_idx: usize, res: Word, index: u32) -> bool {
    ctx.module.functions[entry_idx].blocks.iter().any(|b| {
        b.instructions.iter().any(|inst| {
            if !inst.operands.contains(&Operand::IdRef(res)) {
                return false;
            }
            match inst.class.opcode {
                Op::CompositeExtract => inst.operands.get(1) == Some(&Operand::LiteralBit32(index)),
                Op::CompositeInsert => false,
                _ => true,
            }
        })
    })
}

fn id_is_used(ctx: &Ctx, entry_idx: usize, id: Word) -> bool {
    ctx.module.functions[entry_idx].blocks.iter().any(|b| {
        b.instructions
            .iter()
            .any(|inst| inst.operands.contains(&Operand::IdRef(id)))
    })
}

fn remove_definition(ctx: &mut Ctx, entry_idx: usize, id: Word) {
    for block in &mut ctx.module.functions[entry_idx].blocks {
        block.instructions.retain(|inst| inst.result_id != Some(id));
    }
}

fn intersection_field_type_matches(
    ctx: &Ctx,
    ty: Word,
    field: crate::meta::AirIntersectionResultField,
) -> bool {
    use crate::meta::AirIntersectionResultField as Field;
    let Some(def) = type_def_of(ctx, ty) else {
        return false;
    };
    let integer = |width| {
        def.class.opcode == Op::TypeInt
            && def.operands.first() == Some(&Operand::LiteralBit32(width))
    };
    match field {
        Field::IntersectionType
        | Field::PrimitiveId
        | Field::GeometryId
        | Field::InstanceId
        | Field::UserInstanceId => integer(32),
        Field::InstanceLevel => integer(8),
        Field::Distance | Field::CurveParameter => {
            def.class.opcode == Op::TypeFloat && def.operands == [Operand::LiteralBit32(32)]
        }
        Field::FrontFacing => def.class.opcode == Op::TypeBool,
        Field::OpaquePointer => {
            integer(64)
                || (def.class.opcode == Op::TypePointer
                    && matches!(
                        def.operands.first(),
                        Some(Operand::StorageClass(
                            StorageClass::StorageBuffer | StorageClass::PhysicalStorageBuffer
                        ))
                    ))
        }
        Field::Barycentrics | Field::WorldSpaceVector(_) => {
            let width = if field == Field::Barycentrics { 2 } else { 3 };
            let [Operand::IdRef(element), Operand::LiteralBit32(lanes)] = def.operands.as_slice()
            else {
                return false;
            };
            def.class.opcode == Op::TypeVector
                && *lanes == width
                && type_def_of(ctx, *element).is_some_and(|scalar| {
                    scalar.class.opcode == Op::TypeFloat
                        && scalar.operands == [Operand::LiteralBit32(32)]
                })
        }
    }
}

pub(in crate::passes) fn lower_ray_queries(
    ctx: &mut Ctx,
    entry_idx: usize,
) -> Result<bool, String> {
    let names = air_function_names(ctx);
    let families: HashMap<Word, (Family, String)> = names
        .iter()
        .filter_map(|(id, name)| classify(name).map(|f| (*id, (f, name.clone()))))
        .collect();
    if families.is_empty() {
        return Ok(false);
    }
    for (_, name) in families.values() {
        if !tags_are_carried(name) {
            return Err(format!(
                "ray query: {name} — motion, curve and intersection-function shapes are not carried yet"
            ));
        }
    }

    let mut lw = Lowering::new(ctx);
    ctx.add_capability(Capability::RayQueryKHR);
    if !ctx.module.extensions.iter().any(|e| {
        e.operands.first() == Some(&Operand::LiteralString("SPV_KHR_ray_query".to_string()))
    }) {
        ctx.module.extensions.push(Instruction::new(
            Op::Extension,
            None,
            None,
            vec![Operand::LiteralString("SPV_KHR_ray_query".to_string())],
        ));
    }

    let nblocks = ctx.module.functions[entry_idx].blocks.len();
    for b in 0..nblocks {
        let mut i = 0;
        while i < ctx.module.functions[entry_idx].blocks[b].instructions.len() {
            let inst = ctx.module.functions[entry_idx].blocks[b].instructions[i].clone();
            if inst.class.opcode == Op::FunctionCall {
                if let Some((Family::Allocate, _)) =
                    id_operand(&inst, 0).ok().and_then(|f| families.get(&f))
                {
                    let var = lw.new_query_variable(ctx, entry_idx);
                    let res = inst
                        .result_id
                        .ok_or("ray query: allocate without a result")?;
                    lw.queries.insert(res, var);
                    // its structure-address variable now, while block 0 is not being rewritten
                    lw.query_base_var(ctx, entry_idx, var);
                    remove_definition(ctx, entry_idx, res);
                    continue;
                }
            }
            i += 1;
        }
    }

    for b in 0..nblocks {
        let mut i = 0;
        while i < ctx.module.functions[entry_idx].blocks[b].instructions.len() {
            let inst = ctx.module.functions[entry_idx].blocks[b].instructions[i].clone();
            let Some((family, name)) = (inst.class.opcode == Op::FunctionCall)
                .then(|| {
                    id_operand(&inst, 0)
                        .ok()
                        .and_then(|f| families.get(&f))
                        .cloned()
                })
                .flatten()
            else {
                i += 1;
                continue;
            };
            let replacement: Vec<Instruction> = match family {
                Family::Allocate => unreachable!("allocates were consumed above"),
                Family::Intersect => {
                    i += 1;
                    continue;
                }
                Family::Deallocate => Vec::new(),
                Family::Reset => {
                    let query = lw.query_of(id_operand(&inst, 1)?)?;
                    let origin = id_operand(&inst, 2)?;
                    let dir = id_operand(&inst, 3)?;
                    let tmin = id_operand(&inst, 4)?;
                    let tmax = id_operand(&inst, 5)?;
                    let structure_var =
                        lw.structure_for_operand(ctx, entry_idx, id_operand(&inst, 6)?)?;
                    if let Some(side) = lw.side_table_for(ctx, structure_var)? {
                        lw.query_sides.insert(query, side);
                    }
                    // AIR: an instancing query's reset carries the instance mask after the structure; a primitive
                    // structure's does not (its parameters start there: the mask is all instances)
                    let instancing = name.contains("instancing");
                    let (mask, params) = if instancing {
                        (id_operand(&inst, 7)?, lw.params_from(&inst, 8)?)
                    } else {
                        (ctx.const_uint(255), lw.params_from(&inst, 7)?)
                    };
                    let mut out = Vec::new();
                    let (structure, base) = lw.load_structure_with_base(&mut out, ctx, structure_var);
                    let base = match base {
                        Some(b) => b,
                        None => ctx.const_ulong(0),
                    };
                    let var = lw.query_base_var(ctx, entry_idx, query);
                    out.push(Instruction::new(Op::Store, None, None, vec![Operand::IdRef(var), Operand::IdRef(base)]));
                    lw.initialize(
                        &mut out, ctx, query, structure, &params, mask, origin, tmin, dir, tmax,
                    );
                    out
                }
                Family::AsBase => {
                    let structure_var =
                        lw.structure_for_operand(ctx, entry_idx, id_operand(&inst, 1)?)?;
                    let res = inst.result_id.ok_or("air.nvmtl_as_base without a result")?;
                    let rty = inst.result_type.ok_or("air.nvmtl_as_base without a result type")?;
                    let mut out = Vec::new();
                    let base = lw.structure_base(&mut out, ctx, structure_var).ok_or(
                        "ray tracing: the acceleration structure has no address here (a descriptor-typed binding); its header (curves, user IDs, primitive data) cannot be read",
                    )?;
                    out.push(Instruction::new(Op::CopyObject, Some(rty), Some(res), vec![Operand::IdRef(base)]));
                    out
                }
                Family::Next => {
                    let query = lw.query_of(id_operand(&inst, 1)?)?;
                    vec![Instruction::new(
                        Op::RayQueryProceedKHR,
                        Some(
                            inst.result_type
                                .ok_or("ray query: next without a result type")?,
                        ),
                        inst.result_id,
                        vec![Operand::IdRef(query)],
                    )]
                }
                Family::Abort => {
                    let query = lw.query_of(id_operand(&inst, 1)?)?;
                    vec![Instruction::new(
                        Op::RayQueryTerminateKHR,
                        None,
                        None,
                        vec![Operand::IdRef(query)],
                    )]
                }
                Family::CommitTriangle => {
                    let query = lw.query_of(id_operand(&inst, 1)?)?;
                    vec![Instruction::new(
                        Op::RayQueryConfirmIntersectionKHR,
                        None,
                        None,
                        vec![Operand::IdRef(query)],
                    )]
                }
                Family::CommitBoundingBox => {
                    let query = lw.query_of(id_operand(&inst, 1)?)?;
                    let distance = id_operand(&inst, 2)?;
                    vec![Instruction::new(
                        Op::RayQueryGenerateIntersectionKHR,
                        None,
                        None,
                        vec![Operand::IdRef(query), Operand::IdRef(distance)],
                    )]
                }
                Family::Get if name.starts_with("air.get_nvmtl_as_base_intersection_query") => {
                    let query = lw.query_of(id_operand(&inst, 1)?)?;
                    let var = lw.query_base_var(ctx, entry_idx, query);
                    vec![Instruction::new(
                        Op::Load,
                        Some(inst.result_type.ok_or("as base getter without a result type")?),
                        inst.result_id,
                        vec![Operand::IdRef(var)],
                    )]
                }
                Family::Get => {
                    let mut shifted = inst.clone();
                    shifted.operands.remove(0);
                    lw.lower_get(ctx, &name, &shifted)?
                }
            };
            let block = &mut ctx.module.functions[entry_idx].blocks[b];
            let n = replacement.len();
            block.instructions.splice(i..i + 1, replacement);
            i += n;
        }
    }

    loop {
        let mut site = None;
        'find: for b in 0..ctx.module.functions[entry_idx].blocks.len() {
            for (i, inst) in ctx.module.functions[entry_idx].blocks[b]
                .instructions
                .iter()
                .enumerate()
            {
                if inst.class.opcode == Op::FunctionCall {
                    if let Some((Family::Intersect, _)) =
                        id_operand(inst, 0).ok().and_then(|f| families.get(&f))
                    {
                        site = Some((b, i));
                        break 'find;
                    }
                }
            }
        }
        let Some((b, i)) = site else { break };
        let call = ctx.module.functions[entry_idx].blocks[b].instructions[i].clone();
        if crate::env_vars::rq_debug() {
            eprintln!(
                "[rq-debug] intersect call %{:?} at block {b} (label %{:?}) inst {i}; {} blocks in the entry",
                call.result_id,
                ctx.module.functions[entry_idx].blocks[b].label.as_ref().and_then(|l| l.result_id),
                ctx.module.functions[entry_idx].blocks.len()
            );
        }

        let callee = id_operand(&call, 0)?;
        let (_, name) = families
            .get(&callee)
            .ok_or("ray query: missing intersection family")?;
        let family = crate::meta::AirIntersectionFamily::parse(name)?
            .ok_or("ray query: invalid intersection family")?;
        if family.instancing == crate::meta::AirIntersectionInstancing::MultiLevel {
            return Err(
                "ray query: multi-level instancing requires hierarchy path metadata; unsupported"
                    .into(),
            );
        }
        let fields = family.result_fields();
        let n = call.operands.len();
        if n != family.argument_count() + 1 {
            return Err(format!(
                "ray query: {name} has {} arguments, expected {}",
                n - 1,
                family.argument_count()
            ));
        }
        let res = call
            .result_id
            .ok_or("ray query: intersect without a result")?;
        let rty = call
            .result_type
            .ok_or("ray query: intersect without a result type")?;
        let result_def =
            type_def_of(ctx, rty).ok_or("ray query: intersect result type undefined")?;
        if result_def.class.opcode != Op::TypeStruct || result_def.operands.len() != fields.len() {
            return Err(format!(
                "ray query: {name} result does not match its {}-member AIR aggregate",
                fields.len()
            ));
        }
        let member_ty = |k: usize| -> Result<Word, String> {
            match result_def.operands.get(k) {
                Some(Operand::IdRef(t)) => Ok(*t),
                _ => Err("ray query: intersection_result member type missing".to_string()),
            }
        };
        for (index, field) in fields.iter().enumerate() {
            if !intersection_field_type_matches(ctx, member_ty(index)?, *field) {
                return Err(format!(
                    "ray query: {name} intersection result field {index} must be {}",
                    field.llvm_type()
                ));
            }
        }
        let origin = id_operand(&call, 1)?;
        let dir = id_operand(&call, 2)?;
        let tmin = id_operand(&call, 3)?;
        let tmax = id_operand(&call, 4)?;
        let structure_var = lw.structure_for_operand(ctx, entry_idx, id_operand(&call, 5)?)?;
        let mask = if family.instancing == crate::meta::AirIntersectionInstancing::None {
            ctx.const_uint(255)
        } else {
            id_operand(&call, 6)?
        };
        // AIR's tail after the payload size: [?, triangle cull, geometry cull, opacity cull, forced opacity, assumed
        // geometry types, -1, -1, 0, (instancing: i1), accept any]; measured with every parameter set (rtopt4)
        let tail = usize::from(family.instancing != crate::meta::AirIntersectionInstancing::None);
        let params = IntersectionParams {
            triangle_cull_mode: id_operand(&call, n - 9 - tail)?,
            geometry_cull_mode: id_operand(&call, n - 8 - tail)?,
            opacity_cull_mode: id_operand(&call, n - 7 - tail)?,
            forced_opacity: id_operand(&call, n - 6 - tail)?,
            accept_any_intersection: id_operand(&call, n - 1)?,
        };
        if let Some(k) = fields.iter().position(|f| *f == crate::meta::AirIntersectionResultField::OpaquePointer) {
            if result_member_is_read(ctx, entry_idx, res, k as u32) {
                return Err(PRIMITIVE_DATA_REFUSAL.to_string());
            }
        }
        let mut split = CallSiteSplit::open(ctx, entry_idx, b, i, "air.intersect")?;
        let continuation = split.continuation(ctx);
        let query = lw.new_query_variable(ctx, entry_idx);
        let header = ctx.module.fresh_id();
        let cond = ctx.module.fresh_id();
        let body = ctx.module.fresh_id();
        let confirm = ctx.module.fresh_id();
        let sel_merge = ctx.module.fresh_id();
        let cont = ctx.module.fresh_id();
        let merge = ctx.module.fresh_id();

        let structure = lw.load_structure(&mut split.prefix, ctx, structure_var);
        lw.initialize(
            &mut split.prefix,
            ctx,
            query,
            structure,
            &params,
            mask,
            origin,
            tmin,
            dir,
            tmax,
        );
        split.branch_prefix_to(header);

        let mut blocks = Vec::new();
        blocks.push(labelled_block(
            header,
            vec![
                Instruction::new(
                    Op::LoopMerge,
                    None,
                    None,
                    vec![
                        Operand::IdRef(merge),
                        Operand::IdRef(cont),
                        Operand::LoopControl(LoopControl::NONE),
                    ],
                ),
                Instruction::new(Op::Branch, None, None, vec![Operand::IdRef(cond)]),
            ],
        ));
        let proceed = ctx.module.fresh_id();
        blocks.push(labelled_block(
            cond,
            vec![
                Instruction::new(
                    Op::RayQueryProceedKHR,
                    Some(lw.bool_ty),
                    Some(proceed),
                    vec![Operand::IdRef(query)],
                ),
                Instruction::new(
                    Op::BranchConditional,
                    None,
                    None,
                    vec![
                        Operand::IdRef(proceed),
                        Operand::IdRef(body),
                        Operand::IdRef(merge),
                    ],
                ),
            ],
        ));
        let mut body_insts = Vec::new();
        let candidate = lw.get(
            &mut body_insts,
            ctx,
            Op::RayQueryGetIntersectionTypeKHR,
            lw.uint,
            query,
            false,
        );
        let is_triangle = lw.equals(&mut body_insts, ctx, candidate, 0);
        body_insts.push(Instruction::new(
            Op::SelectionMerge,
            None,
            None,
            vec![
                Operand::IdRef(sel_merge),
                Operand::SelectionControl(SelectionControl::NONE),
            ],
        ));
        body_insts.push(Instruction::new(
            Op::BranchConditional,
            None,
            None,
            vec![
                Operand::IdRef(is_triangle),
                Operand::IdRef(confirm),
                Operand::IdRef(sel_merge),
            ],
        ));
        blocks.push(labelled_block(body, body_insts));
        blocks.push(labelled_block(
            confirm,
            vec![
                Instruction::new(
                    Op::RayQueryConfirmIntersectionKHR,
                    None,
                    None,
                    vec![Operand::IdRef(query)],
                ),
                Instruction::new(Op::Branch, None, None, vec![Operand::IdRef(sel_merge)]),
            ],
        ));
        blocks.push(labelled_block(
            sel_merge,
            vec![Instruction::new(
                Op::Branch,
                None,
                None,
                vec![Operand::IdRef(cont)],
            )],
        ));
        blocks.push(labelled_block(
            cont,
            vec![Instruction::new(
                Op::Branch,
                None,
                None,
                vec![Operand::IdRef(header)],
            )],
        ));

        use crate::meta::AirIntersectionResultField as Field;
        let mut m = Vec::new();
        let ty = lw.get(
            &mut m,
            ctx,
            Op::RayQueryGetIntersectionTypeKHR,
            member_ty(0)?,
            query,
            true,
        );
        let hit = lw.equals(&mut m, ctx, ty, 1);
        let hit_block = ctx.module.fresh_id();
        let result_block = ctx.module.fresh_id();
        m.push(Instruction::new(
            Op::SelectionMerge,
            None,
            None,
            vec![
                Operand::IdRef(result_block),
                Operand::SelectionControl(SelectionControl::NONE),
            ],
        ));
        m.push(Instruction::new(
            Op::BranchConditional,
            None,
            None,
            vec![
                Operand::IdRef(hit),
                Operand::IdRef(hit_block),
                Operand::IdRef(result_block),
            ],
        ));
        blocks.push(labelled_block(merge, m));

        let mut m = Vec::new();
        let mut values = Vec::with_capacity(fields.len());
        let mut matrices = [None, None];
        for (index, field) in fields.iter().enumerate() {
            let field_ty = member_ty(index)?;
            let value = match *field {
                Field::IntersectionType => ty,
                Field::OpaquePointer => {
                    // intersection_result::primitive_data: the device does not carry per-primitive data
                    // (supportsRayTracingPerPrimitiveData NO, builds with a primitive data buffer are refused); a read
                    // of it is refused here rather than handed a null pointer
                    ctx.get_or_create(Op::ConstantNull, Some(field_ty), Vec::new())
                }
                Field::UserInstanceId => {
                    let value = ctx.module.fresh_id();
                    let side = lw.side_table_for(ctx, structure_var)?;
                    lw.user_id(&mut m, ctx, field_ty, query, true, side, value);
                    value
                }
                Field::WorldSpaceVector(column) => {
                    let matrix_index = usize::from(column / 4);
                    let matrix = if let Some(matrix) = matrices[matrix_index] {
                        matrix
                    } else {
                        let matrix_ty = ctx.get_or_create(Op::TypeMatrix, None,
                            vec![Operand::IdRef(field_ty), Operand::LiteralBit32(4)]);
                        let op = if matrix_index == 0 { Op::RayQueryGetIntersectionWorldToObjectKHR }
                            else { Op::RayQueryGetIntersectionObjectToWorldKHR };
                        let matrix = lw.get(&mut m, ctx, op, matrix_ty, query, true);
                        matrices[matrix_index] = Some(matrix);
                        matrix
                    };
                    let value = ctx.module.fresh_id();
                    m.push(Instruction::new(Op::CompositeExtract, Some(field_ty), Some(value),
                        vec![Operand::IdRef(matrix), Operand::LiteralBit32(u32::from(column % 4))]));
                    value
                }
                Field::InstanceLevel => return Err("ray query: multi-level instancing requires hierarchy path metadata; unsupported".into()),
                field => {
                    let op = match field {
                        Field::Distance => Op::RayQueryGetIntersectionTKHR,
                        Field::PrimitiveId => Op::RayQueryGetIntersectionPrimitiveIndexKHR,
                        Field::GeometryId => Op::RayQueryGetIntersectionGeometryIndexKHR,
                        Field::InstanceId => Op::RayQueryGetIntersectionInstanceIdKHR,
                        Field::Barycentrics => Op::RayQueryGetIntersectionBarycentricsKHR,
                        Field::FrontFacing => Op::RayQueryGetIntersectionFrontFaceKHR,
                        _ => return Err("ray query: unhandled AIR result field".into()),
                    };
                    lw.get(&mut m, ctx, op, field_ty, query, true)
                }
            };
            values.push(Operand::IdRef(value));
        }
        let hit_result = ctx.module.fresh_id();
        m.push(Instruction::new(
            Op::CompositeConstruct,
            Some(rty),
            Some(hit_result),
            values,
        ));
        m.push(Instruction::new(
            Op::Branch,
            None,
            None,
            vec![Operand::IdRef(result_block)],
        ));
        blocks.push(labelled_block(hit_block, m));
        let miss_result = ctx.get_or_create(Op::ConstantNull, Some(rty), Vec::new());
        blocks.push(labelled_block(
            result_block,
            vec![
                Instruction::new(
                    Op::Phi,
                    Some(rty),
                    Some(res),
                    vec![
                        Operand::IdRef(miss_result),
                        Operand::IdRef(merge),
                        Operand::IdRef(hit_result),
                        Operand::IdRef(hit_block),
                    ],
                ),
                Instruction::new(Op::Branch, None, None, vec![Operand::IdRef(continuation)]),
            ],
        ));
        split.finish(ctx, entry_idx, blocks);
    }

    let dead = std::mem::take(&mut lw.dead_chains);
    for id in dead.into_iter().rev() {
        if !id_is_used(ctx, entry_idx, id) {
            remove_definition(ctx, entry_idx, id);
        }
    }
    for root in lw.structures.keys() {
        if id_is_used(ctx, entry_idx, *root) {
            return Err(format!(
                "ray query: the acceleration structure parameter %{root} is also used as ordinary memory; this pass carries it only as a structure"
            ));
        }
    }
    for alloc in lw.queries.keys() {
        if id_is_used(ctx, entry_idx, *alloc) {
            return Err(format!(
                "ray query: an intersection query (%{alloc}) is used outside its own calls"
            ));
        }
    }

    Ok(true)
}
