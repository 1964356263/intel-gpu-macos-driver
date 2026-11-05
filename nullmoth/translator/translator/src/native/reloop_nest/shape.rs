use std::collections::{BTreeMap, BTreeSet, VecDeque};

type Cut = BTreeSet<(Label, Label)>;

pub(super) type Label = u32;

pub(super) struct Graph {
    pub(super) entry: Label,
    pub(super) successors: BTreeMap<Label, Vec<Label>>,
    pub(super) predecessors: BTreeMap<Label, Vec<Label>>,
}

impl Graph {
    pub(super) fn new(entry: Label, successors: BTreeMap<Label, Vec<Label>>) -> Self {
        let mut predecessors: BTreeMap<Label, Vec<Label>> = BTreeMap::new();
        for label in successors.keys() {
            predecessors.entry(*label).or_default();
        }
        for (label, targets) in &successors {
            for target in targets {
                let list = predecessors.entry(*target).or_default();
                if !list.contains(label) {
                    list.push(*label);
                }
            }
        }
        Self {
            entry,
            successors,
            predecessors,
        }
    }

    pub(super) fn succ(&self, label: Label) -> &[Label] {
        self.successors.get(&label).map_or(&[], Vec::as_slice)
    }

    fn pred(&self, label: Label) -> &[Label] {
        self.predecessors.get(&label).map_or(&[], Vec::as_slice)
    }

    fn reachable_within(
        &self,
        label: Label,
        within: &BTreeSet<Label>,
        cut: &Cut,
    ) -> BTreeSet<Label> {
        let mut seen = BTreeSet::new();
        let mut queue = VecDeque::new();
        if within.contains(&label) {
            seen.insert(label);
            queue.push_back(label);
        }
        while let Some(current) = queue.pop_front() {
            for target in self.succ(current) {
                if within.contains(target)
                    && !cut.contains(&(current, *target))
                    && seen.insert(*target)
                {
                    queue.push_back(*target);
                }
            }
        }
        seen
    }

    pub(super) fn reachable(&self) -> BTreeSet<Label> {
        let all = self.successors.keys().copied().collect::<BTreeSet<_>>();
        self.reachable_within(self.entry, &all, &Cut::new())
    }

    pub(super) fn is_reducible(&self) -> bool {
        let dominators = self.dominators();
        let mut state: BTreeMap<Label, u8> = BTreeMap::new();
        let mut stack = vec![(self.entry, 0usize)];
        state.insert(self.entry, 1);
        while let Some((node, index)) = stack.pop() {
            let targets = self.succ(node);
            if index < targets.len() {
                stack.push((node, index + 1));
                let target = targets[index];
                match state.get(&target).copied().unwrap_or(0) {
                    0 => {
                        state.insert(target, 1);
                        stack.push((target, 0));
                    }
                    1 if !dominators.dominates(target, node) => {
                        return false;
                    }
                    _ => {}
                }
            } else {
                state.insert(node, 2);
            }
        }
        true
    }

    fn dominators(&self) -> Dominators {
        let index = self
            .successors
            .keys()
            .copied()
            .enumerate()
            .map(|(index, label)| (label, index))
            .collect::<BTreeMap<Label, usize>>();
        let Some(&entry) = index.get(&self.entry) else {
            return Dominators::default();
        };
        let swap = |slot: usize| match slot {
            0 => entry,
            slot if slot == entry => 0,
            slot => slot,
        };
        let mut successors = vec![Vec::new(); index.len()];
        for (label, targets) in &self.successors {
            successors[swap(index[label])] = targets
                .iter()
                .filter_map(|target| index.get(target).map(|target| swap(*target)))
                .collect();
        }
        let predecessors = crate::dominators::build_predecessors(&successors);
        let (_, intervals, _) = crate::dominators::dominance(&successors, &predecessors);
        Dominators {
            block: index
                .into_iter()
                .map(|(label, slot)| (label, swap(slot)))
                .collect(),
            intervals,
        }
    }
}

#[derive(Default)]
pub(super) struct Dominators {
    block: BTreeMap<Label, usize>,
    intervals: Vec<Option<(usize, usize)>>,
}

impl Dominators {
    pub(super) fn dominates(&self, ancestor: Label, node: Label) -> bool {
        let (Some(&ancestor), Some(&node)) = (self.block.get(&ancestor), self.block.get(&node))
        else {
            return false;
        };
        crate::dominators::dominates_interval(&self.intervals, ancestor, node)
    }

    #[cfg(test)]
    pub(super) fn reached(&self) -> usize {
        self.intervals.iter().filter(|slot| slot.is_some()).count()
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Shape {
    Simple {
        id: usize,
        label: Label,
        next: Option<Box<Shape>>,
    },
    Loop {
        id: usize,
        entries: BTreeSet<Label>,
        inner: Box<Shape>,
        next: Option<Box<Shape>>,
    },
    Multiple {
        id: usize,
        entries: BTreeSet<Label>,
        handled: Vec<(Label, Shape)>,
        next: Option<Box<Shape>>,
    },
}

impl Shape {
    pub(super) fn id(&self) -> usize {
        match self {
            Shape::Simple { id, .. } | Shape::Loop { id, .. } | Shape::Multiple { id, .. } => *id,
        }
    }

    pub(super) fn entry_labels(&self) -> BTreeSet<Label> {
        match self {
            Shape::Simple { label, .. } => BTreeSet::from([*label]),
            Shape::Loop { entries, .. } | Shape::Multiple { entries, .. } => entries.clone(),
        }
    }
}

/// The graph in indices: label order is index order, so ascending bits are ascending labels and the regions below
/// walk in the same order as sets of labels would. A function has one graph and many regions, each of them a set
/// asked about every edge, so a region is a bit set rather than a tree.
struct Dense {
    labels: Vec<Label>,
    succ: Vec<Vec<u32>>,
    pred: Vec<Vec<u32>>,
    words: usize,
}

impl Dense {
    fn new(graph: &Graph) -> Self {
        let labels = graph.predecessors.keys().copied().collect::<Vec<_>>();
        let index = |label: &Label| labels.binary_search(label).map(|i| i as u32).ok();
        let convert = |list: &[Label]| list.iter().filter_map(index).collect::<Vec<_>>();
        let succ = labels.iter().map(|label| convert(graph.succ(*label))).collect();
        let pred = labels.iter().map(|label| convert(graph.pred(*label))).collect();
        let words = labels.len().div_ceil(64);
        Self { labels, succ, pred, words }
    }

    fn label_set(&self, entries: &[u32]) -> BTreeSet<Label> {
        entries.iter().map(|entry| self.labels[*entry as usize]).collect()
    }
}

#[derive(Clone)]
struct Bits(Vec<u64>);

impl Bits {
    fn empty(words: usize) -> Self {
        Self(vec![0; words])
    }

    #[inline]
    fn has(&self, index: u32) -> bool {
        self.0[index as usize / 64] >> (index % 64) & 1 != 0
    }

    /// True when the bit was not set.
    #[inline]
    fn insert(&mut self, index: u32) -> bool {
        let word = &mut self.0[index as usize / 64];
        let bit = 1u64 << (index % 64);
        let new = *word & bit == 0;
        *word |= bit;
        new
    }

    #[inline]
    fn remove(&mut self, index: u32) {
        self.0[index as usize / 64] &= !(1u64 << (index % 64));
    }

    fn remove_all(&mut self, other: &Bits) {
        for (word, removed) in self.0.iter_mut().zip(&other.0) {
            *word &= !removed;
        }
    }

    fn is_empty(&self) -> bool {
        self.0.iter().all(|word| *word == 0)
    }

    fn iter(&self) -> impl Iterator<Item = u32> + '_ {
        self.0.iter().enumerate().flat_map(|(at, word)| {
            let mut word = *word;
            std::iter::from_fn(move || {
                (word != 0).then(|| {
                    let bit = word.trailing_zeros();
                    word &= word - 1;
                    at as u32 * 64 + bit
                })
            })
        })
    }
}

type DenseCut = crate::fxhash::HashSet<(u32, u32)>;

fn sorted_unique(mut list: Vec<u32>) -> Vec<u32> {
    list.sort_unstable();
    list.dedup();
    list
}

pub(super) fn calculate(graph: &Graph) -> Option<Shape> {
    let mut counter = 0usize;
    let dense = Dense::new(graph);
    let mut blocks = Bits::empty(dense.words);
    for label in graph.reachable() {
        blocks.insert(dense.labels.binary_search(&label).ok()? as u32);
    }
    // An entry the graph does not know is in no region: the empty shape.
    let entry = dense.labels.binary_search(&graph.entry).ok()? as u32;
    let mut cut = DenseCut::default();
    calculate_region(&dense, blocks, vec![entry], &mut cut, &mut counter)
}

/// `entries` is sorted and has no duplicates.
fn calculate_region(
    graph: &Dense,
    mut blocks: Bits,
    mut entries: Vec<u32>,
    cut: &mut DenseCut,
    counter: &mut usize,
) -> Option<Shape> {
    entries.retain(|entry| blocks.has(*entry));
    if entries.is_empty() {
        return None;
    }
    if let [label] = entries[..] {
        let reentered = graph.pred[label as usize]
            .iter()
            .any(|predecessor| blocks.has(*predecessor) && !cut.contains(&(*predecessor, label)));
        if !reentered {
            let id = fresh(counter);
            blocks.remove(label);
            let next_entries = sorted_unique(
                graph.succ[label as usize]
                    .iter()
                    .copied()
                    .filter(|target| blocks.has(*target) && !cut.contains(&(label, *target)))
                    .collect(),
            );
            let next = calculate_region(graph, blocks, next_entries, cut, counter);
            return Some(Shape::Simple {
                id,
                label: graph.labels[label as usize],
                next: next.map(Box::new),
            });
        }
        return Some(make_loop(graph, blocks, entries, cut, counter));
    }
    match independent_groups(graph, &blocks, &entries, cut) {
        Some(groups) => Some(make_multiple(graph, blocks, entries, groups, cut, counter)),
        None => Some(make_loop(graph, blocks, entries, cut, counter)),
    }
}

fn make_loop(
    graph: &Dense,
    mut blocks: Bits,
    entries: Vec<u32>,
    cut: &mut DenseCut,
    counter: &mut usize,
) -> Shape {
    let id = fresh(counter);
    let mut inner = Bits::empty(graph.words);
    let mut queue = entries.clone();
    while let Some(current) = queue.pop() {
        if !blocks.has(current) || !inner.insert(current) {
            continue;
        }
        for predecessor in &graph.pred[current as usize] {
            if blocks.has(*predecessor)
                && !cut.contains(&(*predecessor, current))
                && !inner.has(*predecessor)
            {
                queue.push(*predecessor);
            }
        }
    }
    blocks.remove_all(&inner);
    let mut next_entries = Vec::new();
    let mut back_edges = Vec::new();
    for label in inner.iter() {
        let successors = &graph.succ[label as usize];
        next_entries.extend(
            successors
                .iter()
                .copied()
                .filter(|target| blocks.has(*target) && !cut.contains(&(label, *target))),
        );
        back_edges.extend(
            entries
                .iter()
                .filter(|entry| successors.contains(entry))
                .map(|entry| (label, *entry)),
        );
    }
    let next_entries = sorted_unique(next_entries);
    let restore = back_edges
        .into_iter()
        .filter(|edge| cut.insert(*edge))
        .collect::<Vec<_>>();
    let body = calculate_region(graph, inner, entries.clone(), cut, counter);
    for edge in restore {
        cut.remove(&edge);
    }
    let next = calculate_region(graph, blocks, next_entries, cut, counter);
    let entries = graph.label_set(&entries);
    let inner = body.unwrap_or_else(|| Shape::Multiple {
        id: fresh(counter),
        entries: entries.clone(),
        handled: Vec::new(),
        next: None,
    });
    Shape::Loop {
        id,
        entries,
        inner: Box::new(inner),
        next: next.map(Box::new),
    }
}

fn make_multiple(
    graph: &Dense,
    mut blocks: Bits,
    entries: Vec<u32>,
    groups: Vec<(u32, Bits)>,
    cut: &mut DenseCut,
    counter: &mut usize,
) -> Shape {
    let id = fresh(counter);
    for (_, group) in &groups {
        blocks.remove_all(group);
    }
    let mut handled = Vec::with_capacity(groups.len());
    let mut next_entries = entries
        .iter()
        .copied()
        .filter(|entry| groups.binary_search_by_key(entry, |(group, _)| *group).is_err())
        .collect::<Vec<_>>();
    for (entry, group) in groups {
        for label in group.iter() {
            next_entries.extend(
                graph.succ[label as usize]
                    .iter()
                    .copied()
                    .filter(|target| blocks.has(*target) && !cut.contains(&(label, *target))),
            );
        }
        if let Some(shape) = calculate_region(graph, group, vec![entry], cut, counter) {
            handled.push((graph.labels[entry as usize], shape));
        }
    }
    let next = calculate_region(graph, blocks, sorted_unique(next_entries), cut, counter);
    Shape::Multiple {
        id,
        entries: graph.label_set(&entries),
        handled,
        next: next.map(Box::new),
    }
}

/// For each entry in order, the blocks only it reaches and which are not another entry.
fn independent_groups(
    graph: &Dense,
    blocks: &Bits,
    entries: &[u32],
    cut: &DenseCut,
) -> Option<Vec<(u32, Bits)>> {
    let mut reached_once = Bits::empty(graph.words);
    let mut reached_more = Bits::empty(graph.words);
    let mut groups = Vec::with_capacity(entries.len());
    let mut stack = Vec::new();
    for entry in entries {
        let mut seen = Bits::empty(graph.words);
        if blocks.has(*entry) {
            seen.insert(*entry);
            stack.push(*entry);
        }
        while let Some(current) = stack.pop() {
            for target in &graph.succ[current as usize] {
                if blocks.has(*target)
                    && !cut.contains(&(current, *target))
                    && seen.insert(*target)
                {
                    stack.push(*target);
                }
            }
        }
        for ((once, more), word) in reached_once.0.iter_mut().zip(&mut reached_more.0).zip(&seen.0) {
            *more |= *once & word;
            *once |= word;
        }
        groups.push((*entry, seen));
    }
    groups.retain_mut(|(entry, seen)| {
        seen.remove_all(&reached_more);
        for other in entries {
            if other != entry {
                seen.remove(*other);
            }
        }
        !seen.is_empty()
    });
    (!groups.is_empty()).then_some(groups)
}

fn fresh(counter: &mut usize) -> usize {
    let id = *counter;
    *counter += 1;
    id
}

#[cfg(test)]
mod tests {
    use super::*;

    fn graph(entry: Label, edges: &[(Label, &[Label])]) -> Graph {
        Graph::new(
            entry,
            edges
                .iter()
                .map(|(label, targets)| (*label, targets.to_vec()))
                .collect(),
        )
    }

    fn rendered(shape: &Shape, out: &mut Vec<Label>) {
        match shape {
            Shape::Simple { label, next, .. } => {
                out.push(*label);
                if let Some(next) = next {
                    rendered(next, out);
                }
            }
            Shape::Loop { inner, next, .. } => {
                rendered(inner, out);
                if let Some(next) = next {
                    rendered(next, out);
                }
            }
            Shape::Multiple { handled, next, .. } => {
                for (_, arm) in handled {
                    rendered(arm, out);
                }
                if let Some(next) = next {
                    rendered(next, out);
                }
            }
        }
    }

    #[test]
    fn straight_line_is_a_chain_of_simple_shapes() {
        let g = graph(1, &[(1, &[2]), (2, &[3]), (3, &[])]);
        let shape = calculate(&g).expect("shape");
        let mut order = Vec::new();
        rendered(&shape, &mut order);
        assert_eq!(order, vec![1, 2, 3]);
        assert!(matches!(shape, Shape::Simple { label: 1, .. }));
    }

    #[test]
    fn diamond_becomes_a_multiple_with_two_arms() {
        let g = graph(1, &[(1, &[2, 3]), (2, &[4]), (3, &[4]), (4, &[])]);
        let shape = calculate(&g).expect("shape");
        let Shape::Simple { label: 1, next, .. } = shape else {
            panic!("expected the header to be simple");
        };
        let next = next.expect("diamond has a continuation");
        let Shape::Multiple { handled, next, .. } = *next else {
            panic!("expected a dispatch over the two arms");
        };
        assert_eq!(
            handled.iter().map(|(label, _)| *label).collect::<Vec<_>>(),
            vec![2, 3]
        );
        assert!(matches!(
            next.as_deref(),
            Some(Shape::Simple { label: 4, .. })
        ));
    }

    #[test]
    fn if_without_else_puts_the_single_arm_in_the_multiple() {
        let g = graph(1, &[(1, &[2, 3]), (2, &[3]), (3, &[])]);
        let shape = calculate(&g).expect("shape");
        let Shape::Simple { next, .. } = shape else {
            panic!("expected simple header");
        };
        let Some(box_next) = next else {
            panic!("expected a continuation")
        };
        let Shape::Multiple { handled, next, .. } = *box_next else {
            panic!("expected a dispatch");
        };
        assert_eq!(
            handled.iter().map(|(label, _)| *label).collect::<Vec<_>>(),
            vec![2]
        );
        assert!(matches!(
            next.as_deref(),
            Some(Shape::Simple { label: 3, .. })
        ));
    }

    #[test]
    fn self_loop_becomes_a_loop_shape() {
        let g = graph(1, &[(1, &[2]), (2, &[2, 3]), (3, &[])]);
        let shape = calculate(&g).expect("shape");
        let Shape::Simple { label: 1, next, .. } = shape else {
            panic!("expected simple header");
        };
        let Shape::Loop { entries, next, .. } = *next.expect("loop follows") else {
            panic!("expected a loop");
        };
        assert_eq!(entries, BTreeSet::from([2]));
        assert!(matches!(
            next.as_deref(),
            Some(Shape::Simple { label: 3, .. })
        ));
    }

    #[test]
    fn nested_loops_nest_in_the_shape_tree() {
        let g = graph(
            1,
            &[(1, &[2]), (2, &[3]), (3, &[3, 4]), (4, &[2, 5]), (5, &[])],
        );
        let shape = calculate(&g).expect("shape");
        let Shape::Simple { next, .. } = shape else {
            panic!("expected simple header");
        };
        let Shape::Loop { inner, next, .. } = *next.expect("outer loop") else {
            panic!("expected the outer loop");
        };
        assert!(matches!(
            next.as_deref(),
            Some(Shape::Simple { label: 5, .. })
        ));
        let mut order = Vec::new();
        rendered(&inner, &mut order);
        assert_eq!(order, vec![2, 3, 4]);
    }

    #[test]
    fn every_reachable_block_is_rendered_exactly_once() {
        let g = graph(
            1,
            &[
                (1, &[2, 3]),
                (2, &[4]),
                (3, &[4, 5]),
                (4, &[6]),
                (5, &[6]),
                (6, &[7, 2]),
                (7, &[]),
            ],
        );
        let shape = calculate(&g).expect("shape");
        let mut order = Vec::new();
        rendered(&shape, &mut order);
        let unique = order.iter().copied().collect::<BTreeSet<_>>();
        assert_eq!(order.len(), unique.len(), "rendered twice: {order:?}");
        assert_eq!(unique, g.reachable());
    }

    #[test]
    fn unreachable_blocks_are_not_rendered() {
        let g = graph(1, &[(1, &[2]), (2, &[]), (9, &[2])]);
        let shape = calculate(&g).expect("shape");
        let mut order = Vec::new();
        rendered(&shape, &mut order);
        assert_eq!(order, vec![1, 2]);
    }

    #[test]
    fn reducible_graphs_are_recognized() {
        let reducible = graph(1, &[(1, &[2]), (2, &[3, 4]), (3, &[2]), (4, &[])]);
        assert!(reducible.is_reducible());
        let irreducible = graph(1, &[(1, &[2, 3]), (2, &[3]), (3, &[2])]);
        assert!(!irreducible.is_reducible());
    }

    fn dense_dominators(graph: &Graph) -> BTreeMap<Label, BTreeSet<Label>> {
        let reachable = graph.reachable();
        let mut dominators: BTreeMap<Label, BTreeSet<Label>> = reachable
            .iter()
            .map(|label| (*label, reachable.clone()))
            .collect();
        if let Some(entry) = dominators.get_mut(&graph.entry) {
            *entry = BTreeSet::from([graph.entry]);
        }
        let mut changed = true;
        while changed {
            changed = false;
            for label in &reachable {
                if *label == graph.entry {
                    continue;
                }
                let mut incoming = graph
                    .pred(*label)
                    .iter()
                    .filter(|predecessor| reachable.contains(predecessor))
                    .filter_map(|predecessor| dominators.get(predecessor));
                let Some(first) = incoming.next() else {
                    continue;
                };
                let mut next = first.clone();
                for other in incoming {
                    next.retain(|candidate| other.contains(candidate));
                }
                next.insert(*label);
                if dominators.get(label) != Some(&next) {
                    dominators.insert(*label, next);
                    changed = true;
                }
            }
        }
        dominators
    }

    fn assert_matches_dense(graph: &Graph, what: &str) {
        let dense = dense_dominators(graph);
        let tree = graph.dominators();
        let reachable = graph.reachable();
        for node in &reachable {
            for ancestor in &reachable {
                assert_eq!(
                    tree.dominates(*ancestor, *node),
                    dense[node].contains(ancestor),
                    "{what}: disagreement on whether %{ancestor} dominates %{node}"
                );
            }
        }
    }

    #[test]
    fn the_dominator_tree_agrees_with_the_dominator_sets() {
        for (what, graph) in [
            ("straight line", graph(1, &[(1, &[2]), (2, &[3]), (3, &[])])),
            (
                "diamond",
                graph(1, &[(1, &[2, 3]), (2, &[4]), (3, &[4]), (4, &[])]),
            ),
            (
                "loop with an exit",
                graph(1, &[(1, &[2]), (2, &[3, 4]), (3, &[2]), (4, &[])]),
            ),
            (
                "nested loops",
                graph(
                    1,
                    &[(1, &[2]), (2, &[3]), (3, &[3, 4]), (4, &[2, 5]), (5, &[])],
                ),
            ),
            ("self loop", graph(1, &[(1, &[1, 2]), (2, &[])])),
            (
                "irreducible pair",
                graph(1, &[(1, &[2, 3]), (2, &[3]), (3, &[2])]),
            ),
            (
                "unreachable block",
                graph(1, &[(1, &[2]), (2, &[]), (9, &[2])]),
            ),
            (
                "two paths rejoining under a loop",
                graph(
                    1,
                    &[
                        (1, &[2, 3]),
                        (2, &[4]),
                        (3, &[4]),
                        (4, &[5, 6]),
                        (5, &[4]),
                        (6, &[]),
                    ],
                ),
            ),
        ] {
            assert_matches_dense(&graph, what);
        }
    }

    #[test]
    fn the_dominator_structure_stays_linear_in_the_block_count() {
        let mut edges: Vec<(Label, Vec<Label>)> = Vec::new();
        let diamonds = 2_000;
        for index in 0..diamonds {
            let head = index * 4 + 1;
            edges.push((head, vec![head + 1, head + 2]));
            edges.push((head + 1, vec![head + 3]));
            edges.push((head + 2, vec![head + 3]));
            edges.push((head + 3, vec![head + 4]));
        }
        let last = diamonds * 4 + 1;
        edges.push((last, vec![]));
        let graph = Graph::new(
            1,
            edges.into_iter().collect::<BTreeMap<Label, Vec<Label>>>(),
        );
        let blocks = graph.reachable().len();
        assert_eq!(blocks, (diamonds * 4 + 1) as usize);
        assert!(graph.is_reducible());
        assert_eq!(graph.dominators().reached(), blocks);
    }
}
