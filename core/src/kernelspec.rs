// Discover Jupyter kernels by scanning kernelspec directories.
// Reference: https://jupyter-client.readthedocs.io/en/stable/kernels.html

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KernelSpec {
    /// Kernel name (directory name under kernels/)
    pub name: String,
    /// Path to the kernel directory containing kernel.json
    pub path: PathBuf,
    /// Argv to launch the kernel (with {connection_file} placeholder)
    pub argv: Vec<String>,
    pub display_name: String,
    pub language: String,
    #[serde(default)]
    pub interrupt_mode: Option<String>,
    #[serde(default)]
    pub env: HashMap<String, String>,
    #[serde(default)]
    pub metadata: serde_json::Value,
}

#[derive(Debug, Deserialize)]
struct KernelJson {
    argv: Vec<String>,
    display_name: String,
    language: String,
    #[serde(default)]
    interrupt_mode: Option<String>,
    #[serde(default)]
    env: HashMap<String, String>,
    #[serde(default)]
    metadata: serde_json::Value,
}

/// Standard Jupyter kernelspec dirs in priority order.
fn search_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Ok(s) = std::env::var("JUPYTER_PATH") {
        for p in s.split(':') {
            dirs.push(PathBuf::from(p).join("kernels"));
        }
    }
    if let Some(home) = dirs::home_dir() {
        // macOS user data
        dirs.push(home.join("Library/Jupyter/kernels"));
        // Linux user data
        if let Some(data) = dirs::data_dir() {
            dirs.push(data.join("jupyter/kernels"));
        }
        // Conda env shadow
        if let Ok(prefix) = std::env::var("CONDA_PREFIX") {
            dirs.push(PathBuf::from(&prefix).join("share/jupyter/kernels"));
        }
        if let Ok(prefix) = std::env::var("VIRTUAL_ENV") {
            dirs.push(PathBuf::from(&prefix).join("share/jupyter/kernels"));
        }
    }
    // System
    dirs.push(PathBuf::from("/usr/share/jupyter/kernels"));
    dirs.push(PathBuf::from("/usr/local/share/jupyter/kernels"));
    dirs.push(PathBuf::from("/opt/homebrew/share/jupyter/kernels"));
    dirs
}

/// All conda environment prefixes on this machine, whatever flavor of conda:
/// - `~/.conda/environments.txt`: conda's own registry, maintained for every
///   install kind. This is what makes `module load anaconda3` setups work:
///   the system install lives at an arbitrary module path, but user envs are
///   created under `~/.conda/envs` and BOTH end up registered here.
/// - Conventional home roots (miniconda3/anaconda3/...) + their `envs/*`,
///   plus `~/.conda/envs/*`, as fallback when environments.txt is absent.
/// - `CONDA_PREFIX` / `CONDA_EXE` from the backend env, when present.
/// Existing dirs only, deduped, registry order first.
fn conda_prefixes_from(home: Option<PathBuf>) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    let mut seen: std::collections::HashSet<PathBuf> = std::collections::HashSet::new();
    let mut add = |p: PathBuf, out: &mut Vec<PathBuf>, seen: &mut std::collections::HashSet<PathBuf>| {
        if p.is_dir() && seen.insert(p.clone()) {
            out.push(p);
        }
    };
    if let Some(home) = home {
        if let Ok(txt) = std::fs::read_to_string(home.join(".conda/environments.txt")) {
            for line in txt.lines() {
                let line = line.trim();
                if !line.is_empty() {
                    add(PathBuf::from(line), &mut out, &mut seen);
                }
            }
        }
        for root in ["miniconda3", "anaconda3", "miniforge3", "mambaforge", "micromamba"] {
            let r = home.join(root);
            add(r.clone(), &mut out, &mut seen);
            if let Ok(envs) = std::fs::read_dir(r.join("envs")) {
                for e in envs.flatten() {
                    add(e.path(), &mut out, &mut seen);
                }
            }
        }
        if let Ok(envs) = std::fs::read_dir(home.join(".conda/envs")) {
            for e in envs.flatten() {
                add(e.path(), &mut out, &mut seen);
            }
        }
    }
    out
}

/// conda_prefixes_from + prefixes implied by the backend's own environment:
/// CONDA_PREFIX / CONDA_EXE, and conda/python found on PATH. The PATH scan is
/// what makes `module load anaconda3` work: modules typically ONLY prepend
/// PATH (no CONDA_* vars), and a system install is never in the user's
/// ~/.conda/environments.txt unless they've created envs with it.
/// Kept separate from conda_prefixes_from so tests stay hermetic.
fn conda_prefixes() -> Vec<PathBuf> {
    let mut out = conda_prefixes_from(dirs::home_dir());
    let mut seen: std::collections::HashSet<PathBuf> = out.iter().cloned().collect();
    fn add(p: PathBuf, out: &mut Vec<PathBuf>, seen: &mut std::collections::HashSet<PathBuf>) {
        if p.is_dir() && seen.insert(p.clone()) {
            out.push(p);
        }
    }
    fn add_root(root: PathBuf, out: &mut Vec<PathBuf>, seen: &mut std::collections::HashSet<PathBuf>) {
        if let Ok(envs) = std::fs::read_dir(root.join("envs")) {
            for e in envs.flatten() {
                add(e.path(), out, seen);
            }
        }
        add(root, out, seen);
    }
    if let Ok(p) = std::env::var("CONDA_PREFIX") {
        add(PathBuf::from(p), &mut out, &mut seen);
    }
    if let Ok(exe) = std::env::var("CONDA_EXE") {
        // .../<root>/bin/conda -> <root>, plus its envs
        if let Some(root) = PathBuf::from(exe).parent().and_then(|b| b.parent()).map(|r| r.to_path_buf()) {
            add_root(root, &mut out, &mut seen);
        }
    }
    // PATH scan: any bin dir holding `conda` or a python whose prefix ships
    // jupyter kernels is an env/install worth listing.
    if let Ok(path) = std::env::var("PATH") {
        for dir in std::env::split_paths(&path) {
            let prefix = match dir.parent() {
                Some(p) => p.to_path_buf(),
                None => continue,
            };
            if dir.join("conda").is_file() {
                add_root(prefix.clone(), &mut out, &mut seen);
            } else if (dir.join("python3").is_file() || dir.join("python").is_file())
                && prefix.join("share/jupyter/kernels").is_dir()
            {
                add(prefix, &mut out, &mut seen);
            }
        }
    }
    out
}

/// Human label for an env prefix: its basename, with the parent folded in
/// when the basename alone is ambiguous:
///   /opt/packages/anaconda3/2024.10 -> "anaconda3-2024.10" (version dir)
///   /home/me/myproj/.venv           -> "myproj-.venv" (generic venv name)
fn env_label(prefix: &std::path::Path) -> String {
    let base = prefix
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "env".to_string());
    let generic_venv = base == ".venv" || base == "venv" || base == "env";
    let version_like = base.chars().next().map_or(false, |c| c.is_ascii_digit());
    if generic_venv || version_like {
        if let Some(parent) = prefix.parent().and_then(|p| p.file_name()) {
            let parent = parent.to_string_lossy();
            // envs/<name> and .conda/<name> are user-chosen env names, not
            // version dirs; keep just the name there.
            if parent != "envs" && parent != ".conda" {
                return format!("{parent}-{base}");
            }
        }
    }
    base
}

/// Project-local virtualenv prefixes: walk up from `start_dir` (10 levels)
/// looking for `.venv` / `venv` / `env` dirs. Closest-first, so the first
/// entry is the one auto-venv should prefer. Only dirs that actually contain
/// kernels get used downstream (pip's ipykernel ships
/// `<venv>/share/jupyter/kernels/python3`, so no manual registration needed).
pub fn project_env_prefixes(start_dir: &std::path::Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut dir = start_dir.to_path_buf();
    for _ in 0..10 {
        for name in [".venv", "venv", "env"] {
            let p = dir.join(name);
            if p.is_dir() {
                out.push(p);
            }
        }
        match dir.parent() {
            Some(parent) => dir = parent.to_path_buf(),
            None => break,
        }
    }
    out
}

/// The closest project venv's python kernel for `start_dir`, if any. Used by
/// auto-venv on the backend (remote parity with the frontend's local `.venv`
/// detection): a notebook inside a project with its own env runs on that env
/// unless the user explicitly picked a kernel.
pub fn closest_project_python_kernel(start_dir: &std::path::Path) -> Option<KernelSpec> {
    for prefix in project_env_prefixes(start_dir) {
        let mut found: HashMap<String, KernelSpec> = HashMap::new();
        add_conda_kernels(&mut found, std::slice::from_ref(&prefix));
        if let Some(spec) = found
            .into_values()
            .find(|s| s.language.eq_ignore_ascii_case("python"))
        {
            return Some(spec);
        }
    }
    None
}

/// Unique (key, display label) for an env kernel. Plain `base` when free,
/// else `base-<label>`; when two envs share a label (two "project" envs in
/// different roots), the nearest meaningful ancestor dir is folded in
/// ("shared-project"), with a numeric suffix as last resort. Without this the
/// second same-named env was silently dropped from the picker.
fn disambiguated(
    found: &HashMap<String, KernelSpec>,
    base: &str,
    prefix: &std::path::Path,
    label: &str,
) -> (String, String) {
    if !found.contains_key(base) {
        return (base.to_string(), label.to_string());
    }
    let mut lab = label.to_string();
    let mut key = format!("{base}-{lab}");
    if found.contains_key(&key) {
        let mut anc = prefix.parent();
        while let Some(a) = anc {
            if let Some(name) = a.file_name().map(|s| s.to_string_lossy().into_owned()) {
                if name != "envs" && name != ".conda" {
                    lab = format!("{name}-{label}");
                    key = format!("{base}-{lab}");
                    break;
                }
            }
            anc = a.parent();
        }
    }
    let mut n = 2;
    while found.contains_key(&key) {
        lab = format!("{label}-{n}");
        key = format!("{base}-{lab}");
        n += 1;
    }
    (key, lab)
}

/// Add per-conda-env kernels (VSCode style: every env with ipykernel shows up,
/// no manual `ipykernel install` registration needed — conda's ipykernel ships
/// `<prefix>/share/jupyter/kernels/python3`). Registered kernels found in the
/// standard dirs keep priority; name collisions get namespaced `<name>-<env>`.
/// Relative `python`/`python3` argv is rewritten to the env's own binary so
/// the kernel spawns correctly even when the backend's PATH lacks the env
/// (the `module load anaconda3` case).
fn add_conda_kernels(found: &mut HashMap<String, KernelSpec>, prefixes: &[PathBuf]) {
    // Dedupe against already-found kernels by resolved interpreter path, so a
    // registered spec and its conda twin don't both show.
    let mut known_argv0: std::collections::HashSet<String> =
        found.values().filter_map(|s| s.argv.first().cloned()).collect();
    for prefix in prefixes {
        let kdir = prefix.join("share/jupyter/kernels");
        let entries = match std::fs::read_dir(&kdir) {
            Ok(e) => e,
            Err(_) => {
                // No registered kernels in this env (no ipykernel installed).
                // Still list it if it has a python: picking it triggers an
                // automatic `pip install ipykernel` into the env at start
                // (VSCode-style), so every env is selectable with zero setup.
                synthesize_env_kernel(found, prefix, &mut known_argv0);
                continue;
            }
        };
        let label = env_label(prefix);
        let mut added_python = false;
        for ent in entries.flatten() {
            let path = ent.path();
            if !path.is_dir() {
                continue;
            }
            let base = match path.file_name().and_then(|s| s.to_str()) {
                Some(s) => s.to_string(),
                None => continue,
            };
            let mut spec = match load_one(&base, &path) {
                Ok(s) => s,
                Err(_) => continue,
            };
            if let Some(a0) = spec.argv.first().cloned() {
                if a0 == "python" || a0 == "python3" {
                    for cand in ["bin/python", "bin/python3"] {
                        let py = prefix.join(cand);
                        if py.is_file() {
                            spec.argv[0] = py.to_string_lossy().into_owned();
                            break;
                        }
                    }
                }
            }
            if let Some(a0) = spec.argv.first() {
                if known_argv0.contains(a0) {
                    continue; // same interpreter already listed
                }
            }
            let (key, lab) = disambiguated(found, &base, prefix, &label);
            if !spec.display_name.contains(&lab) {
                spec.display_name = format!("{} ({})", spec.display_name, lab);
            }
            if spec.language.eq_ignore_ascii_case("python") {
                added_python = true;
            }
            spec.name = key.clone();
            if let Some(a0) = spec.argv.first() {
                known_argv0.insert(a0.clone());
            }
            found.insert(key, spec);
        }
        // kernels dir existed but yielded no python kernel (e.g. only an R
        // kernel registered): still offer the env's python via auto-install.
        if !added_python {
            synthesize_env_kernel(found, prefix, &mut known_argv0);
        }
    }
}

/// Offer an env's python as a pickable kernel even though ipykernel isn't
/// installed there. argv is the real launch command; metadata flags the env
/// prefix so start_kernel can `pip install ipykernel` into it first.
fn synthesize_env_kernel(
    found: &mut HashMap<String, KernelSpec>,
    prefix: &std::path::Path,
    known_argv0: &mut std::collections::HashSet<String>,
) {
    let py = ["bin/python", "bin/python3"]
        .iter()
        .map(|c| prefix.join(c))
        .find(|p| p.is_file());
    let py = match py {
        Some(p) => p.to_string_lossy().into_owned(),
        None => return, // not a python env
    };
    if known_argv0.contains(&py) {
        return;
    }
    let label = env_label(prefix);
    let (key, lab) = disambiguated(found, "python3", prefix, &label);
    known_argv0.insert(py.clone());
    found.insert(
        key.clone(),
        KernelSpec {
            name: key,
            path: prefix.to_path_buf(),
            argv: vec![
                py,
                "-m".to_string(),
                "ipykernel_launcher".to_string(),
                "-f".to_string(),
                "{connection_file}".to_string(),
            ],
            display_name: format!("Python ({lab}) [installs ipykernel]"),
            language: "python".to_string(),
            interrupt_mode: None,
            env: HashMap::new(),
            metadata: serde_json::json!({
                "jupynvim": { "ensure_ipykernel": true, "prefix": prefix.to_string_lossy() }
            }),
        },
    );
}

pub fn discover_all() -> Vec<KernelSpec> {
    discover_for_dir(None)
}

/// Full kernel discovery. With `dir` set (a notebook's directory), kernels
/// from project-local venvs (`.venv`/`venv`/`env`, walking up) are included
/// ahead of conda envs, so the kernel picker can offer them directly.
pub fn discover_for_dir(dir: Option<&std::path::Path>) -> Vec<KernelSpec> {
    let mut found: HashMap<String, KernelSpec> = HashMap::new();
    for sdir in search_dirs() {
        let entries = match std::fs::read_dir(&sdir) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for ent in entries.flatten() {
            let path = ent.path();
            if !path.is_dir() {
                continue;
            }
            let name = match path.file_name().and_then(|s| s.to_str()) {
                Some(s) => s.to_string(),
                None => continue,
            };
            // First-found-wins (search dirs are ordered by priority)
            if found.contains_key(&name) {
                continue;
            }
            if let Ok(spec) = load_one(&name, &path) {
                found.insert(name, spec);
            }
        }
    }
    // Project-local venvs first (closest wins naming), then conda envs
    // (miniconda, anaconda, module-loaded system installs).
    if let Some(d) = dir {
        add_conda_kernels(&mut found, &project_env_prefixes(d));
    }
    add_conda_kernels(&mut found, &conda_prefixes());
    let mut list: Vec<KernelSpec> = found.into_values().collect();
    list.sort_by(|a, b| a.display_name.cmp(&b.display_name));
    list
}

pub fn discover_by_name(name: &str) -> Option<KernelSpec> {
    discover_all().into_iter().find(|s| s.name == name)
}

/// Resolve a kernelspec name with sensible fallbacks.
///
/// Match priority:
///   1. Exact name match (`julia-1.12` → `julia-1.12`).
///   2. Prefix-with-dash match (`julia` → `julia-1.12` if installed).
///      Catches notebooks saved without a version suffix.
///   3. Language match (notebook says language="julia" but no exact / prefix
///      kernel found → use the first installed kernel whose language matches).
///      Lets a notebook from a 1.10 user open cleanly on a machine with only
///      1.12 installed, even if name and prefix both differ.
/// Returns None if nothing matches.
pub fn discover_with_fallback(name: &str, language: Option<&str>) -> Option<KernelSpec> {
    discover_with_fallback_in(name, language, None)
}

/// discover_with_fallback over discover_for_dir, so picker-chosen project-venv
/// kernel names (e.g. "python3-myproj-.venv") resolve when starting too.
pub fn discover_with_fallback_in(
    name: &str,
    language: Option<&str>,
    dir: Option<&std::path::Path>,
) -> Option<KernelSpec> {
    let all = discover_for_dir(dir);
    if let Some(s) = all.iter().find(|s| s.name == name) {
        return Some(s.clone());
    }
    let prefix = format!("{name}-");
    if let Some(s) = all.iter().find(|s| s.name.starts_with(&prefix)) {
        return Some(s.clone());
    }
    if let Some(lang) = language {
        let lang_lower = lang.to_lowercase();
        if let Some(s) = all.iter().find(|s| s.language.to_lowercase() == lang_lower) {
            return Some(s.clone());
        }
    }
    None
}

fn load_one(name: &str, dir: &PathBuf) -> Result<KernelSpec> {
    let kj_path = dir.join("kernel.json");
    let raw = std::fs::read_to_string(&kj_path)
        .with_context(|| format!("reading {}", kj_path.display()))?;
    let kj: KernelJson = serde_json::from_str(&raw)
        .with_context(|| format!("parsing {}", kj_path.display()))?;
    Ok(KernelSpec {
        name: name.to_string(),
        path: dir.clone(),
        argv: kj.argv,
        display_name: kj.display_name,
        language: kj.language,
        interrupt_mode: kj.interrupt_mode,
        env: kj.env,
        metadata: kj.metadata,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn discover_does_not_panic() {
        let _ = discover_all();
    }

    fn mk_env(prefix: &std::path::Path, display: &str) {
        let kdir = prefix.join("share/jupyter/kernels/python3");
        fs::create_dir_all(&kdir).unwrap();
        fs::create_dir_all(prefix.join("bin")).unwrap();
        fs::write(prefix.join("bin/python"), "").unwrap();
        fs::write(
            kdir.join("kernel.json"),
            format!(
                r#"{{"argv":["python","-m","ipykernel_launcher","-f","{{connection_file}}"],"display_name":"{display}","language":"python"}}"#
            ),
        )
        .unwrap();
    }

    #[test]
    fn conda_envs_discovered_and_rewritten() {
        let home = std::env::temp_dir().join(format!("jvtest-conda-{}", std::process::id()));
        let _ = fs::remove_dir_all(&home);
        // module-anaconda-style: system base + user env under ~/.conda/envs,
        // both registered in environments.txt
        let base = home.join("opt/anaconda3/2024.10");
        let ml = home.join(".conda/envs/ml");
        mk_env(&base, "Python 3 (ipykernel)");
        mk_env(&ml, "Python 3 (ipykernel)");
        fs::create_dir_all(home.join(".conda")).unwrap();
        fs::write(
            home.join(".conda/environments.txt"),
            format!("{}\n{}\n", base.display(), ml.display()),
        )
        .unwrap();

        let prefixes = conda_prefixes_from(Some(home.clone()));
        assert!(prefixes.contains(&base), "base registered via environments.txt");
        assert!(prefixes.contains(&ml), "user env registered via environments.txt");

        let mut found: HashMap<String, KernelSpec> = HashMap::new();
        add_conda_kernels(&mut found, &prefixes);
        assert_eq!(found.len(), 2, "one kernel per env");
        // first env keeps the plain name; second is namespaced
        let plain = found.get("python3").expect("base keeps python3 name");
        assert_eq!(plain.argv[0], base.join("bin/python").to_string_lossy());
        let ns = found.get("python3-ml").expect("env namespaced as python3-ml");
        assert_eq!(ns.argv[0], ml.join("bin/python").to_string_lossy());
        assert!(ns.display_name.contains("(ml)"), "display labeled: {}", ns.display_name);
        // version-basename label folds in the parent dir name
        assert!(plain.display_name.contains("anaconda3-2024.10"), "label: {}", plain.display_name);

        // dedupe: a registered kernel with the same interpreter suppresses the twin
        let mut found2: HashMap<String, KernelSpec> = HashMap::new();
        found2.insert(
            "python3".into(),
            KernelSpec {
                name: "python3".into(),
                path: ml.clone(),
                argv: vec![ml.join("bin/python").to_string_lossy().into_owned(), "-m".into(), "ipykernel_launcher".into()],
                display_name: "Registered".into(),
                language: "python".into(),
                interrupt_mode: None,
                env: HashMap::new(),
                metadata: serde_json::Value::Null,
            },
        );
        add_conda_kernels(&mut found2, &prefixes);
        assert_eq!(found2.len(), 2, "ml twin deduped by interpreter, base added");
        assert!(found2.contains_key("python3-anaconda3-2024.10") || found2.values().any(|s| s.argv[0] == base.join("bin/python").to_string_lossy()),
            "base env still added under a namespaced key");

        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn same_named_envs_both_listed() {
        // Mirrors the PSC case: ~/.conda/envs/project AND
        // /ocean/.../shared/envs/project. The second must not be dropped.
        let root = std::env::temp_dir().join(format!("jvtest-coll-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let a = root.join("home/.conda/envs/project");
        let b = root.join("ocean/shared/envs/project");
        // a has ipykernel-style registered kernel; b has only a python (so it
        // goes through synthesize_env_kernel)
        mk_env(&a, "Python 3 (ipykernel)");
        fs::create_dir_all(b.join("bin")).unwrap();
        fs::write(b.join("bin/python"), "").unwrap();

        let mut found: HashMap<String, KernelSpec> = HashMap::new();
        // a registered "python3" name is usually present already
        found.insert("python3".into(), KernelSpec {
            name: "python3".into(), path: root.clone(),
            argv: vec!["/usr/bin/python3".into()],
            display_name: "Python 3".into(), language: "python".into(),
            interrupt_mode: None, env: HashMap::new(), metadata: serde_json::Value::Null,
        });
        add_conda_kernels(&mut found, &[a.clone(), b.clone()]);
        assert!(found.contains_key("python3-project"), "first project listed: {:?}", found.keys().collect::<Vec<_>>());
        let second = found.iter().find(|(k, _)| k.starts_with("python3-shared-project")
            || k.starts_with("python3-project-2"));
        assert!(second.is_some(), "second project disambiguated, not dropped: {:?}", found.keys().collect::<Vec<_>>());
        let (_, spec) = second.unwrap();
        assert!(spec.metadata.pointer("/jupynvim/ensure_ipykernel").is_some(),
            "ipykernel-less env flagged for auto-install");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn project_envs_walk_up_and_label() {
        let root = std::env::temp_dir().join(format!("jvtest-proj-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        // myproj/.venv (closest) and a parent-level env/
        let nb_dir = root.join("work/myproj/notebooks");
        fs::create_dir_all(&nb_dir).unwrap();
        let dotvenv = root.join("work/myproj/.venv");
        let envdir = root.join("work/env");
        mk_env(&dotvenv, "Python 3 (ipykernel)");
        mk_env(&envdir, "Python 3 (ipykernel)");

        let prefixes = project_env_prefixes(&nb_dir);
        assert_eq!(prefixes[0], dotvenv, "closest env first: {prefixes:?}");
        assert!(prefixes.contains(&envdir));

        // closest python kernel = the .venv, argv rewritten absolute
        let closest = closest_project_python_kernel(&nb_dir).expect("found project kernel");
        assert_eq!(closest.argv[0], dotvenv.join("bin/python").to_string_lossy());

        // labels fold the project dir in for generic venv names
        let mut found: HashMap<String, KernelSpec> = HashMap::new();
        add_conda_kernels(&mut found, &prefixes);
        assert!(found.values().any(|s| s.display_name.contains("(myproj-.venv)")),
            "labels: {:?}", found.values().map(|s| s.display_name.clone()).collect::<Vec<_>>());

        let _ = fs::remove_dir_all(&root);
    }
}
