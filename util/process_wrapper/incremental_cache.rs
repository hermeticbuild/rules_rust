// Copyright 2026 The Bazel Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! Cache-path computation and injection for `-Cincremental`.
//!
//! Given a base directory (typically `.rustc_incremental_cache` relative to the
//! Bazel output_base) and a set of rustc arguments, compute a deterministic
//! cache directory keyed on compilation-relevant inputs. A relative base is
//! resolved against the Bazel output_base when possible so that every action
//! converges on the same shared cache.
//!
//! Partition dimensions:
//!   - rustc binary path (identity)
//!   - target triple
//!   - crate name
//!   - edition
//!   - action kind (full vs metadata, the latter detected via `-Zno-codegen`)
//!   - stable hash of compilation-relevant flags

use std::collections::{hash_map::DefaultHasher, HashSet};
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};

/// Flags whose trailing value is an output path or diagnostic formatting knob.
/// Neither the flag nor its value contributes to the cache key.
const SKIP_WITH_VALUE: &[&str] = &[
    "-o",
    "--out-dir",
    "--error-format",
    "--json",
    "--color",
    "--remap-path-prefix",
];

/// `SKIP_WITH_VALUE` entries with a trailing `=`, pre-joined so the per-arg
/// loop can do a cheap `starts_with` without allocating a new `String`.
const SKIP_WITH_VALUE_EQ: &[&str] = &[
    "-o=",
    "--out-dir=",
    "--error-format=",
    "--json=",
    "--color=",
    "--remap-path-prefix=",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ActionKind {
    Full,
    Metadata,
}

#[derive(Debug)]
pub(crate) struct CacheKey {
    pub(crate) rustc_path: String,
    pub(crate) target_triple: String,
    pub(crate) crate_name: String,
    pub(crate) edition: String,
    pub(crate) action_kind: ActionKind,
    pub(crate) args_hash: u64,
}

/// Hash a single string with the same hasher we use for the args stream, so
/// callers that want a short directory-friendly digest of a path get something
/// consistent with the rest of the module.
fn stable_hash(s: &str) -> u64 {
    let mut h = DefaultHasher::new();
    s.hash(&mut h);
    h.finish()
}

impl CacheKey {
    /// Extract a cache key from the rustc executable path and rustc arguments.
    pub(crate) fn from_rustc_args(rustc_path: &str, args: &[&str]) -> Self {
        let mut target_triple = String::new();
        let mut crate_name = String::new();
        let mut edition = String::new();
        let mut action_kind = ActionKind::Full;

        let mut hasher = DefaultHasher::new();
        let mut skip_next = false;

        for (i, arg) in args.iter().enumerate() {
            if skip_next {
                skip_next = false;
                continue;
            }

            if *arg == "--target" {
                if let Some(val) = args.get(i + 1) {
                    target_triple = (*val).to_string();
                }
            } else if let Some(val) = arg.strip_prefix("--target=") {
                target_triple = val.to_string();
            } else if *arg == "--crate-name" {
                if let Some(val) = args.get(i + 1) {
                    crate_name = (*val).to_string();
                }
            } else if let Some(val) = arg.strip_prefix("--crate-name=") {
                crate_name = val.to_string();
            } else if *arg == "--edition" {
                if let Some(val) = args.get(i + 1) {
                    edition = (*val).to_string();
                }
            } else if let Some(val) = arg.strip_prefix("--edition=") {
                edition = val.to_string();
            } else if *arg == "-Zno-codegen" {
                action_kind = ActionKind::Metadata;
            }

            if SKIP_WITH_VALUE.contains(arg) {
                skip_next = true;
                continue;
            }
            if SKIP_WITH_VALUE_EQ.iter().any(|p| arg.starts_with(p)) {
                continue;
            }
            // Source file positional args are excluded: Bazel's action inputs
            // already capture them and including their paths destabilises the
            // key across workspace moves.
            if arg.ends_with(".rs") && !arg.starts_with('-') {
                continue;
            }

            arg.hash(&mut hasher);
        }

        CacheKey {
            rustc_path: rustc_path.to_string(),
            target_triple,
            crate_name,
            edition,
            action_kind,
            args_hash: hasher.finish(),
        }
    }

    /// Compute the full cache directory under `base`.
    ///
    /// Layout: `<base>/<rustc_hash>/<target>/<crate>-<edition>-<kind>/<args_hash>/`
    pub(crate) fn cache_dir(&self, base: impl AsRef<Path>) -> PathBuf {
        let rustc_hash = stable_hash(&self.rustc_path);

        let kind_str = match self.action_kind {
            ActionKind::Full => "full",
            ActionKind::Metadata => "meta",
        };
        let target = if self.target_triple.is_empty() {
            "host"
        } else {
            &self.target_triple
        };
        let crate_part = if self.crate_name.is_empty() {
            "unknown"
        } else {
            &self.crate_name
        };
        let edition_part = if self.edition.is_empty() {
            "default"
        } else {
            &self.edition
        };

        base.as_ref()
            .join(format!("{rustc_hash:016x}"))
            .join(target)
            .join(format!("{crate_part}-{edition_part}-{kind_str}"))
            .join(format!("{:016x}", self.args_hash))
    }
}

/// Resolve a `--inject-incremental-cache` argument to a stable absolute path.
///
/// Absolute paths pass through unchanged. Relative paths are resolved against
/// the Bazel `output_base`, detected by walking up `cwd` for the first
/// ancestor containing Bazel's `DO_NOT_BUILD_HERE` sentinel file. Every
/// action in the workspace resolves to the same cache location regardless of
/// strategy or cwd.
pub(crate) fn resolve_cache_base(arg: &str) -> PathBuf {
    let path = PathBuf::from(arg);
    if path.is_absolute() {
        return path;
    }
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    if let Some(output_base) = find_output_base(&cwd) {
        return output_base.join(arg);
    }
    cwd.join(arg)
}

/// Bazel writes `DO_NOT_BUILD_HERE` into every output_base as a sentinel that
/// prevents users from accidentally treating it as a workspace. Its presence
/// is a reliable, Bazel-maintained signal that a directory is an output_base.
fn find_output_base(start: &Path) -> Option<PathBuf> {
    let mut cur: Option<&Path> = Some(start);
    while let Some(d) = cur {
        if d.join("DO_NOT_BUILD_HERE").is_file() {
            return Some(d.to_path_buf());
        }
        cur = d.parent();
    }
    None
}

/// Compute the cache directory for a rustc invocation without creating it.
///
/// `@argfile` references in `rustc_args` are expanded by reading from disk,
/// so fields like `--crate-name`/`--target`/`--edition` are discovered even
/// when `process_wrapper` has moved them into a param file. A missing argfile
/// is skipped rather than failing the build; the key is computed from whatever
/// args were visible inline.
pub(crate) fn incremental_cache_dir(
    rustc_path: &str,
    rustc_args: &[&str],
    base: &Path,
) -> PathBuf {
    let expanded = expand_argfiles(rustc_args);
    let refs: Vec<&str> = expanded.iter().map(String::as_str).collect();
    let key = CacheKey::from_rustc_args(rustc_path, &refs);
    key.cache_dir(base)
}

/// Recursively expand `@path` argfile references into their file contents.
/// Missing or unreadable files are dropped; Bazel itself surfaces those errors
/// at action execution time. Visited argfile paths are tracked so self- or
/// mutually-referencing argfiles terminate rather than loop forever.
fn expand_argfiles(args: &[&str]) -> Vec<String> {
    let mut out = Vec::with_capacity(args.len());
    let mut visited = HashSet::new();
    for arg in args {
        if let Some(path) = arg.strip_prefix('@') {
            expand_one(path, &mut out, &mut visited);
        } else {
            out.push((*arg).to_string());
        }
    }
    out
}

fn expand_one(path: &str, out: &mut Vec<String>, visited: &mut HashSet<PathBuf>) {
    let canonical = std::fs::canonicalize(path).unwrap_or_else(|_| PathBuf::from(path));
    if !visited.insert(canonical) {
        return;
    }
    let Ok(content) = std::fs::read_to_string(path) else {
        return;
    };
    for line in content.lines() {
        if line.is_empty() {
            continue;
        }
        if let Some(nested) = line.strip_prefix('@') {
            expand_one(nested, out, visited);
        } else {
            out.push(line.to_string());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identical_args_produce_identical_keys() {
        let args = &[
            "--crate-name",
            "foo",
            "--edition=2021",
            "--target",
            "x86_64-unknown-linux-gnu",
            "-C",
            "opt-level=2",
        ];
        let k1 = CacheKey::from_rustc_args("/usr/bin/rustc", args);
        let k2 = CacheKey::from_rustc_args("/usr/bin/rustc", args);
        assert_eq!(k1.args_hash, k2.args_hash);
        assert_eq!(k1.crate_name, "foo");
        assert_eq!(k1.edition, "2021");
        assert_eq!(k1.target_triple, "x86_64-unknown-linux-gnu");
        assert_eq!(k1.action_kind, ActionKind::Full);
    }

    #[test]
    fn output_path_and_error_format_excluded_from_hash() {
        let a = &[
            "--crate-name",
            "foo",
            "-o",
            "/out/a",
            "--error-format",
            "json",
        ];
        let b = &[
            "--crate-name",
            "foo",
            "-o",
            "/out/b",
            "--error-format",
            "human",
        ];
        let k1 = CacheKey::from_rustc_args("/usr/bin/rustc", a);
        let k2 = CacheKey::from_rustc_args("/usr/bin/rustc", b);
        assert_eq!(k1.args_hash, k2.args_hash);
    }

    #[test]
    fn source_file_excluded_from_hash() {
        let a = &["--crate-name", "foo", "src/lib.rs"];
        let b = &["--crate-name", "foo", "other/lib.rs"];
        let k1 = CacheKey::from_rustc_args("/usr/bin/rustc", a);
        let k2 = CacheKey::from_rustc_args("/usr/bin/rustc", b);
        assert_eq!(k1.args_hash, k2.args_hash);
    }

    #[test]
    fn no_codegen_detected_as_metadata() {
        let args = &["--crate-name", "foo", "-Zno-codegen"];
        let k = CacheKey::from_rustc_args("/usr/bin/rustc", args);
        assert_eq!(k.action_kind, ActionKind::Metadata);
    }

    #[test]
    fn metadata_and_full_get_separate_dirs() {
        let full = CacheKey::from_rustc_args("/usr/bin/rustc", &["--crate-name", "foo"]);
        let meta =
            CacheKey::from_rustc_args("/usr/bin/rustc", &["--crate-name", "foo", "-Zno-codegen"]);
        assert_ne!(full.cache_dir("/tmp"), meta.cache_dir("/tmp"));
    }

    #[test]
    fn resolve_cache_base_passes_absolute_through() {
        let abs = if cfg!(windows) {
            r"C:\abs\path"
        } else {
            "/abs/path"
        };
        assert_eq!(resolve_cache_base(abs), PathBuf::from(abs));
    }

    #[test]
    fn find_output_base_detects_bazel_sentinel() {
        let root = std::env::temp_dir().join(format!(
            "pw_ob_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let ob = root.join("hash");
        std::fs::create_dir_all(&ob).unwrap();
        std::fs::write(ob.join("DO_NOT_BUILD_HERE"), "").unwrap();
        let cwd = ob.join("execroot").join("_main");
        std::fs::create_dir_all(&cwd).unwrap();
        assert_eq!(find_output_base(&cwd), Some(ob));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn expand_argfiles_terminates_on_cycle() {
        let tmp = std::env::temp_dir().join(format!(
            "pw_cycle_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();
        let a = tmp.join("a");
        let b = tmp.join("b");
        std::fs::write(&a, format!("@{}", b.display())).unwrap();
        std::fs::write(&b, format!("@{}", a.display())).unwrap();
        let arg = format!("@{}", a.display());
        let out = expand_argfiles(&[arg.as_str()]);
        assert!(out.is_empty(), "cycle should produce no literal args");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn expand_argfiles_reads_nested_file() {
        let tmp = std::env::temp_dir().join(format!(
            "pw_nest_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();
        let inner = tmp.join("inner");
        let outer = tmp.join("outer");
        std::fs::write(&inner, "--crate-name\nfoo\n").unwrap();
        std::fs::write(&outer, format!("@{}\n--edition=2021\n", inner.display())).unwrap();
        let arg = format!("@{}", outer.display());
        let out = expand_argfiles(&[arg.as_str()]);
        assert_eq!(out, vec!["--crate-name", "foo", "--edition=2021"]);
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
