//! Rules about the library's source that keep the C boundary honest:
//! nothing prints, every export runs inside the panic guard, and the
//! exports and constants match the header's declaration block, which is
//! also what `native.lua` hands to LuaJIT's `ffi.cdef`.

use std::fs;
use std::path::{Path, PathBuf};

use jupynvim::abi::C_CONSTANTS;

const BEGIN: &str = "/* JNV-CDEF-BEGIN */";
const END: &str = "/* JNV-CDEF-END */";

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn read(rel: &str) -> String {
    let p = root().join(rel);
    fs::read_to_string(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()))
}

/// The declarations between the two markers of the header.
fn cdef() -> String {
    let h = read("include/jupynvim.h");
    assert_eq!(h.matches(BEGIN).count(), 1, "exactly one {BEGIN}");
    assert_eq!(h.matches(END).count(), 1, "exactly one {END}");
    let a = h.find(BEGIN).unwrap() + BEGIN.len();
    let b = h.find(END).unwrap();
    assert!(a <= b, "{BEGIN} comes before {END}");
    h[a..b].to_string()
}

fn is_ident(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// Names `jnv_...` directly followed (after blanks) by `(`: the functions a
/// block of C declarations declares.
fn c_function_names(src: &str) -> Vec<String> {
    let mut names = Vec::new();
    let mut rest = src;
    while let Some(i) = rest.find("jnv_") {
        let before = rest[..i].chars().last();
        let tail = &rest[i..];
        let len = tail.find(|c: char| !is_ident(c)).unwrap_or(tail.len());
        let name = &tail[..len];
        let after = tail[len..].trim_start();
        if !before.is_some_and(is_ident) && after.starts_with('(') {
            names.push(name.to_string());
        }
        rest = &tail[len..];
    }
    names
}

/// An exported function of lib.rs: its name and its source from the
/// signature to the closing brace (rustfmt puts it alone at column 0).
struct Export {
    name: String,
    body: String,
    no_mangle: bool,
}

fn exports(src: &str) -> Vec<Export> {
    let lines: Vec<&str> = src.lines().collect();
    let mut out = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        let sig = line
            .strip_prefix("pub extern \"C\" fn ")
            .or_else(|| line.strip_prefix("pub unsafe extern \"C\" fn "));
        let Some(sig) = sig else { continue };
        let name: String = sig.chars().take_while(|&c| is_ident(c)).collect();
        let end = (i..lines.len())
            .find(|&j| lines[j] == "}")
            .unwrap_or_else(|| panic!("no closing brace for {name}"));
        // The next export must not start before this one ends.
        let body = lines[i..=end].join("\n");
        let no_mangle = i > 0 && lines[i - 1].trim() == "#[no_mangle]";
        out.push(Export { name, body, no_mangle });
    }
    out
}

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    for e in fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() {
            rust_files(&p, out);
        } else if p.extension().is_some_and(|x| x == "rs") {
            out.push(p);
        }
    }
}

#[test]
fn nothing_in_the_library_prints() {
    let mut files = Vec::new();
    rust_files(&root().join("src"), &mut files);
    assert!(files.len() >= 6, "found {files:?}");
    let banned = [
        "print!(", "println!(", "eprint!(", "eprintln!(", "dbg!(",
        "io::stdout", "io::stderr", "stdout()", "stderr()",
    ];
    let mut hits = Vec::new();
    for f in &files {
        let text = fs::read_to_string(f).unwrap();
        for (n, line) in text.lines().enumerate() {
            for b in banned {
                if line.contains(b) {
                    hits.push(format!("{}:{}: {}", f.display(), n + 1, line.trim()));
                }
            }
        }
    }
    assert!(hits.is_empty(), "the library must never print:\n{}", hits.join("\n"));
}

#[test]
fn every_export_runs_inside_the_guard() {
    let src = read("src/lib.rs");
    let ex = exports(&src);
    assert_eq!(ex.len(), 14, "exports: {:?}", ex.iter().map(|e| &e.name).collect::<Vec<_>>());
    for e in &ex {
        assert!(e.no_mangle, "{} is not #[no_mangle]", e.name);
        assert!(e.body.contains("guard("), "{} does not run inside guard(", e.name);
        // One export per body: the next signature is outside this one.
        assert_eq!(e.body.matches("extern \"C\" fn ").count(), 1, "{} body runs into the next export", e.name);
    }
    assert_eq!(src.matches("#[no_mangle]").count(), ex.len(), "every #[no_mangle] is an export");
    assert_eq!(src.matches("extern \"C\" fn ").count(), ex.len(), "every extern fn is a recognized export");
}

#[test]
fn the_exports_are_the_header_functions() {
    let mut header = c_function_names(&cdef());
    header.sort();
    let mut lib: Vec<String> = exports(&read("src/lib.rs")).into_iter().map(|e| e.name).collect();
    lib.sort();
    assert_eq!(header.len(), 14, "{header:?}");
    assert_eq!(lib, header);
}

#[test]
fn the_fake_libraries_match_the_header() {
    let mut header = c_function_names(&cdef());
    header.sort();
    let mut fake: Vec<String> = exports(&read("examples/jnv_fake.rs")).into_iter().map(|e| e.name).collect();
    fake.sort();
    assert_eq!(fake, header, "jnv_fake exports every header function");
    let mut nosym: Vec<String> =
        exports(&read("examples/jnv_fake_nosym.rs")).into_iter().map(|e| e.name).collect();
    nosym.sort();
    assert_eq!(nosym, ["jnv_abi_version", "jnv_version"]);
    // Standalone: the fakes never link the real library.
    for f in ["examples/jnv_fake.rs", "examples/jnv_fake_nosym.rs"] {
        let s = read(f);
        assert!(!s.contains("jupynvim::") && !s.contains("use jupynvim"), "{f} uses the library");
    }
}

#[test]
fn the_cdef_block_holds_declarations_only() {
    let block = cdef();
    assert!(!block.contains('#'), "no preprocessor lines inside the markers");
    assert!(!block.contains("/*") && !block.contains("*/") && !block.contains("//"), "no comments inside the markers");
    assert!(block.contains("typedef struct jnv_ctx jnv_ctx;"));
}

/// The source of the function declared by the first line of `src` that
/// contains `decl`, up to the closing brace at that line's indentation.
fn fn_source(src: &str, decl: &str) -> String {
    let lines: Vec<&str> = src.lines().collect();
    let start = lines
        .iter()
        .position(|l| l.contains(decl))
        .unwrap_or_else(|| panic!("no line declares {decl}"));
    let indent = lines[start].len() - lines[start].trim_start().len();
    let close = format!("{}}}", " ".repeat(indent));
    let end = (start + 1..lines.len())
        .find(|&j| lines[j] == close)
        .unwrap_or_else(|| panic!("no closing brace for {decl}"));
    lines[start..=end].join("\n")
}

/// Where `needle` occurs in `hay`, which it must do exactly once.
fn once(hay: &str, needle: &str, what: &str) -> usize {
    let n = hay.matches(needle).count();
    assert_eq!(n, 1, "{what}: `{needle}` occurs {n} times, not once");
    hay.find(needle).unwrap()
}

/// A lost wake is a job that never runs, and the pool's lock-free submit
/// rests on one pair of sequentially consistent operations: a submit pushes
/// its job and only then reads `parked`; a worker raises `parked` and only
/// then looks at the inbox once more before it waits. Either the worker
/// sees the job or the submit sees the worker. The gate tests catch either
/// half reversed when the code still compiles the same way, but neither a
/// read moved in between nor an ordering relaxed to Release/Acquire shows
/// in a test: x86_64 makes every read-modify-write a full barrier, and the
/// gates serialize through their own flags. So the order and the strength
/// are checked here, in the text.
#[test]
fn the_pools_seqcst_pair_keeps_its_order_and_strength() {
    let src = read("src/pool.rs");

    let submit = fn_source(&src, "pub unsafe fn submit(");
    let push = once(&submit, "sh.inbox.compare_exchange_weak(head, node, Ordering::SeqCst", "submit's push");
    let parked = once(&submit, "sh.parked.load(Ordering::SeqCst)", "submit's read of parked");
    let waking = once(&submit, "sh.waking.load(Ordering::SeqCst)", "submit's read of waking");
    assert!(push < parked, "submit reads parked before its push");
    assert!(push < waking, "submit reads waking before its push");
    for (op, all) in [("parked.load(", "parked.load(Ordering::SeqCst)"), ("waking.load(", "waking.load(Ordering::SeqCst)")] {
        assert_eq!(submit.matches(op).count(), submit.matches(all).count(), "submit has a {op}) that is not SeqCst");
    }
    assert_eq!(submit.matches("compare_exchange").count(), 1, "submit pushes with one compare_exchange");

    let worker = fn_source(&src, "fn worker_loop(");
    let a = once(&worker, "q.idle += 1;", "worker_loop's count of idle workers");
    let b = a + once(&worker[a..], "sh.cv.wait(q)", "worker_loop's wait");
    let park = &worker[a..b];
    let raise = once(park, "sh.parked.fetch_add(1, Ordering::SeqCst)", "the worker's raise of parked");
    let look = once(park, "sh.inbox.load(Ordering::SeqCst)", "the worker's last look at the inbox");
    assert!(raise < look, "the worker looks at the inbox before it counts itself parked");
    assert_eq!(park.matches("parked.fetch_add(").count(), 1, "one raise of parked before the wait");
    assert_eq!(park.matches("inbox.load(").count(), 1, "one look at the inbox before the wait");

    let take = fn_source(&src, "fn take_inbox(");
    once(&take, "sh.inbox.swap(ptr::null_mut(), Ordering::SeqCst)", "take_inbox's swap");
    assert_eq!(take.matches(".swap(").count(), 1, "take_inbox empties the inbox with one swap");
}

#[test]
fn the_cdef_constants_equal_abi_c_constants() {
    let block = cdef();
    // Every `NAME = number` inside the block, in order.
    let mut found: Vec<(String, i64)> = Vec::new();
    let toks: Vec<&str> = block
        .split(|c: char| c.is_whitespace() || c == ',' || c == '{' || c == '}' || c == ';')
        .filter(|t| !t.is_empty())
        .collect();
    let mut i = 0;
    while i < toks.len() {
        if toks[i] == "=" && i > 0 && i + 1 < toks.len() {
            let name = toks[i - 1].to_string();
            let value: i64 = toks[i + 1].parse().unwrap_or_else(|_| panic!("{name} = {}", toks[i + 1]));
            found.push((name, value));
            i += 2;
        } else {
            assert!(!toks[i].contains('='), "write NAME = value with blanks around =: {}", toks[i]);
            i += 1;
        }
    }
    let expected: Vec<(String, i64)> = C_CONSTANTS.iter().map(|(n, v)| (n.to_string(), *v)).collect();
    assert_eq!(found, expected, "header constants vs abi::C_CONSTANTS");
}
