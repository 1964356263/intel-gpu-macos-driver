//! Reflection asks whether a kernel needs the device-address model, and answers it from the same normalized
//! text and typed module the translation that follows builds again: on a large compute kernel the two passes
//! were about 45% of the whole translation. Within a `with_module_reuse` scope the first result is kept and
//! the translation takes it.
//!
//! The key is the full input, not a hash: the source text, the entry name, the kernel metadata, and the one
//! thread-local flag that reaches the parser (function constants taken as unknown). The parsed module is moved
//! out by the one consumer, so nothing shares a module that the emitter then changes. Outside a scope nothing is
//! stored, and leaving the outermost scope frees the entry, so a long-lived process keeps nothing.
use super::inline::PointerConsumerInlining;
use super::ir::LlModule;
use crate::meta;
use std::any::Any;
use std::borrow::Cow;
use std::cell::{Cell, RefCell};
use std::mem::Discriminant;

/// `lower_air_text` from one text to its result: None when the text came back unchanged.
type LoweredMemo = (String, Option<String>);

struct StageMetaMemo {
    input: String,
    stage: Discriminant<crate::passes::Stage>,
    function_constants_unknown: bool,
    value: Box<dyn Any>,
}

struct Entry {
    input: String,
    entry_name: Option<String>,
    function_constants_unknown: bool,
    normalized: String,
    requires_relooper: bool,
    parsed: Option<(LlModule, String)>,
}

thread_local! {
    static DEPTH: Cell<usize> = const { Cell::new(0) };
    static ENTRY: RefCell<Option<Entry>> = const { RefCell::new(None) };
    static LOWERED: RefCell<Vec<LoweredMemo>> = const { RefCell::new(Vec::new()) };
    static STAGE_META: RefCell<Option<StageMetaMemo>> = const { RefCell::new(None) };
}

/// `compute(san_ll)`, remembered per text. Reflection and translation lower the same text, and reflection's check
/// lowers that result once more, hence two texts.
pub(super) fn lowered<'a>(
    san_ll: &'a str,
    compute: impl FnOnce(&'a str) -> Cow<'a, str>,
) -> Cow<'a, str> {
    if !active() {
        return compute(san_ll);
    }
    let known = LOWERED.with(|memo| {
        memo.borrow()
            .iter()
            .find(|(input, _)| input == san_ll)
            .map(|(_, output)| output.clone())
    });
    if let Some(output) = known {
        return output.map_or(Cow::Borrowed(san_ll), Cow::Owned);
    }
    let output = compute(san_ll);
    let kept = match &output {
        Cow::Borrowed(_) => None,
        Cow::Owned(text) => Some(text.clone()),
    };
    LOWERED.with(|memo| {
        let mut memo = memo.borrow_mut();
        if memo.len() == 2 {
            memo.remove(0);
        }
        memo.push((san_ll.to_string(), kept));
    });
    output
}

/// `compute()`, remembered for this text and stage.
pub fn stage_meta<T: Clone + 'static>(
    san_ll: &str,
    stage: crate::passes::Stage,
    compute: impl FnOnce() -> T,
) -> T {
    if !active() {
        return compute();
    }
    let stage = std::mem::discriminant(&stage);
    let unknown = meta::function_constants_are_unknown();
    let known = STAGE_META.with(|memo| {
        let memo = memo.borrow();
        let memo = memo.as_ref()?;
        (memo.stage == stage && memo.function_constants_unknown == unknown && memo.input == san_ll)
            .then(|| memo.value.downcast_ref::<T>().cloned())
            .flatten()
    });
    if let Some(value) = known {
        return value;
    }
    let value = compute();
    STAGE_META.with(|memo| {
        *memo.borrow_mut() = Some(StageMetaMemo {
            input: san_ll.to_string(),
            stage,
            function_constants_unknown: unknown,
            value: Box::new(value.clone()),
        });
    });
    value
}

/// Runs `f` with the reuse on; the entry lives until the outermost scope ends.
pub fn with_module_reuse<R>(f: impl FnOnce() -> R) -> R {
    struct Scope;
    impl Drop for Scope {
        fn drop(&mut self) {
            let depth = DEPTH.with(|depth| {
                depth.set(depth.get() - 1);
                depth.get()
            });
            if depth == 0 {
                ENTRY.with(|entry| *entry.borrow_mut() = None);
                LOWERED.with(|memo| memo.borrow_mut().clear());
                STAGE_META.with(|memo| *memo.borrow_mut() = None);
            }
        }
    }
    DEPTH.with(|depth| depth.set(depth.get() + 1));
    let _scope = Scope;
    f()
}

fn active() -> bool {
    DEPTH.with(|depth| depth.get() > 0)
}

fn kern_key(kern: Option<&meta::KernMeta>) -> String {
    format!("{kern:?}")
}

fn matches_input(entry: &Entry, san_ll: &str, entry_name: Option<&str>) -> bool {
    entry.function_constants_unknown == meta::function_constants_are_unknown()
        && entry.entry_name.as_deref() == entry_name
        && entry.input == san_ll
}

/// Keeps what `requires_device_address_model_for_source` built from `san_ll`.
pub(super) fn store(
    san_ll: &str,
    entry_name: Option<&str>,
    normalized: String,
    requires_relooper: bool,
    parsed: Option<LlModule>,
    kern: Option<&meta::KernMeta>,
) {
    if !active() {
        return;
    }
    let parsed = parsed.map(|parsed| (parsed, kern_key(kern)));
    ENTRY.with(|entry| {
        *entry.borrow_mut() = Some(Entry {
            input: san_ll.to_string(),
            entry_name: entry_name.map(str::to_string),
            function_constants_unknown: meta::function_constants_are_unknown(),
            normalized,
            requires_relooper,
            parsed,
        });
    });
}

/// The normalized form of `san_ll`, when it is the text kept in this scope. It stays in the entry, because a second
/// attempt at the same input (the wrapper's fallback without formatless storage images) needs it as well.
pub(super) fn normalized(san_ll: &str, entry_name: Option<&str>) -> Option<PointerConsumerInlining> {
    ENTRY.with(|entry| {
        let entry = entry.borrow();
        let entry = entry.as_ref()?;
        matches_input(entry, san_ll, entry_name).then(|| PointerConsumerInlining {
            source: entry.normalized.clone(),
            requires_relooper: entry.requires_relooper,
        })
    })
}

/// Moves out the module parsed from exactly `source` with this metadata. A later attempt parses again.
pub(super) fn take_parsed(
    source: &str,
    kern: Option<&meta::KernMeta>,
    entry_name: Option<&str>,
) -> Option<LlModule> {
    ENTRY.with(|entry| {
        let mut entry = entry.borrow_mut();
        let entry = entry.as_mut()?;
        if entry.function_constants_unknown != meta::function_constants_are_unknown()
            || entry.entry_name.as_deref() != entry_name
            || entry.normalized != source
            || entry.parsed.as_ref()?.1 != kern_key(kern)
        {
            return None;
        }
        entry.parsed.take().map(|(parsed, _)| parsed)
    })
}
