//! Lazily built per-segment indexes and failure memos that keep the inline
//! scans linear on unclosed delimiters.
//!
//! The reference answers each question by walking the text from the
//! delimiter that asks. On a text with many delimiters and no closing one,
//! every walk reads to the end: quadratic time. Here each question is
//! answered from a structure built once per text segment, the first time a
//! scan of that kind runs in it (nothing is allocated for a kind that never
//! runs), or from a memo of an earlier failed walk. Every answer is the one
//! the walk would give; the argument sits at each function, and the unit
//! tests at the end of this file check each against the walk itself on
//! random text.
//!
//! Positions are bytes of the segment. The scans only move forward, so the
//! questions of a kind arrive with growing positions; the memos are correct
//! for any order (they check their own range) and fast for that one.

use super::jsstr::at;
use super::scan::{quote_blank, sub};
use std::collections::HashMap;
use std::hash::{BuildHasher, Hasher};

/// Deviation D4: the work the names with a starred atom (two or more `*` in
/// the name of a `\begin{..}`) may cost in one text segment, in units, is this
/// many per byte of the segment plus [`STAR_WORK_BASE`]. A unit is one state
/// set word handled by the walk over the trie, one byte of a pattern built,
/// and a key or an occurrence put into a match set or a merged group (times
/// the logarithm of their number, for the sort). Once the segment has spent
/// it, a name with a starred atom that was not answered before is plain text,
/// as if its pattern were invalid. The state sets of the path the walk is on
/// are bounded as well: at most one word per byte of the segment plus
/// [`STAR_SET_WORDS_BASE`] words. See `EnvIndex::place_for`.
pub const STAR_WORK_FACTOR: usize = 16;

/// The part of the work budget that does not depend on the segment, so that
/// every ordinary text is far below it.
pub const STAR_WORK_BASE: usize = 1 << 20;

/// The words of state sets, beyond one per byte of the segment, that the walk
/// over the trie may hold at once.
pub const STAR_SET_WORDS_BASE: usize = 4096;

/// The two closing characters a `\(` or `\[` walk looks for, as an index.
fn slot(close: u8) -> usize {
    usize::from(close == b']')
}

/// The hasher of the indexes: one multiply and a rotate per word, a seed
/// that differs per process and segment (the address of the text, which
/// address randomization changes per run), and an avalanche at the end. The
/// multiply alone leaves the high bits of the last word out of the low bits
/// of the product, and hashbrown reads the low bits (the bucket) and the top
/// seven bits (the tag) of the hash, so keys that differ only in those high
/// bits would share both whatever the seed; the finalizer mixes every bit
/// into every other. The keys are short, and the default hasher costs more
/// than the lookup it serves on the hot paths below.
struct Fx(u64);

const FX_K: u64 = 0x517c_c1b7_2722_0a95;

impl Fx {
    fn add(&mut self, w: u64) {
        self.0 = (self.0.rotate_left(5) ^ w).wrapping_mul(FX_K);
    }
}

impl Hasher for Fx {
    fn write(&mut self, bytes: &[u8]) {
        for chunk in bytes.chunks(8) {
            let mut w = 0u64;
            for (i, &b) in chunk.iter().enumerate() {
                w |= u64::from(b) << (8 * i);
            }
            self.add(w);
        }
    }

    fn write_usize(&mut self, n: usize) {
        self.add(n as u64);
    }

    fn finish(&self) -> u64 {
        // the 64-bit finalizer of splitmix64: a bijection that mixes all bits
        let mut x = self.0;
        x ^= x >> 30;
        x = x.wrapping_mul(0xbf58_476d_1ce4_e5b9);
        x ^= x >> 27;
        x = x.wrapping_mul(0x94d0_49bb_1331_11eb);
        x ^ (x >> 31)
    }
}

#[derive(Clone, Copy)]
struct Seeded(u64);

impl BuildHasher for Seeded {
    type Hasher = Fx;

    fn build_hasher(&self) -> Fx {
        Fx(self.0)
    }
}

type Map<K, V> = HashMap<K, V, Seeded>;

fn new_map<K, V>(s: &[u8]) -> Map<K, V> {
    HashMap::with_hasher(Seeded(
        (s.as_ptr() as usize as u64) ^ ((s.len() as u64) << 32),
    ))
}

/// The number of items of the sorted `v` for which `below` holds (the first
/// index where it stops holding), starting the search at `*hint` and leaving
/// the answer there. The questions of a scan come with growing positions, so
/// the answer is at the hint or a few places after it; a few steps find it,
/// and a binary search over the rest takes over when they do not. A hint that
/// is past the answer (the questions went back) is searched back from.
fn lower_bound<T>(v: &[T], hint: &mut usize, below: impl Fn(&T) -> bool) -> usize {
    let mut i = (*hint).min(v.len());
    let behind = i > 0 && v.get(i - 1).is_some_and(|x| !below(x));
    if behind {
        i = v.get(..i).map_or(0, |head| head.partition_point(&below));
    } else {
        let mut steps = 0;
        while steps < 8 && v.get(i).is_some_and(&below) {
            i += 1;
            steps += 1;
        }
        if v.get(i).is_some_and(&below) {
            i += v.get(i..).map_or(0, |rest| rest.partition_point(&below));
        }
    }
    *hint = i;
    i
}

/// One `\begin{w}` or `\end{w}` with `w` made of letters and `*`.
#[derive(Clone, Copy)]
struct Ev {
    /// Where the backslash is.
    pos: usize,
    /// One past the closing brace.
    end: usize,
    /// `\begin` rather than `\end`.
    begin: bool,
}

/// The occurrences a pattern matches, in order, with the running depth that
/// answers "where does the environment opened here close".
struct Group {
    /// The events, ascending by position.
    ev: Vec<Ev>,
    /// Whether any event is an `\end`; without one nothing can close.
    has_end: bool,
    ready: bool,
    /// `before[i]`: begins minus ends among `ev[..i]`. Filled by `prepare`
    /// (only for a group with an end).
    before: Vec<i64>,
    /// The smallest count of begins minus ends right after an end.
    lo: i64,
    /// The ends grouped by the count right after them: the events `t` with
    /// count `v` are `flat[off[v - lo]..off[v - lo + 1]]`, ascending. The
    /// counts change by one per event, so they fill a contiguous range and a
    /// counting sort lays them out.
    off: Vec<usize>,
    flat: Vec<usize>,
}

impl Group {
    fn new() -> Group {
        Group {
            ev: Vec::new(),
            has_end: false,
            ready: false,
            before: Vec::new(),
            lo: 0,
            off: Vec::new(),
            flat: Vec::new(),
        }
    }

    fn push(&mut self, e: Ev) {
        self.has_end |= !e.begin;
        self.ev.push(e);
    }

    /// Fills `before`, `off` and `flat` from the events of the group.
    fn prepare(&mut self) {
        if self.ready || !self.has_end {
            return;
        }
        self.before.reserve(self.ev.len());
        let mut count = 0i64;
        let (mut lo, mut hi) = (i64::MAX, i64::MIN);
        for e in &self.ev {
            self.before.push(count);
            if e.begin {
                count += 1;
            } else {
                count -= 1;
                lo = lo.min(count);
                hi = hi.max(count);
            }
        }
        self.lo = lo;
        let width = usize::try_from(hi - lo + 1).unwrap_or(0);
        let mut off = vec![0usize; width + 1];
        for (e, &b) in self.ev.iter().zip(&self.before) {
            if !e.begin {
                if let Some(c) = off.get_mut((b - 1 - lo) as usize + 1) {
                    *c += 1;
                }
            }
        }
        let mut acc = 0;
        for c in off.iter_mut() {
            acc += *c;
            *c = acc;
        }
        let mut fill = off.clone();
        self.flat = vec![0usize; off.last().copied().unwrap_or(0)];
        for (t, (e, &b)) in self.ev.iter().zip(&self.before).enumerate() {
            if !e.begin {
                let v = (b - 1 - lo) as usize;
                if let Some(slot) = fill.get_mut(v) {
                    if let Some(x) = self.flat.get_mut(*slot) {
                        *x = t;
                    }
                    *slot += 1;
                }
            }
        }
        self.off = off;
        self.ready = true;
    }

    /// The end of the first `\end` at or after `k` that brings the depth,
    /// counted from the first event at or after `k`, back to 0.
    ///
    /// The reference counts from 0 at the first matching occurrence `i0` at
    /// or after `k`: a begin adds 1, an end subtracts 1, and the answer is
    /// the first end that leaves 0. The depth after event `t` of that walk is
    /// `after[t] - before[i0]` (`after[t] = before[t + 1]`), so the answer is
    /// the first end `t >= i0` whose count after it equals `before[i0]`:
    /// the first entry `>= i0` of the ends with count `before[i0]`.
    fn close_from(&self, k: usize) -> Option<usize> {
        if !self.has_end {
            return None;
        }
        let i0 = self.ev.partition_point(|e| e.pos < k);
        let want = *self.before.get(i0)?;
        let v = usize::try_from(want.checked_sub(self.lo)?).ok()?;
        let ends = self.flat.get(*self.off.get(v)?..*self.off.get(v + 1)?)?;
        let t = *ends.get(ends.partition_point(|&t| t < i0))?;
        self.ev.get(t).map(|e| e.end)
    }
}

/// Where the occurrences a name's lookup runs over are kept.
#[derive(Clone, Copy)]
enum Place {
    /// The group of one distinct `w`.
    Name(usize),
    /// A merged group.
    Merged(usize),
}

/// Every occurrence of the segment, grouped by the exact text between the
/// braces, and the merged groups of patterns with a starred atom.
struct EnvIndex<'a> {
    /// The distinct `w` of the segment and the occurrences of each.
    keys: Vec<&'a [u8]>,
    groups: Vec<Group>,
    /// `w` to its place in `keys` and `groups`.
    by_name: Map<&'a [u8], usize>,
    /// The distinct `w` as a trie, built when the first pattern with a starred
    /// atom (two or more `*` in the name) is asked about.
    trie: Option<Trie>,
    /// The merged groups of patterns that match two or more distinct `w`.
    merged: Vec<Group>,
    /// A pattern name to where its occurrences are.
    by_pattern: Map<&'a [u8], Place>,
    /// The set of `w` a pattern matches (ascending places in `keys`) to its
    /// merged group: names that match the same `w` share one group.
    by_set: std::collections::HashMap<Vec<usize>, usize>,
    /// The group of a pattern that matches no `w`.
    empty: Group,
    /// Buffers of the trie walk, kept between names.
    walk: Walk,
    /// Every occurrence of the segment.
    total_events: usize,
    /// Events and ids held by the merged groups and the match sets. Once they
    /// pass a constant times `total_events` the work budget is spent (see
    /// [`EnvIndex::place_for`]), so they never pass it by more than one group.
    retained: usize,
    /// What is left of the work budget of the names with a starred atom
    /// (deviation D4, [`STAR_WORK_FACTOR`]); zero once it is spent.
    work_left: usize,
    /// The length of the segment: the bound of the walk's state sets.
    seg_len: usize,
}

impl<'a> EnvIndex<'a> {
    /// One pass over the backslashes of the segment. The occurrences cannot
    /// overlap (each has a single backslash, at its start), so the pass
    /// finds the same ones as the reference's sequential regex search.
    fn build(s: &'a [u8]) -> EnvIndex<'a> {
        let mut ix = EnvIndex {
            keys: Vec::new(),
            groups: Vec::new(),
            by_name: new_map(s),
            trie: None,
            merged: Vec::new(),
            by_pattern: new_map(s),
            by_set: std::collections::HashMap::new(),
            empty: Group::new(),
            walk: Walk::default(),
            total_events: 0,
            retained: 0,
            work_left: STAR_WORK_FACTOR
                .saturating_mul(s.len())
                .saturating_add(STAR_WORK_BASE),
            seg_len: s.len(),
        };
        let mut i = 0;
        while let Some(off) = s.get(i..).and_then(|r| r.iter().position(|&c| c == b'\\')) {
            let p = i + off;
            let (begin, open) = if sub(s, p, p + 7) == b"\\begin{" {
                (true, p + 7)
            } else if sub(s, p, p + 5) == b"\\end{" {
                (false, p + 5)
            } else {
                i = p + 1;
                continue;
            };
            let mut q = open;
            while at(s, q).is_ascii_alphabetic() || at(s, q) == b'*' {
                q += 1;
            }
            if at(s, q) == b'}' {
                let w = sub(s, open, q);
                let slot = match ix.by_name.get(w) {
                    Some(&slot) => slot,
                    None => {
                        let slot = ix.keys.len();
                        ix.keys.push(w);
                        ix.groups.push(Group::new());
                        ix.by_name.insert(w, slot);
                        slot
                    }
                };
                if let Some(g) = ix.groups.get_mut(slot) {
                    g.push(Ev {
                        pos: p,
                        end: q + 1,
                        begin,
                    });
                    ix.total_events += 1;
                }
                i = q + 1;
            } else {
                i = p + 1;
            }
        }
        ix
    }

    /// The end of the `\end{name}` that closes the `\begin{name}` at `k`.
    ///
    /// The reference matches, from `k` on, every `\begin{w}` and `\end{w}`
    /// whose `w` fully matches the pattern built from `name`. For a name with
    /// at most one `*` that pattern matches only `w == name` (the first `*`
    /// is escaped, so a literal), and the matching occurrences are exactly
    /// the group of that name. A name with more stars gives a pattern with
    /// repeated atoms, which matches several `w`: the `w` that match are
    /// found by walking the pattern over a trie of the distinct `w` of the
    /// segment (see [`Trie::matching`]) and their groups are merged, once
    /// per distinct set of `w`. A name whose pattern the reference cannot
    /// compile (a repeat of a repeat) matches nothing.
    ///
    /// The cost of a name with a starred atom is the part of the trie its
    /// pattern can reach, not the number of distinct `w`: a text of many
    /// distinct `<letters>**` or `**<letters>` names is linear. A text whose
    /// names together cost more than the work budget of the segment (deviation
    /// D4, [`STAR_WORK_FACTOR`]) is not answered past it: such a name that was
    /// not answered before is not an environment (see [`EnvIndex::place_for`]).
    fn end(&mut self, k: usize, name: &'a [u8]) -> Option<usize> {
        let stars = name.iter().filter(|&&c| c == b'*').count();
        let place = if stars <= 1 {
            Place::Name(*self.by_name.get(name)?)
        } else {
            match self.by_pattern.get(name) {
                Some(&place) => place,
                None => {
                    let place = self.place_for(name)?;
                    self.by_pattern.insert(name, place);
                    place
                }
            }
        };
        let g = match place {
            Place::Name(i) => self.groups.get_mut(i)?,
            Place::Merged(i) if i == usize::MAX => &mut self.empty,
            Place::Merged(i) => self.merged.get_mut(i)?,
        };
        g.prepare();
        g.close_from(k)
    }

    /// Where the occurrences of a name with a starred atom are: the group of
    /// the one `w` it matches, the group of the empty set when it matches
    /// none, or a merged group, made if no name with the same matches made
    /// one before. `None` for a name that is not a valid pattern, and for a
    /// name that comes after the work budget of the segment is spent.
    ///
    /// The merged groups are kept for the names that made them, and a text of
    /// very many distinct names that each match thousands of the others would
    /// make them as large as the product of the two. So they are bounded: when
    /// the events and ids they hold pass twice the number of occurrences of
    /// the segment (plus a floor), the work budget is spent, and no name with
    /// a starred atom that was not answered before gets an answer after the
    /// one that passed it. Nothing is dropped, so a name answered before keeps
    /// its answer whatever else is asked (the memo in `by_pattern` is never
    /// shortened), and the groups are at most the bound plus the last one,
    /// which is at most the occurrences of the segment and its keys.
    ///
    /// The work is bounded as well (deviation D4): the walk over the trie, the
    /// pattern, the sort and the hashing of the match set and the merged group
    /// are charged to `work_left` in the units of [`STAR_WORK_FACTOR`], and a
    /// walk that cannot finish within what is left, or whose state sets would
    /// pass `set_cap` words, stops. Without it a name with `N` starred atoms
    /// read along a key of `M` bytes takes `M * N / 64` word steps, and `K`
    /// names that each match `K` keys cost `K * K`; with it both are at most a
    /// constant times the segment. The names that come after the budget is
    /// spent are plain text, as a name the reference cannot compile is; the
    /// ones answered before keep their answers.
    fn place_for(&mut self, name: &[u8]) -> Option<Place> {
        if self.work_left == 0 {
            return None;
        }
        let atoms = env_atoms(name)?;
        let pattern = Pattern::new(&atoms);
        self.charge(atoms.len() + pattern.data.len());
        let keys = &self.keys;
        let trie = self.trie.get_or_insert_with(|| Trie::new(keys));
        let set_cap = self.seg_len.saturating_add(STAR_SET_WORDS_BASE);
        if !trie.matching(keys, &pattern, &mut self.walk, &mut self.work_left, set_cap) {
            return None;
        }
        let found = &mut self.walk.found;
        let sorting = sort_units(found.len());
        self.work_left = self.work_left.saturating_sub(sorting);
        match found.as_slice() {
            [] => return Some(Place::Merged(usize::MAX)),
            [one] => return Some(Place::Name(*one)),
            _ => {}
        }
        found.sort_unstable();
        if let Some(&slot) = self.by_set.get(found.as_slice()) {
            return Some(Place::Merged(slot));
        }
        let mut merged = Group::new();
        for &w in found.iter() {
            if let Some(g) = self.groups.get(w) {
                for &e in &g.ev {
                    merged.push(e);
                }
            }
        }
        merged.ev.sort_unstable_by_key(|e| e.pos);
        self.work_left = self.work_left.saturating_sub(sort_units(merged.ev.len()));
        self.retained += merged.ev.len() + found.len();
        if self.retained > 2 * self.total_events + 4096 {
            // the groups are as large as they may be: this one is the last
            self.work_left = 0;
        }
        let slot = self.merged.len();
        self.merged.push(merged);
        self.by_set.insert(found.clone(), slot);
        Some(Place::Merged(slot))
    }

    /// Takes `units` from the work budget, down to zero.
    fn charge(&mut self, units: usize) {
        self.work_left = self.work_left.saturating_sub(units);
    }
}

/// The work units of sorting and hashing `n` items: each costs a constant and
/// the number of comparisons it takes part in.
fn sort_units(n: usize) -> usize {
    n.saturating_mul(2 + (usize::BITS - n.leading_zeros()) as usize)
}

/// One element of a `\begin{name}` pattern: a byte, possibly repeated.
pub(crate) struct Atom {
    pub(crate) byte: u8,
    pub(crate) star: bool,
}

/// The reference builds `\\(begin|end)\{` + name with only its first `*`
/// escaped + `\}`. Every later `*` is a quantifier on the byte before it. A
/// quantifier on a quantifier makes the pattern invalid, which throws in the
/// reference; here that is `None` and the text is not an environment.
pub(crate) fn env_atoms(name: &[u8]) -> Option<Vec<Atom>> {
    let mut atoms: Vec<Atom> = Vec::with_capacity(name.len());
    let mut seen_star = false;
    for &b in name {
        if b == b'*' && seen_star {
            match atoms.last_mut() {
                Some(a) if !a.star => a.star = true,
                _ => return None,
            }
        } else {
            seen_star |= b == b'*';
            atoms.push(Atom {
                byte: b,
                star: false,
            });
        }
    }
    Some(atoms)
}

/// Whether `w` matches the whole pattern `atoms`, by the plainest walk of the
/// automaton. The oracle the trie walk is tested against.
#[cfg(test)]
pub(crate) fn atoms_match(atoms: &[Atom], w: &[u8]) -> bool {
    if atoms.iter().all(|a| !a.star) {
        return atoms.len() == w.len() && atoms.iter().zip(w).all(|(a, &b)| a.byte == b);
    }
    // a small NFA: state i means "atoms before i are matched"
    let m = atoms.len();
    let close = |set: &mut [bool]| {
        for (i, a) in atoms.iter().enumerate() {
            if a.star && set.get(i).copied().unwrap_or(false) {
                if let Some(next) = set.get_mut(i + 1) {
                    *next = true;
                }
            }
        }
    };
    let mut cur = vec![false; m + 1];
    let mut next = vec![false; m + 1];
    if let Some(first) = cur.first_mut() {
        *first = true;
    }
    close(&mut cur);
    for &b in w {
        next.iter_mut().for_each(|x| *x = false);
        for (i, a) in atoms.iter().enumerate() {
            if cur.get(i).copied().unwrap_or(false) && a.byte == b {
                let to = if a.star { i } else { i + 1 };
                if let Some(x) = next.get_mut(to) {
                    *x = true;
                }
            }
        }
        close(&mut next);
        std::mem::swap(&mut cur, &mut next);
    }
    cur.get(m).copied().unwrap_or(false)
}

/// A pattern as a bit-parallel automaton. State `i` (bit `i` of a set) means
/// "the atoms before `i` are matched"; the pattern matches when state `m`
/// (the atom count) is reached. A set is `words` machine words, so a pattern
/// of any length works; one word covers up to 63 atoms.
struct Pattern {
    words: usize,
    /// Byte to its row in `eq`, `NO_ROW` for a byte no atom has.
    row: [u8; 128],
    /// In one allocation: the atoms that repeat (`words` words: state `i`
    /// also holds state `i + 1`), the set before any byte is read (`words`
    /// words), and per distinct byte the atoms with that byte (`words` words
    /// each, in the order of `row`).
    data: Vec<u64>,
    /// The state that accepts.
    accept: usize,
}

const NO_ROW: u8 = u8::MAX;

impl Pattern {
    fn new(atoms: &[Atom]) -> Pattern {
        let m = atoms.len();
        let words = m / 64 + 1;
        let mut row = [NO_ROW; 128];
        let mut data = vec![0u64; 2 * words];
        for (i, a) in atoms.iter().enumerate() {
            let bit = 1u64 << (i % 64);
            if a.star {
                if let Some(w) = data.get_mut(i / 64) {
                    *w |= bit;
                }
            }
            let Some(r) = row.get_mut(usize::from(a.byte)) else {
                continue;
            };
            if *r == NO_ROW {
                *r = u8::try_from((data.len() - 2 * words) / words).unwrap_or(NO_ROW);
                data.resize(data.len() + words, 0);
            }
            let at = 2 * words + usize::from(*r) * words + i / 64;
            if let Some(w) = data.get_mut(at) {
                *w |= bit;
            }
        }
        if let Some(w) = data.get_mut(words) {
            *w = 1;
        }
        let mut p = Pattern {
            words,
            row,
            data,
            accept: m,
        };
        let mut start = p.start().to_vec();
        p.close(&mut start);
        if let Some(dst) = p.data.get_mut(words..2 * words) {
            dst.copy_from_slice(&start);
        }
        p
    }

    fn star(&self) -> &[u64] {
        self.data.get(..self.words).unwrap_or_default()
    }

    fn start(&self) -> &[u64] {
        self.data
            .get(self.words..2 * self.words)
            .unwrap_or_default()
    }

    /// Adds to `set` every state that a state holding a repeating atom
    /// reaches without reading a byte: the run of repeating atoms above it.
    /// Adding the repeating states of the set to the repeating atoms carries
    /// through each run of ones to the state after it.
    fn close(&self, set: &mut [u64]) {
        let mut carry = false;
        for (w, &star) in set.iter_mut().zip(self.star()) {
            let a = *w & star;
            let (sum, c1) = star.overflowing_add(a);
            let (sum, c2) = sum.overflowing_add(u64::from(carry));
            carry = c1 || c2;
            *w |= sum ^ star;
        }
    }

    /// The set after reading `b` in `from`, written to `to`; whether it holds
    /// any state.
    fn step(&self, from: &[u64], b: u8, to: &mut [u64]) -> bool {
        let r = match self.row.get(usize::from(b)) {
            Some(&r) if r != NO_ROW => usize::from(r),
            _ => return false,
        };
        let from_at = 2 * self.words + r * self.words;
        let Some(eq) = self.data.get(from_at..from_at + self.words) else {
            return false;
        };
        let mut carry = 0u64;
        let mut any = 0u64;
        for (((t, &f), &e), &st) in to.iter_mut().zip(from).zip(eq).zip(self.star()) {
            let hit = f & e;
            *t = (hit & st) | ((hit & !st) << 1) | carry;
            carry = (hit & !st) >> 63;
            any |= *t;
        }
        if any == 0 {
            return false;
        }
        self.close(to);
        true
    }

    fn accepts(&self, set: &[u64]) -> bool {
        set.get(self.accept / 64)
            .is_some_and(|w| (w >> (self.accept % 64)) & 1 == 1)
    }
}

/// The buffers of the walk over a trie, kept between patterns so that a text
/// of many names does not allocate for each.
#[derive(Default)]
struct Walk {
    /// The places in the key list of the keys the last pattern matched.
    found: Vec<usize>,
    /// The state sets of the walk, `words` words each: one for every node of
    /// the path being walked that has children, then two that the steps
    /// along an edge alternate between.
    sets: Vec<u64>,
    /// The nodes of that path and, for each, the next child to try.
    stack: Vec<(usize, usize)>,
}

const NONE: usize = usize::MAX;

/// One node of the trie. The edge into it is a range of one of the keys, so
/// the nodes hold no bytes of their own.
#[derive(Clone, Copy)]
struct TrieNode {
    /// The edge into the node is `keys[key][lo..hi]`: a key that passes
    /// through the node, and the part of it between the parent and the node.
    key: usize,
    lo: usize,
    hi: usize,
    /// The first of the children (`NONE` for a leaf).
    first: usize,
    /// The place in the key list plus one of the key that ends here, 0 if none.
    term: usize,
}

/// The distinct `w` of a segment as a path-compressed trie: a node for the
/// root, for every key that ends, and for every point where two keys part,
/// and nothing else, so the trie has at most twice as many nodes as there are
/// keys whatever their length, and each edge is a range of a key that the
/// segment already holds. Node 0 is the root (the empty key is its `term`).
///
/// A walk that goes along an edge keeps one state set, not one for every
/// byte: the sets of the path it is on are one per node, which is at most one
/// per key that ends or part of two keys on the way (at most the square root
/// of twice the bytes of the keys), not one per byte of the longest key.
///
/// The children of a node are a list through `next`, and the first byte of
/// each one's edge is in `lead`. A walk that looks through the children of a
/// node for the ones the pattern can take reads only those two arrays, one
/// byte and one index per child, and reads the node (and the keys) of the
/// ones it takes.
struct Trie {
    nodes: Vec<TrieNode>,
    /// The first byte of the edge into each node (0 for the root).
    lead: Vec<u8>,
    /// The next of the siblings of each node, `NONE` at the end of the list.
    next: Vec<usize>,
}

impl Trie {
    /// Adds a node and returns its number.
    fn push(&mut self, node: TrieNode, lead: u8, next: usize) -> usize {
        self.nodes.push(node);
        self.lead.push(lead);
        self.next.push(next);
        self.nodes.len() - 1
    }

    /// Inserts the keys one after the other. A key follows the edges of the
    /// trie as far as they agree with it, and then either ends there (inside
    /// an edge, which is split in two), or ends in a leaf of its own, or
    /// leaves the edge at a byte where it differs, which splits the edge and
    /// hangs a leaf beside the lower part. A key is read once, and the
    /// children of a node are looked through only for their first byte, so
    /// the time is the bytes of the keys times the largest number of siblings
    /// (53 for the bytes a name can hold).
    fn new(keys: &[&[u8]]) -> Trie {
        let root = TrieNode {
            key: 0,
            lo: 0,
            hi: 0,
            first: NONE,
            term: 0,
        };
        let mut t = Trie {
            nodes: vec![root],
            lead: vec![0],
            next: vec![NONE],
        };
        for (id, key) in keys.iter().enumerate() {
            let key: &[u8] = key;
            // the node reached, and the bytes of the key read to get there
            let mut v = 0;
            let mut pos = 0;
            loop {
                let Some(&b) = key.get(pos) else {
                    if let Some(n) = t.nodes.get_mut(v) {
                        n.term = id + 1;
                    }
                    break;
                };
                let first = t.nodes.get(v).map_or(NONE, |n| n.first);
                let mut c = first;
                while c != NONE && t.lead.get(c) != Some(&b) {
                    c = t.next.get(c).copied().unwrap_or(NONE);
                }
                let Some(&child) = t.nodes.get(c) else {
                    // nothing starts with this byte: a leaf takes the rest of the key
                    let leaf = TrieNode {
                        key: id,
                        lo: pos,
                        hi: key.len(),
                        first: NONE,
                        term: id + 1,
                    };
                    let leaf = t.push(leaf, b, first);
                    if let Some(n) = t.nodes.get_mut(v) {
                        n.first = leaf;
                    }
                    break;
                };
                let label = keys
                    .get(child.key)
                    .and_then(|k| k.get(child.lo..child.hi))
                    .unwrap_or_default();
                let rest = key.get(pos..).unwrap_or_default();
                let same = label.iter().zip(rest).take_while(|(x, y)| x == y).count();
                if same == label.len() {
                    v = c;
                    pos += same;
                    continue;
                }
                // split the edge of `c` at `same`: `c` keeps the upper part, and
                // its old subtree moves to a node for the lower part
                let cut = child.lo + same;
                let lower = TrieNode {
                    key: child.key,
                    lo: cut,
                    hi: child.hi,
                    first: child.first,
                    term: child.term,
                };
                let lower = t.push(lower, label.get(same).copied().unwrap_or(0), NONE);
                if let Some(n) = t.nodes.get_mut(c) {
                    n.hi = cut;
                    n.first = lower;
                    n.term = 0;
                }
                pos += same;
                match key.get(pos) {
                    // the key ends where the edge was cut
                    None => {
                        if let Some(n) = t.nodes.get_mut(c) {
                            n.term = id + 1;
                        }
                    }
                    // it goes its own way from there
                    Some(&b) => {
                        let leaf = TrieNode {
                            key: id,
                            lo: pos,
                            hi: key.len(),
                            first: NONE,
                            term: id + 1,
                        };
                        let leaf = t.push(leaf, b, lower);
                        if let Some(n) = t.nodes.get_mut(c) {
                            n.first = leaf;
                        }
                    }
                }
                break;
            }
        }
        t
    }

    /// Finds the keys the pattern matches and leaves their places in the key
    /// list in `walk.found`, in no particular order. A depth-first walk that
    /// carries the pattern's state set and follows an edge only while the set
    /// is not empty, so it visits the part of the trie the pattern can reach
    /// and nothing else. An explicit stack: a path can have as many nodes as
    /// the keys have.
    ///
    /// Along an edge the walk alternates between two sets, and it keeps one
    /// set for every node of the path that has children, so the sets are
    /// `words` times the nodes on the path plus two, not `words` times the
    /// bytes of the longest key. Every byte the walk steps over costs `words`
    /// units of `budget`, the words of the set it computes, so the time is
    /// bounded by the budget, and the sets by `set_cap` words. The walk stops
    /// when the budget cannot pay for the next byte or the sets would pass
    /// the cap, and returns `false` with the budget at zero; `walk.found` is
    /// then incomplete and must not be used.
    fn matching(
        &self,
        keys: &[&[u8]],
        p: &Pattern,
        walk: &mut Walk,
        budget: &mut usize,
        set_cap: usize,
    ) -> bool {
        let words = p.words;
        let Walk { found, sets, stack } = walk;
        found.clear();
        sets.clear();
        stack.clear();
        let Some(root) = self.nodes.first() else {
            return true;
        };
        if root.term != 0 && p.accepts(p.start()) {
            found.push(root.term - 1);
        }
        if words.saturating_mul(3) > set_cap {
            *budget = 0;
            return false;
        }
        // the root's set, then the two the steps alternate between
        sets.extend_from_slice(p.start());
        sets.resize(3 * words, 0);
        stack.push((0, root.first));
        loop {
            let depth = stack.len();
            let Some(top) = stack.last_mut() else { break };
            // frames 0..depth are the saved sets; the two after them are the scratch
            let (head, tail) = sets.split_at_mut(depth * words);
            let (a, b) = tail.split_at_mut(words);
            let Some(from) = head.get((depth - 1) * words..) else {
                return false;
            };
            // The next child of the node whose first byte the pattern takes;
            // the others are dismissed from the two small arrays alone.
            let mut c = top.1;
            while let Some(&lead) = self.lead.get(c) {
                match budget.checked_sub(words) {
                    Some(rest) => *budget = rest,
                    None => {
                        *budget = 0;
                        return false;
                    }
                }
                if p.step(from, lead, a) {
                    break;
                }
                c = self.next.get(c).copied().unwrap_or(NONE);
            }
            let Some(&child) = self.nodes.get(c) else {
                stack.pop();
                sets.truncate((stack.len() + 2) * words);
                continue;
            };
            top.1 = self.next.get(c).copied().unwrap_or(NONE);
            // the set after the bytes read so far is in `a` or in `b`
            let mut in_a = true;
            if child.hi > child.lo + 1 {
                let rest = keys
                    .get(child.key)
                    .and_then(|k| k.get(child.lo + 1..child.hi))
                    .unwrap_or_default();
                let mut alive = true;
                for &byte in rest {
                    match budget.checked_sub(words) {
                        Some(left) => *budget = left,
                        None => {
                            *budget = 0;
                            return false;
                        }
                    }
                    alive = if in_a {
                        p.step(a, byte, b)
                    } else {
                        p.step(b, byte, a)
                    };
                    if !alive {
                        break;
                    }
                    in_a = !in_a;
                }
                if !alive {
                    continue;
                }
            }
            let set: &[u64] = if in_a { a } else { b };
            if child.term != 0 && p.accepts(set) {
                found.push(child.term - 1);
            }
            if child.first == NONE {
                continue;
            }
            // the node has children: its set joins the saved ones, in the place of `a`
            if words.saturating_mul(depth + 3) > set_cap {
                *budget = 0;
                return false;
            }
            if !in_a {
                a.copy_from_slice(b);
            }
            stack.push((c, child.first));
            sets.resize((stack.len() + 2) * words, 0);
        }
        true
    }
}

/// Every consecutive pair of newlines `(p, q)` of `s` with only a quote
/// prefix between them, ascending.
fn build_b1(s: &[u8]) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut p = match s.iter().position(|&c| c == b'\n') {
        Some(p) => p,
        None => return out,
    };
    while let Some(off) = s
        .get(p + 1..)
        .and_then(|r| r.iter().position(|&c| c == b'\n'))
    {
        let q = p + 1 + off;
        if quote_blank(sub(s, p + 1, q), false) {
            out.push((p, q));
        }
        p = q;
    }
    out
}

/// Every `p` with `\n\n` at `p`, ascending.
fn build_nn(s: &[u8]) -> Vec<usize> {
    s.windows(2)
        .enumerate()
        .filter(|(_, w)| matches!(w, [b'\n', b'\n']))
        .map(|(p, _)| p)
        .collect()
}

/// The start positions of the maximal backtick runs of `s`, by length,
/// ascending.
fn build_runs(s: &[u8]) -> Map<usize, Vec<usize>> {
    let mut runs: Map<usize, Vec<usize>> = new_map(s);
    let mut i = 0;
    while let Some(off) = s.get(i..).and_then(|r| r.iter().position(|&c| c == b'`')) {
        let start = i + off;
        let mut end = start;
        while at(s, end) == b'`' {
            end += 1;
        }
        runs.entry(end - start).or_default().push(start);
        i = end;
    }
    runs
}

/// The first `\\)` (or `\\]`, per `close`) at or after `from`.
fn search_doubled(s: &[u8], from: usize, close: u8) -> Option<usize> {
    s.get(from..)?
        .windows(3)
        .position(|w| matches!(w, [b'\\', b'\\', c] if *c == close))
        .map(|p| p + from)
}

/// The `\)` or `\]` that closes a `\(` or `\[` whose body starts at `from`:
/// a backslash skips the byte after it, and a blank line ends the search.
/// `Err` is the position where the walk gave up: the `\n\n`, or the end.
fn walk_paren(s: &[u8], from: usize, close: u8) -> Result<usize, usize> {
    let mut j = from;
    while j < s.len() {
        let c = at(s, j);
        if c == b'\n' && at(s, j + 1) == b'\n' {
            return Err(j);
        }
        if c == b'\\' {
            if at(s, j + 1) == close {
                return Ok(j);
            }
            j += 2;
            continue;
        }
        j += 1;
    }
    Err(s.len())
}

/// The indexes and memos of one text segment, each built on first use.
pub(crate) struct SegIndex<'a> {
    s: &'a [u8],
    b1: Option<Vec<(usize, usize)>>,
    b1_hint: usize,
    nn: Option<Vec<usize>>,
    nn_hint: usize,
    runs: Option<Map<usize, Vec<usize>>>,
    envs: Option<EnvIndex<'a>>,
    /// Per closing character (`)`, `]`): where the last search for the
    /// doubled close started and what it found.
    dbl: [Option<(usize, Option<usize>)>; 2],
    /// Per closing character: the start and end of the last failed
    /// `\(` / `\[` walk, as `(k, end)`; `(0, 0)` while none failed.
    paren_fail: [(usize, usize); 2],
}

impl<'a> SegIndex<'a> {
    pub(crate) fn new(s: &'a [u8]) -> SegIndex<'a> {
        SegIndex {
            s,
            b1: None,
            b1_hint: 0,
            nn: None,
            nn_hint: 0,
            runs: None,
            envs: None,
            dbl: [None; 2],
            paren_fail: [(0, 0); 2],
        }
    }

    /// `/\n[ \t]*(?:>[ \t]?)*\n/.test(s.slice(from, to))`: a blank line,
    /// modulo quote markers, wholly inside the range.
    ///
    /// The regex needs two newlines `p < q` in the range with only
    /// `[ \t]*(?:>[ \t]?)*` between them. Nothing between them is a newline,
    /// so they are consecutive newlines of the text: the pairs of `b1`.
    /// Such a pair lies inside the range when `p >= from` and `q < to`; `q`
    /// grows with `p`, so the first pair with `p >= from` has the smallest
    /// `q` of those, and the range holds a pair exactly when that one fits.
    pub(crate) fn has_b1(&mut self, from: usize, to: usize) -> bool {
        let s = self.s;
        let pairs = self.b1.get_or_insert_with(|| build_b1(s));
        let i = lower_bound(pairs, &mut self.b1_hint, |&(p, _)| p < from);
        pairs.get(i).is_some_and(|&(_, q)| q < to)
    }

    /// The first `p >= r` with `\n\n` at `p`.
    fn nn_after(&mut self, r: usize) -> Option<usize> {
        let s = self.s;
        let nn = self.nn.get_or_insert_with(|| build_nn(s));
        nn.get(lower_bound(nn, &mut self.nn_hint, |&p| p < r))
            .copied()
    }

    /// The first closing run of exactly `len` backticks at or after `r`; a
    /// longer or shorter run is skipped whole, and a blank line ends the
    /// search. `r` is the end of a backtick run (`s[r]` is not a backtick).
    ///
    /// The reference walk starts at `r`, where no backtick precedes, and
    /// steps one byte at a time over everything but a backtick run, which it
    /// jumps whole. So every backtick it visits starts a maximal run, and it
    /// visits the starts of all maximal runs from `r` on, in order, plus every
    /// other byte (so it sees the first `\n\n` at `p >= r` if it gets there).
    /// It returns the first start with the right length that comes before
    /// `p`, if any: the first entry `>= r` of `runs[len]`, taken when it is
    /// below `nn_after(r)`.
    pub(crate) fn backtick_close(&mut self, r: usize, len: usize) -> Option<usize> {
        let s = self.s;
        let runs = self.runs.get_or_insert_with(|| build_runs(s));
        let starts = runs.get(&len)?;
        let st = *starts.get(starts.partition_point(|&p| p < r))?;
        match self.nn_after(r) {
            Some(p) if st >= p => None,
            _ => Some(st),
        }
    }

    /// The first `\\)` (or `\\]`, per `close`) at or after `from`.
    ///
    /// Memo of the last search `(searched_from, result)`. A later search from
    /// `from >= searched_from` can reuse it: when the earlier search found
    /// nothing, there is no occurrence at or after `searched_from`, so none
    /// at or after `from`; when it found `e >= from`, there is none in
    /// `[searched_from, e)`, so `e` is also the first at or after `from`.
    /// Otherwise (`e < from`, or an earlier `from`) the search runs again and
    /// replaces the memo. The scan position only grows, so the ranges
    /// searched do not overlap beyond the occurrence they end on.
    pub(crate) fn find_doubled_close(&mut self, from: usize, close: u8) -> Option<usize> {
        let sl = slot(close);
        if let Some((searched, result)) = self.dbl[sl] {
            if searched <= from && result.is_none_or(|e| e >= from) {
                return result;
            }
        }
        let result = search_doubled(self.s, from, close);
        self.dbl[sl] = Some((from, result));
        result
    }

    /// The `\)` or `\]` that closes the `\(` or `\[` at `k` (a backslash and
    /// an opening character); the walk starts at `k + 2`.
    ///
    /// After a failed walk from `k0` that ended at `e` (a `\n\n` at `e`, or
    /// the end of the segment), the walk from any later `\(` at `k` with
    /// `k0 < k < e` fails too. The walk steps one byte, or two after a
    /// backslash, and only a byte right after a backslash is skipped. The
    /// byte at `k + 1` is the opening character, not a backslash, so `k + 2`
    /// is not skipped: it is a position the earlier walk visited, or `e`
    /// itself (`k + 1 != e`, because the byte at `e` is a newline or the end
    /// and the byte at `k + 1` is `(` or `[`). From a visited position the
    /// walk is the same as the earlier one's rest, which failed at `e`. So
    /// such a `k` fails at once. `k0 < k` holds for every later question, and
    /// the memo checks it anyway.
    pub(crate) fn walk_paren(&mut self, k: usize, close: u8) -> Option<usize> {
        let sl = slot(close);
        let (k0, e) = self.paren_fail[sl];
        if k0 < k && k < e {
            return None;
        }
        match walk_paren(self.s, k + 2, close) {
            Ok(found) => Some(found),
            Err(end) => {
                self.paren_fail[sl] = (k, end);
                None
            }
        }
    }

    /// The end of the `\end{name}` that closes the `\begin{name}` at `k`, by
    /// the environment index (see [`EnvIndex::end`]).
    pub(crate) fn env_end(&mut self, k: usize, name: &'a [u8]) -> Option<usize> {
        let s = self.s;
        self.envs
            .get_or_insert_with(|| EnvIndex::build(s))
            .end(k, name)
    }
}

#[cfg(test)]
mod tests {
    //! Each index against the walk it replaces, on random text: the walks
    //! are the reference's own loops, kept here as they were before the
    //! indexes existed. Questions are asked the way a scan asks them (growing
    //! positions) and also out of order, so the memos and cursors are checked
    //! in both.

    use super::*;

    fn find_byte(s: &[u8], needle: u8, from: usize, to: usize) -> Option<usize> {
        sub(s, from, to.min(s.len()))
            .iter()
            .position(|&c| c == needle)
            .map(|p| p + from)
    }

    fn has_b1_walk(s: &[u8], from: usize, to: usize) -> bool {
        let to = to.min(s.len());
        let Some(mut p) = find_byte(s, b'\n', from, to) else {
            return false;
        };
        while let Some(q) = find_byte(s, b'\n', p + 1, to) {
            if quote_blank(sub(s, p + 1, q), false) {
                return true;
            }
            p = q;
        }
        false
    }

    fn find_doubled_close_walk(s: &[u8], from: usize, close: u8) -> Option<usize> {
        let mut i = from;
        while i + 2 < s.len() {
            if at(s, i) == b'\\' && at(s, i + 1) == b'\\' && at(s, i + 2) == close {
                return Some(i);
            }
            i += 1;
        }
        None
    }

    fn walk_paren_walk(s: &[u8], from: usize, close: u8) -> Option<usize> {
        let mut j = from;
        while j < s.len() {
            let c = at(s, j);
            if c == b'\n' && at(s, j + 1) == b'\n' {
                return None;
            }
            if c == b'\\' {
                if at(s, j + 1) == close {
                    return Some(j);
                }
                j += 2;
                continue;
            }
            j += 1;
        }
        None
    }

    fn env_end_walk(s: &[u8], k: usize, name: &[u8]) -> Option<usize> {
        let atoms = env_atoms(name)?;
        let mut depth: i64 = 0;
        let mut i = k;
        while let Some(p) = find_byte(s, b'\\', i, s.len()) {
            let (begin, open) = if sub(s, p, p + 7) == b"\\begin{" {
                (true, p + 7)
            } else if sub(s, p, p + 5) == b"\\end{" {
                (false, p + 5)
            } else {
                i = p + 1;
                continue;
            };
            let mut q = open;
            while at(s, q).is_ascii_alphabetic() || at(s, q) == b'*' {
                q += 1;
            }
            if at(s, q) == b'}' && atoms_match(&atoms, sub(s, open, q)) {
                if begin {
                    depth += 1;
                } else {
                    depth -= 1;
                    if depth == 0 {
                        return Some(q + 1);
                    }
                }
                i = q + 1;
            } else {
                i = p + 1;
            }
        }
        None
    }

    fn backtick_close_walk(s: &[u8], from: usize, run: usize) -> Option<usize> {
        let mut j = from;
        while j < s.len() {
            let c = at(s, j);
            if c == b'`' {
                let mut e = j;
                while at(s, e) == b'`' {
                    e += 1;
                }
                if e - j == run {
                    return Some(j);
                }
                j = e;
                continue;
            }
            if c == b'\n' && at(s, j + 1) == b'\n' {
                return None;
            }
            j += 1;
        }
        None
    }

    const PIECES: [&str; 47] = [
        "\\",
        "\\",
        "(",
        ")",
        "[",
        "]",
        "\n",
        "\n",
        "\n\n",
        " ",
        "\t",
        ">",
        "a",
        "b",
        "`",
        "``",
        "```",
        "$",
        "*",
        "{",
        "}",
        "\\(",
        "\\)",
        "\\[",
        "\\]",
        "\\\\(",
        "\\\\)",
        "\\begin{a}",
        "\\end{a}",
        "\\begin{b}",
        "\\end{b}",
        "\\begin{a*}",
        "\\end{a*}",
        "\\begin{ab**}",
        "\\end{a*b}",
        "\\begin{*}",
        "\\end{}",
        "\\begin{a",
        "\\end{**}",
        "\\begin{a*b*}",
        "\\end{a*b*}",
        "\\begin{*a*}",
        "\\end{*a*}",
        "\\begin{a**b*}",
        "\\end{a*b**}",
        "\\begin{a*b}",
        "\\begin{ab*}",
    ];

    /// Names asked about, valid and not, literal and starred.
    const NAMES: [&[u8]; 18] = [
        b"a", b"b", b"a*", b"*", b"ab**", b"a*b*", b"**", b"a***", b"*a*", b"ab", b"a**", b"b*",
        b"a*b**", b"a**b*", b"*a**", b"b**", b"a*b", b"ab*",
    ];

    fn xorshift(state: &mut u64) -> u64 {
        let mut x = *state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        *state = x;
        x
    }

    fn random_text(state: &mut u64) -> String {
        let n = (xorshift(state) % 60) as usize;
        let mut s = String::new();
        for _ in 0..n {
            s.push_str(PIECES[(xorshift(state) % PIECES.len() as u64) as usize]);
        }
        s
    }

    /// Runs `check` on `rounds` random texts, collecting what it reports.
    fn each_text(seed: u64, rounds: usize, check: impl Fn(&str, &mut u64) -> Vec<String>) {
        let mut state = seed;
        let mut bad = Vec::new();
        for _ in 0..rounds {
            let text = random_text(&mut state);
            for why in check(&text, &mut state) {
                bad.push(format!("{why} in {text:?}"));
            }
        }
        assert!(
            bad.is_empty(),
            "{} mismatches\n{}",
            bad.len(),
            bad.iter().take(5).cloned().collect::<Vec<_>>().join("\n")
        );
    }

    #[test]
    fn blank_line_index_matches_the_walk() {
        each_text(1, 20_000, |text, rng| {
            let s = text.as_bytes();
            let mut ix = SegIndex::new(s);
            let mut bad = Vec::new();
            // growing positions
            let mut from = 0;
            while from <= s.len() + 1 {
                let to = from + (xorshift(rng) % 12) as usize;
                if ix.has_b1(from, to) != has_b1_walk(s, from, to) {
                    bad.push(format!("has_b1({from}, {to}) in order"));
                }
                from += 1 + (xorshift(rng) % 3) as usize;
            }
            // any order
            for _ in 0..30 {
                let from = (xorshift(rng) % (s.len() as u64 + 2)) as usize;
                let to = from + (xorshift(rng) % (s.len() as u64 + 2)) as usize;
                if ix.has_b1(from, to) != has_b1_walk(s, from, to) {
                    bad.push(format!("has_b1({from}, {to}) out of order"));
                }
            }
            bad
        });
    }

    #[test]
    fn doubled_close_memo_matches_the_walk() {
        each_text(2, 20_000, |text, rng| {
            let s = text.as_bytes();
            let mut ix = SegIndex::new(s);
            let mut bad = Vec::new();
            for from in 0..=s.len() + 1 {
                for close in [b')', b']'] {
                    if ix.find_doubled_close(from, close) != find_doubled_close_walk(s, from, close)
                    {
                        bad.push(format!(
                            "find_doubled_close({from}, {}) in order",
                            close as char
                        ));
                    }
                }
            }
            for _ in 0..30 {
                let from = (xorshift(rng) % (s.len() as u64 + 2)) as usize;
                let close = if xorshift(rng) & 1 == 0 { b')' } else { b']' };
                if ix.find_doubled_close(from, close) != find_doubled_close_walk(s, from, close) {
                    bad.push(format!(
                        "find_doubled_close({from}, {}) out of order",
                        close as char
                    ));
                }
            }
            bad
        });
    }

    #[test]
    fn paren_failure_memo_matches_the_walk() {
        each_text(3, 20_000, |text, rng| {
            let s = text.as_bytes();
            let mut bad = Vec::new();
            // every `\(` and `\[`, both kinds interleaved
            let mut starts: Vec<(usize, u8)> = Vec::new();
            for k in 0..s.len() {
                if at(s, k) != b'\\' {
                    continue;
                }
                match at(s, k + 1) {
                    b'(' => starts.push((k, b')')),
                    b'[' => starts.push((k, b']')),
                    _ => {}
                }
            }
            // in order, as the scan asks, then backwards, then shuffled
            for round in 0..3 {
                match round {
                    1 => starts.reverse(),
                    2 => {
                        for i in (1..starts.len()).rev() {
                            starts.swap(i, (xorshift(rng) % (i as u64 + 1)) as usize);
                        }
                    }
                    _ => {}
                }
                let mut ix = SegIndex::new(s);
                for &(k, close) in &starts {
                    if ix.walk_paren(k, close) != walk_paren_walk(s, k + 2, close) {
                        bad.push(format!("walk_paren({k}, {}) round {round}", close as char));
                    }
                }
            }
            bad
        });
    }

    #[test]
    fn backtick_index_matches_the_walk() {
        each_text(4, 20_000, |text, rng| {
            let s = text.as_bytes();
            let mut ix = SegIndex::new(s);
            let mut bad = Vec::new();
            // every end of a run (the byte there is not a backtick), every length
            for r in 0..=s.len() {
                if at(s, r) == b'`' {
                    continue;
                }
                for run in 1..=4 {
                    if ix.backtick_close(r, run) != backtick_close_walk(s, r, run) {
                        bad.push(format!("backtick_close({r}, {run})"));
                    }
                }
            }
            for _ in 0..20 {
                let r = (xorshift(rng) % (s.len() as u64 + 1)) as usize;
                if at(s, r) == b'`' {
                    continue;
                }
                let run = 1 + (xorshift(rng) % 4) as usize;
                if ix.backtick_close(r, run) != backtick_close_walk(s, r, run) {
                    bad.push(format!("backtick_close({r}, {run}) out of order"));
                }
            }
            bad
        });
    }

    #[test]
    fn environment_index_matches_the_walk() {
        each_text(5, 20_000, |text, rng| {
            let s = text.as_bytes();
            let mut ix = SegIndex::new(s);
            let mut bad = Vec::new();
            let mut ks: Vec<usize> = (0..s.len())
                .filter(|&k| sub(s, k, k + 7) == b"\\begin{")
                .collect();
            // in order, then shuffled
            for round in 0..2 {
                if round == 1 {
                    for i in (1..ks.len()).rev() {
                        ks.swap(i, (xorshift(rng) % (i as u64 + 1)) as usize);
                    }
                }
                for &k in &ks {
                    for name in NAMES {
                        if ix.env_end(k, name) != env_end_walk(s, k, name) {
                            bad.push(format!(
                                "env_end({k}, {:?}) round {round}",
                                String::from_utf8_lossy(name)
                            ));
                        }
                    }
                }
            }
            // a position that is not a begin at all
            for _ in 0..10 {
                let k = (xorshift(rng) % (s.len() as u64 + 2)) as usize;
                for name in NAMES {
                    if ix.env_end(k, name) != env_end_walk(s, k, name) {
                        bad.push(format!(
                            "env_end({k}, {:?}) anywhere",
                            String::from_utf8_lossy(name)
                        ));
                    }
                }
            }
            bad
        });
    }

    /// A random byte string over `alphabet`, `0..=max_len` long.
    fn random_word(state: &mut u64, alphabet: &[u8], max_len: usize) -> Vec<u8> {
        let n = (xorshift(state) % (max_len as u64 + 1)) as usize;
        (0..n)
            .map(|_| alphabet[(xorshift(state) % alphabet.len() as u64) as usize])
            .collect()
    }

    /// A random word the pattern matches: every atom once, a repeating atom
    /// zero to three times.
    fn expansion(state: &mut u64, atoms: &[Atom]) -> Vec<u8> {
        let mut w = Vec::new();
        for a in atoms {
            let times = if a.star { xorshift(state) % 4 } else { 1 };
            for _ in 0..times {
                w.push(a.byte);
            }
        }
        w
    }

    /// The trie walk finds exactly the keys the plain automaton accepts, for
    /// short and long patterns (past 64 atoms: several words per set, runs of
    /// repeating atoms across a word boundary) and for keys that do and do not
    /// match.
    #[test]
    fn trie_walk_matches_the_plain_automaton() {
        let mut state = 0x1234_5678_9abc_def1u64;
        let mut checked = 0usize;
        let mut accepted = 0usize;
        for round in 0..3000 {
            // pattern names: a small alphabet so that matches are common; every
            // third round a long name (up to 200 bytes)
            let long = round % 3 == 0;
            let alphabet: &[u8] = if round % 2 == 0 { b"ab*" } else { b"abc***" };
            let name = random_word(&mut state, alphabet, if long { 200 } else { 12 });
            let Some(atoms) = env_atoms(&name) else {
                continue;
            };
            let mut keys: Vec<Vec<u8>> = (0..40)
                .map(|_| random_word(&mut state, b"abc*", if long { 90 } else { 8 }))
                .collect();
            for _ in 0..40 {
                keys.push(expansion(&mut state, &atoms));
            }
            keys.sort();
            keys.dedup();
            let refs: Vec<&[u8]> = keys.iter().map(Vec::as_slice).collect();
            let trie = Trie::new(&refs);
            let mut walk = Walk::default();
            let mut budget = usize::MAX;
            assert!(trie.matching(
                &refs,
                &Pattern::new(&atoms),
                &mut walk,
                &mut budget,
                usize::MAX
            ));
            let mut got = walk.found;
            got.sort_unstable();
            let want: Vec<usize> = (0..refs.len())
                .filter(|&i| atoms_match(&atoms, refs[i]))
                .collect();
            checked += 1;
            accepted += want.len();
            assert_eq!(
                got,
                want,
                "pattern {:?} over {} keys",
                String::from_utf8_lossy(&name),
                refs.len()
            );
        }
        // the test must reach both outcomes
        assert!(checked > 1000 && accepted > 5000, "{checked} {accepted}");
    }

    /// The empty key and the empty pattern, and keys that are prefixes of one another.
    #[test]
    fn trie_walk_edges() {
        let keys: [&[u8]; 5] = [b"", b"a", b"a*", b"a**", b"*"];
        let trie = Trie::new(&keys);
        let run = |name: &[u8]| {
            let mut walk = Walk::default();
            let mut budget = usize::MAX;
            assert!(trie.matching(
                &keys,
                &Pattern::new(&env_atoms(name).unwrap_or_default()),
                &mut walk,
                &mut budget,
                usize::MAX,
            ));
            let mut v = walk.found;
            v.sort_unstable();
            v
        };
        // `a\**` matches `a`, `a*` and `a**`
        assert_eq!(run(b"a**"), [1, 2, 3]);
        // `\**` (a literal star, repeated) matches the empty key, `*`
        assert_eq!(run(b"**"), [0, 4]);
        // no atoms: the empty key only
        assert_eq!(run(b""), [0]);
        // a byte no key holds
        assert_eq!(run(b"z*z*"), Vec::<usize>::new());
    }

    /// Names whose patterns match the same keys share one merged group, a
    /// pattern that matches one key uses that key's group, and every answer is
    /// the walk's.
    #[test]
    fn equal_matches_share_a_group() {
        // keys `a*`, `a**`, `a**x*` and `a*b*`; `a\**` and `a\**x*` both match
        // exactly `a*` and `a**`, and `a\*b*` matches `a*` alone
        let text = b"\\begin{a*}p\\end{a*}\\begin{a**}q\\end{a**}\\begin{a**x*}r\\begin{a*b*}s";
        let mut ix = SegIndex::new(text);
        let begins: Vec<usize> = (0..text.len())
            .filter(|&k| sub(text, k, k + 7) == b"\\begin{")
            .collect();
        for &k in &begins {
            for name in [&b"a**"[..], b"a**x*", b"a*", b"a*b*", b"a**", b"zz*z*"] {
                assert_eq!(
                    ix.env_end(k, name),
                    env_end_walk(text, k, name),
                    "{k} {name:?}"
                );
            }
        }
        let envs = ix.envs.as_ref().expect("the environment index was built");
        assert_eq!(envs.merged.len(), 1, "one group for the two names");
        // `a**`, `a**x*`, `a*b*` and `zz*z*`; `a*` is a literal and not looked up as a pattern
        assert_eq!(envs.by_pattern.len(), 4);
    }

    /// The names of a text, then the keys they match, as the scan would ask
    /// about them: `\begin{name}` for every name (distinct, each `x*` and
    /// eight starred letters, so each matches many keys), then
    /// `\begin{x*w}\end{x*w}` for every word `w` over `abc` of up to five
    /// letters (364 keys, each of which every name matches or not by its
    /// letters). Returns the text, the names and the position of each name's
    /// `\begin`.
    fn names_then_keys() -> (String, Vec<String>, Vec<usize>) {
        let mut text = String::new();
        let mut names: Vec<String> = Vec::new();
        let mut begins = Vec::new();
        for i in 0..3usize.pow(8) {
            let mut name = String::from("x*");
            let mut v = i;
            for _ in 0..8 {
                name.push_str(["a", "b", "c"][v % 3]);
                name.push('*');
                v /= 3;
            }
            begins.push(text.len());
            text.push_str(&format!("\\begin{{{name}}} "));
            names.push(name);
        }
        let mut level = vec![String::new()];
        for _ in 0..=5 {
            for t in &level {
                text.push_str(&format!("\\begin{{x*{t}}} \\end{{x*{t}}} "));
            }
            level = level
                .iter()
                .flat_map(|t| ["a", "b", "c"].map(|c| format!("{t}{c}")))
                .collect();
        }
        (text, names, begins)
    }

    /// A text of many distinct names that each match many of the others holds
    /// no more than a constant times its occurrences in merged groups: the
    /// work budget is spent when the groups pass the bound, and from then on
    /// no name that was not answered before gets an answer, while every name
    /// that was keeps its own, whatever else is asked.
    #[test]
    fn merged_groups_stay_bounded() {
        let (text, names, begins) = names_then_keys();
        let s = text.as_bytes();
        let mut ix = SegIndex::new(s);
        let mut answers: Vec<Option<usize>> = Vec::new();
        let mut spent_at = None;
        let mut bound = 0;
        let mut biggest = 0;
        let mut deviating = 0;
        for (j, (&k, name)) in begins.iter().zip(&names).enumerate() {
            let name = name.as_bytes();
            let got = ix.env_end(k, name);
            answers.push(got);
            let e = ix.envs.as_ref().expect("built");
            bound = 2 * e.total_events + 4096;
            biggest = biggest.max(e.retained);
            if spent_at.is_none() {
                // while the budget lasts the answer is the walk's
                assert_eq!(got, env_end_walk(s, k, name), "name {j}");
                assert!(got.is_some(), "every name matches a key: {j}");
                if e.work_left == 0 {
                    spent_at = Some(j);
                    assert!(e.retained > bound, "the bound spent it: {}", e.retained);
                } else {
                    assert!(e.retained <= bound, "{} at name {j}", e.retained);
                }
            } else {
                assert_eq!(got, None, "name {j} comes after the budget is spent");
                if j % 97 == 0 && env_end_walk(s, k, name).is_some() {
                    deviating += 1;
                }
            }
        }
        let spent_at = spent_at.expect("the groups must pass the bound");
        assert!(
            spent_at > 20 && spent_at < names.len() / 4,
            "spent after {spent_at} names of {}",
            names.len()
        );
        assert!(
            deviating > 10,
            "{deviating} sampled names differ from the walk"
        );
        // one group may pass the bound; none is dropped, so nothing else grows
        let e = ix.envs.as_ref().expect("built");
        assert!(
            biggest <= bound + 2 * e.total_events,
            "{biggest} retained for {} occurrences",
            e.total_events
        );
        assert_eq!(biggest, e.retained, "nothing was dropped");
        assert!(e.merged.len() > 10, "the test must make merged groups");
        // every name answered before still has its answer, asked in any order
        for j in (0..=spent_at).rev() {
            let again = ix.env_end(begins[j], names[j].as_bytes());
            assert_eq!(again, answers[j], "name {j} asked again");
        }
    }

    /// The rule of D4 for the names answered before, in a small text. A name
    /// gets a merged group; other names then push the groups past the bound,
    /// which spends the budget; the first name, asked again, has the answer
    /// it had, and a new name has none.
    #[test]
    fn answers_are_kept_when_the_groups_pass_the_bound() {
        // `x**` matches the keys `x*` and `x**`, `y**` the keys `y*` and `y**`, ...
        let text = "\\begin{x**}\\begin{y**}\\begin{z**}\\begin{w**}\
                    \\end{x*}\\end{x**}\\end{y*}\\end{y**}\\end{z*}\\end{z**}\\end{w*}\\end{w**}";
        let s = text.as_bytes();
        let at = |n: &str| text.find(&format!("\\begin{{{n}}}")).expect("name");
        let mut ix = SegIndex::new(s);
        let x = ix.env_end(at("x**"), b"x**");
        assert_eq!(x, env_end_walk(s, at("x**"), b"x**"));
        assert!(x.is_some());
        let e = ix.envs.as_mut().expect("built");
        assert_eq!(e.merged.len(), 1, "the name made a merged group");
        assert!(e.work_left > 0);
        // the groups are at the bound: the next one passes it
        e.retained = 2 * e.total_events + 4096;
        let y = ix.env_end(at("y**"), b"y**");
        assert_eq!(
            y,
            env_end_walk(s, at("y**"), b"y**"),
            "the last name still answered"
        );
        assert!(y.is_some());
        let e = ix.envs.as_ref().expect("built");
        assert_eq!(e.work_left, 0, "passing the bound spends the budget");
        assert_eq!(e.merged.len(), 2, "no group was dropped");
        // the first name, and the second, asked again: the answers they had
        assert_eq!(ix.env_end(at("x**"), b"x**"), x, "answered before");
        assert_eq!(ix.env_end(at("y**"), b"y**"), y, "answered before");
        // a name not answered before has none, though the walk would give it one
        assert!(env_end_walk(s, at("z**"), b"z**").is_some());
        assert_eq!(ix.env_end(at("z**"), b"z**"), None, "past the budget");
        assert_eq!(ix.env_end(at("w**"), b"w**"), None, "past the budget");
        // and the first name again, after the others were refused
        assert_eq!(ix.env_end(at("x**"), b"x**"), x);
    }

    /// Reads the keys back from a trie by walking it: for every key that ends
    /// at a node, the labels on the way down put together; and checks what a
    /// path-compressed trie promises.
    fn check_trie(trie: &Trie, keys: &[&[u8]]) {
        assert!(
            trie.nodes.len() <= 2 * keys.len() + 1,
            "{} nodes for {} keys",
            trie.nodes.len(),
            keys.len()
        );
        let mut seen = vec![false; keys.len()];
        // (node, the path to it)
        let mut stack = vec![(0usize, Vec::<u8>::new())];
        while let Some((v, path)) = stack.pop() {
            let n = trie.nodes[v];
            let mut kids = 0;
            let mut leads = std::collections::HashSet::new();
            let mut c = n.first;
            while c != NONE {
                let kid = trie.nodes[c];
                let label = &keys[kid.key][kid.lo..kid.hi];
                assert!(!label.is_empty(), "an empty edge into node {c}");
                assert_eq!(trie.lead[c], label[0], "lead of node {c}");
                assert!(
                    leads.insert(trie.lead[c]),
                    "two children start with the same byte"
                );
                let mut p = path.clone();
                p.extend_from_slice(label);
                stack.push((c, p));
                kids += 1;
                c = trie.next[c];
            }
            if n.term != 0 {
                let id = n.term - 1;
                assert_eq!(keys[id], path.as_slice(), "key {id} ends at node {v}");
                assert!(!seen[id], "key {id} ends twice");
                seen[id] = true;
            }
            // a node that is not the root is a key's end or a place where two keys part
            if v != 0 {
                assert!(
                    n.term != 0 || kids >= 2,
                    "node {v} could be merged with its child"
                );
            }
        }
        assert!(seen.iter().all(|&x| x), "every key ends at a node");
    }

    /// The trie holds every key once, in as few nodes as there are ends and
    /// parting points of keys, whatever the length of the keys.
    #[test]
    fn trie_is_path_compressed() {
        // keys that are prefixes of one another, with the empty key, in every order
        let chain: Vec<Vec<u8>> = (0..=12).map(|n| vec![b'a'; n]).collect();
        let mut order: Vec<usize> = (0..chain.len()).collect();
        let mut state = 0x2545_f491_4f6c_dd1du64;
        for _ in 0..50 {
            for i in (1..order.len()).rev() {
                order.swap(i, (xorshift(&mut state) % (i as u64 + 1)) as usize);
            }
            let keys: Vec<&[u8]> = order.iter().map(|&i| chain[i].as_slice()).collect();
            check_trie(&Trie::new(&keys), &keys);
        }
        // random sets over a small alphabet, short and long, every order
        for round in 0..2000 {
            let alphabet: &[u8] = if round % 2 == 0 { b"ab" } else { b"abc*" };
            let max = if round % 3 == 0 { 40 } else { 7 };
            let mut owned: Vec<Vec<u8>> = (0..1 + xorshift(&mut state) % 30)
                .map(|_| random_word(&mut state, alphabet, max))
                .collect();
            owned.sort();
            owned.dedup();
            for i in (1..owned.len()).rev() {
                owned.swap(i, (xorshift(&mut state) % (i as u64 + 1)) as usize);
            }
            let keys: Vec<&[u8]> = owned.iter().map(Vec::as_slice).collect();
            check_trie(&Trie::new(&keys), &keys);
        }
        // long keys that share almost everything: a node per part of the keys, not per byte
        let prefix = "ab".repeat(2500);
        let owned: Vec<String> = (0..1000)
            .map(|i| format!("{prefix}{}{}", nth_letters(i), "c".repeat(10)))
            .collect();
        let keys: Vec<&[u8]> = owned.iter().map(|k| k.as_bytes()).collect();
        let trie = Trie::new(&keys);
        check_trie(&trie, &keys);
        assert!(trie.nodes.len() < 2100, "{} nodes", trie.nodes.len());
        // one key of a hundred thousand bytes is three nodes at most
        let long = "a".repeat(100_000);
        let keys: [&[u8]; 2] = [long.as_bytes(), b"ab"];
        let trie = Trie::new(&keys);
        check_trie(&trie, &keys);
        assert_eq!(
            trie.nodes.len(),
            4,
            "the root, the shared `a`, and the two ends"
        );
    }

    // ---- deviation D4: the work and the memory of the names with a starred atom ----

    /// `\begin{x*` + `atoms` times `a*` + `}`, then `\begin{x*` + `key` times
    /// `a` + `}`: the pattern keeps every prefix of the key alive, so the walk
    /// over the trie goes as deep as the key, with a state set of
    /// `atoms / 64 + 1` words at each level.
    fn deep_key_text(atoms: usize, key: usize) -> String {
        format!(
            "\\begin{{x*{}}} \\begin{{x*{}}}",
            "a*".repeat(atoms),
            "a".repeat(key)
        )
    }

    /// The letters `a`, `b`, ..., `z`, `aa`, `ab`, ...
    fn nth_letters(mut i: usize) -> String {
        let mut v = Vec::new();
        loop {
            v.push(b'a' + (i % 26) as u8);
            i /= 26;
            if i == 0 {
                break;
            }
            i -= 1;
        }
        v.reverse();
        String::from_utf8(v).unwrap_or_default()
    }

    /// Keys `x*` + a word of at most four runs `a^i b^j a^k b^l`, then names
    /// `x*a*b*a*b*` + four starred letters that no key holds: every name
    /// matches every key, so the work of the names alone is their number times
    /// the number of keys. About `size` bytes, a third of them keys.
    fn every_name_matches_every_key(size: usize) -> String {
        let mut s = String::new();
        let mut len = 0;
        'keys: loop {
            for a in 0..=len {
                for b in 0..=(len - a) {
                    for c in 0..=(len - a - b) {
                        let d = len - a - b - c;
                        s.push_str(&format!(
                            "\\begin{{x*{}{}{}{}}} ",
                            "a".repeat(a),
                            "b".repeat(b),
                            "a".repeat(c),
                            "b".repeat(d)
                        ));
                        if s.len() > size / 3 {
                            break 'keys;
                        }
                    }
                }
            }
            len += 1;
        }
        let mut j = 0;
        while s.len() < size {
            let mut name = String::from("x*a*b*a*b*");
            let mut v = j;
            for _ in 0..4 {
                name.push((b'c' + (v % 24) as u8) as char);
                name.push('*');
                v /= 24;
            }
            s.push_str(&format!("\\begin{{{name}}} "));
            j += 1;
        }
        s
    }

    /// Asks the index for the end of every `\begin{name}` of `text`, the way
    /// the scan does, and returns the answers.
    fn ask_every_begin<'a>(ix: &mut SegIndex<'a>, text: &'a str) -> Vec<Option<usize>> {
        let s = text.as_bytes();
        let mut out = Vec::new();
        let mut k = 0;
        while let Some(p) = text.get(k..).and_then(|r| r.find("\\begin{")) {
            let at_ = k + p;
            let open = at_ + 7;
            let mut q = open;
            while q < s.len() && (s[q].is_ascii_alphabetic() || s[q] == b'*') {
                q += 1;
            }
            if q < s.len() && s[q] == b'}' {
                out.push(ix.env_end(at_, &s[open..q]));
            }
            k = at_ + 1;
        }
        out
    }

    fn initial_work(len: usize) -> usize {
        STAR_WORK_FACTOR * len + STAR_WORK_BASE
    }

    /// A name with `N` starred atoms read along a key of `M` bytes needed `M * N
    /// / 64` words of state sets at once when the trie had a node for every
    /// byte: 1 GiB for 256 KiB of text. The walk keeps one set for every node
    /// of the path it is on and two for the edge it is stepping along, so the
    /// key's length does not matter to the memory, and the time is paid for by
    /// the work budget, which is spent when the walk gives up.
    #[test]
    fn walk_memory_stays_within_the_segment() {
        for size in [32 * 1024, 128 * 1024] {
            let text = deep_key_text(size / 4, size / 2);
            let mut ix = SegIndex::new(text.as_bytes());
            let answers = ask_every_begin(&mut ix, &text);
            assert_eq!(answers, [None, None]);
            let e = ix.envs.as_ref().expect("built");
            let (sets, stack) = (e.walk.sets.capacity(), e.walk.stack.capacity());
            // the pattern's `size / 4` atoms are `size / 256 + 1` words; the
            // path has two nodes with children, so four sets at most (the
            // vector may double once)
            let words = size / 4 / 64 + 1;
            assert!(
                sets > 0 && sets <= 2 * 4 * words,
                "{sets} words of state sets"
            );
            assert!(sets <= 2 * (text.len() + STAR_SET_WORDS_BASE));
            assert!(stack > 0 && stack <= 8, "{stack} frames");
            assert_eq!(e.work_left, 0, "the walk that gave up spent the budget");
            // the trie of the two keys: the root, the shared `x*a`, and the two ends
            assert_eq!(e.trie.as_ref().expect("built").nodes.len(), 4);
        }
    }

    /// A path of many nodes that have children, read with a pattern of many
    /// words, needs a set for each: the keys `x*b`, `x*bb`, `x*bbb`, ... are a
    /// chain of nodes, and the pattern `x*` and `N` times `b*` keeps every one
    /// of them alive. The sets of the walk stop at one word per byte of the
    /// segment and the walk gives up there; without the cap it would match
    /// every key, at a few words per byte of the segment.
    #[test]
    fn sets_of_a_long_path_are_capped() {
        let (keys, atoms) = (400, 200_000);
        let name = format!("x*{}", "b*".repeat(atoms));
        let mut text = format!("\\begin{{{name}}} ");
        for k in 1..=keys {
            let key = format!("x*{}", "b".repeat(k));
            text.push_str(&format!("\\begin{{{key}}}\\end{{{key}}} "));
        }
        let s = text.as_bytes();
        let mut ix = SegIndex::new(s);
        assert_eq!(ix.env_end(0, name.as_bytes()), None, "past the cap");
        let e = ix.envs.as_ref().expect("built");
        let words = atoms / 64 + 1;
        assert!(
            words * keys > 2 * (text.len() + STAR_SET_WORDS_BASE),
            "the shape must need more sets than the cap: {} words for {} bytes",
            words * keys,
            text.len()
        );
        let sets = e.walk.sets.capacity();
        assert!(
            sets > 0 && sets <= 2 * (text.len() + STAR_SET_WORDS_BASE),
            "{sets} words"
        );
        assert_eq!(e.work_left, 0, "the walk that gave up spent the budget");
        // the sets held up to the cap, one for each node of the path
        assert!(e.walk.stack.len() > 100, "{} frames", e.walk.stack.len());
        // with fewer atoms the same keys are all matched and the path is exact
        let name = format!("x*{}", "b*".repeat(100));
        let mut text = format!("\\begin{{{name}}} ");
        for k in 1..=keys {
            let key = format!("x*{}", "b".repeat(k));
            text.push_str(&format!("\\begin{{{key}}}\\end{{{key}}} "));
        }
        let s = text.as_bytes();
        let mut ix = SegIndex::new(s);
        // every key matches, so the name closes at the first `\end`
        let first_end = "\\end{x*b}";
        let want = text.find(first_end).map(|p| p + first_end.len());
        assert!(want.is_some());
        assert_eq!(ix.env_end(0, name.as_bytes()), want);
        let e = ix.envs.as_ref().expect("built");
        assert_eq!(e.merged.len(), 1, "all the keys in one group");
        assert!(e.work_left > 0);
        assert!(e.walk.stack.is_empty() || e.walk.stack.capacity() <= 2 * (keys + 4));
    }

    /// Many names that each stay alive along one long key walk all of it, one
    /// word of state per byte, so the memory is small and the time is the
    /// number of names times the length of the key. The walk pays for every
    /// child it looks at, and the budget ends it.
    #[test]
    fn walks_along_one_long_key_are_paid_for() {
        let size = 128 * 1024;
        let mut text = format!("\\begin{{x*{}}} ", "a".repeat(size / 2));
        let mut j = 0;
        while text.len() < size {
            text.push_str(&format!(
                "\\begin{{x*a*{}*{}*{}*}} ",
                (b'c' + (j % 24) as u8) as char,
                (b'c' + (j / 24 % 24) as u8) as char,
                (b'c' + (j / 576 % 24) as u8) as char
            ));
            j += 1;
        }
        let mut ix = SegIndex::new(text.as_bytes());
        let answers = ask_every_begin(&mut ix, &text);
        assert!(answers.len() > 2000 && answers.iter().all(Option::is_none));
        let e = ix.envs.as_ref().expect("built");
        assert_eq!(
            e.work_left, 0,
            "walking the key for every name must spend the budget"
        );
        // far fewer names were walked than there are
        assert!(
            e.by_pattern.len() < 100,
            "{} names were answered",
            e.by_pattern.len()
        );
    }

    /// Inside the bounds a deep walk is exact: a pattern of two words along a
    /// key of a thousand bytes, and one word along a key of 20,000. (A name
    /// with a starred letter never matches itself, so each `\begin` closes at
    /// the `\end` of the second, plain, environment.)
    #[test]
    fn walks_inside_the_bounds_are_exact() {
        let long = "a".repeat(1000);
        let wide = format!(
            "\\begin{{x*{}}}\\begin{{x*{long}}}p\\end{{x*{long}}}",
            "a*".repeat(100)
        );
        let longer = "a".repeat(20_000);
        let deep = format!("\\begin{{x*a*}}\\begin{{x*{longer}}}p\\end{{x*{longer}}}");
        for text in [wide, deep] {
            let s = text.as_bytes();
            let mut ix = SegIndex::new(s);
            for k in (0..s.len()).filter(|&k| sub(s, k, k + 7) == b"\\begin{") {
                let open = k + 7;
                let close = text[open..].find('}').map_or(s.len(), |p| open + p);
                let name = &s[open..close];
                let want = env_end_walk(s, k, name);
                assert_eq!(
                    ix.env_end(k, name),
                    want,
                    "{k} {}",
                    String::from_utf8_lossy(name)
                );
                if k == 0 {
                    assert_eq!(want, Some(text.len()), "the first begin closes");
                }
            }
            let e = ix.envs.as_ref().expect("built");
            assert!(e.work_left > 0, "the budget was not spent");
            // the walk along the key kept a few sets, not one for each byte of it
            assert!(
                e.walk.sets.capacity() <= 16 * (100 / 64 + 1 + 2),
                "{}",
                e.walk.sets.capacity()
            );
            assert!(e.walk.stack.capacity() <= 8);
        }
    }

    /// The names with a starred atom of a text that look like no LaTeX
    /// (`abc**`, `**abc`) are the shapes the trie keeps linear, and they spend
    /// a fraction of the work budget: a matcher that does not go through the
    /// trie spends none, and one that is quadratic does not finish.
    #[test]
    fn linear_shapes_spend_a_fraction_of_the_budget() {
        for (size, stars_first) in [
            (128 * 1024, false),
            (128 * 1024, true),
            (2 * 1024 * 1024, false),
            (2 * 1024 * 1024, true),
        ] {
            let mut text = String::new();
            let mut i = 0;
            while text.len() < size {
                let l = nth_letters(i);
                text.push_str(&if stars_first {
                    format!("\\begin{{**{l}}} a ")
                } else {
                    format!("\\begin{{{l}**}} a ")
                });
                i += 1;
            }
            let mut ix = SegIndex::new(text.as_bytes());
            let answers = ask_every_begin(&mut ix, &text);
            assert!(answers.len() > 5000 && answers.iter().all(Option::is_none));
            let left = ix.envs.as_ref().expect("built").work_left;
            let used = initial_work(text.len()) - left;
            assert!(
                used > text.len(),
                "the trie walk must have been charged: {used}"
            );
            assert!(
                left > initial_work(text.len()) / 4,
                "{used} of {} units spent",
                initial_work(text.len())
            );
        }
    }

    /// Names that each match every key cost the number of keys each; the
    /// budget ends that after a constant times the segment, and what is
    /// answered before and after is the rule of D4.
    #[test]
    fn names_past_the_work_budget_are_plain_text() {
        let text = every_name_matches_every_key(48 * 1024);
        let mut ix = SegIndex::new(text.as_bytes());
        let answers = ask_every_begin(&mut ix, &text);
        assert!(answers.iter().all(Option::is_none));
        let e = ix.envs.as_ref().expect("built");
        assert_eq!(e.work_left, 0, "the shape must spend the budget");

        // a small budget set by hand: the names answered before keep their
        // answers, a new name with a starred atom is plain text, a literal
        // name (one star) is not affected
        let text = "\\begin{a**}p\\end{a**} \\begin{b**}q\\end{b**} \\begin{c*}r\\end{c*}";
        let s = text.as_bytes();
        let begin_a = 0;
        let begin_b = text.find("\\begin{b").expect("b");
        let begin_c = text.find("\\begin{c").expect("c");
        let mut ix = SegIndex::new(s);
        let first = ix.env_end(begin_a, b"a**");
        assert_eq!(first, env_end_walk(s, begin_a, b"a**"));
        assert!(first.is_some());
        ix.envs.as_mut().expect("built").work_left = 0;
        assert_eq!(ix.env_end(begin_a, b"a**"), first, "answered before");
        assert!(env_end_walk(s, begin_b, b"b**").is_some());
        assert_eq!(ix.env_end(begin_b, b"b**"), None, "past the budget");
        assert_eq!(
            ix.env_end(begin_c, b"c*"),
            env_end_walk(s, begin_c, b"c*"),
            "a literal name is not a pattern"
        );
        assert!(ix.env_end(begin_c, b"c*").is_some());
    }

    /// Keys that differ only in the high bits of their last word spread over the
    /// buckets and the tags of the table (a multiply alone puts them all in
    /// one bucket with one tag, for every seed).
    #[test]
    fn hasher_spreads_keys_that_differ_in_high_bits() {
        let letters: Vec<u8> = (b'a'..=b'z').chain(b'A'..=b'Z').chain([b'*']).collect();
        // eight bytes; the last two vary, the low bits of the sixth are fixed
        let keys: Vec<[u8; 8]> = letters
            .iter()
            .filter(|&&x| x & 7 == b'A' & 7)
            .flat_map(|&x| {
                letters
                    .iter()
                    .map(move |&y| [b'a', b'b', b'c', b'd', b'e', b'f', x, y])
            })
            .collect();
        assert!(keys.len() > 300);
        for seed in [1u64, 0xdead_beef, 0x7fff_0000_1234, u64::MAX, 0x1_0000_0000] {
            let (mut buckets, mut tags) = (
                std::collections::HashSet::new(),
                std::collections::HashSet::new(),
            );
            for k in &keys {
                let mut h = Seeded(seed).build_hasher();
                h.write(k);
                let v = h.finish();
                buckets.insert(v & 0x1fff);
                tags.insert(v >> 57);
            }
            // 424 keys into 8192 buckets and 128 tags: a good hash fills about
            // 410 buckets and nearly all of the tags
            assert!(
                buckets.len() > keys.len() * 8 / 10,
                "seed {seed}: {} buckets",
                buckets.len()
            );
            assert!(tags.len() > 64, "seed {seed}: {} tags", tags.len());
        }
    }
}
