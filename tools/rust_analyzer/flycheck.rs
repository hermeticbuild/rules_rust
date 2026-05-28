//! Flycheck mode for the rust-analyzer helper binary: replays the
//! metadata-only typecheck commands the analyzer aspect captured
//! (`*.rust_analyzer_check_command.json`) for the package owning a saved file,
//! running rustc directly with no bazel hop per save.
//!
//! `install_flycheck_symlink` points rust-analyzer at this binary and
//! `maybe_run_flycheck` routes the symlinked invocation here.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::Context;
use camino::Utf8Path;
use serde::Deserialize;

use crate::{BUILD_FILE_NAMES, WORKSPACE_ROOT_FILE_NAMES};

const FLYCHECK_SYMLINK_NAME: &str = "bazel-rust-flycheck";

/// If this process was invoked through the flycheck symlink, run a check for
/// the saved file passed as the first argument and return `true`; the caller
/// should then exit. Returns `false` for a normal (discovery) invocation so the
/// caller proceeds as usual. Dispatching on `argv[0]` lets one binary serve
/// both of rust-analyzer's channels (discoverConfig and check.overrideCommand).
pub fn maybe_run_flycheck() -> bool {
    let mut args = std::env::args_os();
    let invoked_as_flycheck = args
        .next()
        .as_deref()
        .map(Path::new)
        .and_then(Path::file_name)
        .is_some_and(|name| name == FLYCHECK_SYMLINK_NAME);
    if !invoked_as_flycheck {
        return false;
    }
    if let Some(saved_file) = args.next() {
        run_flycheck(Path::new(&saved_file));
    }
    true
}

/// Installs a symlink at `<workspace>/bazel-rust-flycheck` pointing at this
/// binary, giving rust-analyzer a fixed path to call from `check.overrideCommand`.
/// Invoked under that name the binary runs in flycheck mode rather than
/// discovery; see `maybe_run_flycheck`.
///
/// We can't point the editor config straight at the binary: it lives deep under
/// `bazel-out` behind bzlmod canonical repo names that can't be hand-written, so
/// we resolve it here via `current_exe`.
///
/// The alias goes at the workspace root rather than under `bazel-out`, which
/// retargets across output_bases (common in monorepos that give the editor its
/// own) and would strand it. The `bazel-` prefix keeps it covered by the usual
/// `bazel-*` gitignore, so no new ignore entry is needed.
pub fn install_flycheck_symlink(workspace: &Utf8Path) -> anyhow::Result<()> {
    let current_exe = std::env::current_exe().context("failed to resolve current executable")?;
    let resolved = current_exe
        .canonicalize()
        .with_context(|| format!("failed to canonicalize {}", current_exe.display()))?;
    let symlink_path = workspace.join(FLYCHECK_SYMLINK_NAME);
    match fs::remove_file(&symlink_path) {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(error)
                .with_context(|| format!("failed to remove {symlink_path}"));
        }
    }
    symlink_to_file(&resolved, symlink_path.as_std_path())
        .with_context(|| format!("failed to symlink {symlink_path} -> {}", resolved.display()))?;
    Ok(())
}

#[cfg(unix)]
fn symlink_to_file(target: &Path, link: &Path) -> std::io::Result<()> {
    std::os::unix::fs::symlink(target, link)
}

#[cfg(windows)]
fn symlink_to_file(target: &Path, link: &Path) -> std::io::Result<()> {
    std::os::windows::fs::symlink_file(target, link)
}

const CHECK_COMMAND_SUFFIX: &str = ".rust_analyzer_check_command.json";

#[derive(Debug, Deserialize)]
struct CheckCommand {
    argv: Vec<String>,
    env: BTreeMap<String, String>,
}

/// Typecheck the crate(s) owning `saved_file` by replaying every check command
/// the aspect emitted for the file's Bazel package. Best-effort: anything that
/// goes wrong (file outside a workspace, missing outputs, malformed json) just
/// yields no diagnostics rather than erroring, so a save never surfaces noise.
pub fn run_flycheck(saved_file: &Path) {
    let Ok(saved_file) = saved_file.canonicalize() else {
        return;
    };
    let Some(workspace_root) = find_workspace_root(&saved_file) else {
        return;
    };
    let Ok(file_relative) = saved_file.strip_prefix(&workspace_root) else {
        return;
    };
    let Some(package_dir) = find_package_dir(&workspace_root, file_relative) else {
        return;
    };
    let Some(execroot) = resolve_execroot(&workspace_root) else {
        return;
    };

    let bin_dir = workspace_root.join("bazel-bin").join(&package_dir);
    for check_command_file in collect_check_command_files(&bin_dir) {
        run_check_command(&execroot, &check_command_file);
    }
}

fn find_workspace_root(saved_file: &Path) -> Option<PathBuf> {
    let mut dir = saved_file.parent()?;
    loop {
        if WORKSPACE_ROOT_FILE_NAMES
            .iter()
            .any(|marker| dir.join(marker).is_file())
        {
            return Some(dir.to_path_buf());
        }
        dir = dir.parent()?;
    }
}

fn find_package_dir(workspace_root: &Path, file_relative: &Path) -> Option<PathBuf> {
    let mut dir = file_relative.parent()?.to_path_buf();
    loop {
        let absolute = workspace_root.join(&dir);
        if BUILD_FILE_NAMES
            .iter()
            .any(|name| absolute.join(name).is_file())
        {
            return Some(dir);
        }
        if !dir.pop() {
            return None;
        }
    }
}

/// rustc resolves transitive crate lookups relative to its cwd; running from
/// the repo root (where `bazel-out` is a symlink) breaks lookups for some
/// crates. Bazel runs the same actions from `execroot`, which is the parent of
/// the real `bazel-out` directory.
fn resolve_execroot(workspace_root: &Path) -> Option<PathBuf> {
    let bazel_out = workspace_root.join("bazel-out").canonicalize().ok()?;
    bazel_out.parent().map(Path::to_path_buf)
}

fn collect_check_command_files(bin_dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(bin_dir) else {
        return Vec::new();
    };
    entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|name| name.ends_with(CHECK_COMMAND_SUFFIX))
        })
        .collect()
}

fn run_check_command(execroot: &Path, path: &Path) {
    let Ok(contents) = fs::read_to_string(path) else {
        return;
    };
    let Ok(command) = serde_json::from_str::<CheckCommand>(&contents) else {
        return;
    };
    let Some((program, args)) = command.argv.split_first() else {
        return;
    };
    // rustc writes JSON diagnostics to stderr; rust-analyzer reads them from
    // our stdout. Hand the child a clone of our stdout fd to use as its stderr,
    // so its diagnostics land where the editor is listening.
    let stderr_for_child = clone_stdout_as_stderr_target().unwrap_or_else(Stdio::inherit);
    let _ = Command::new(program)
        .args(args)
        .envs(&command.env)
        .current_dir(execroot)
        .stderr(stderr_for_child)
        .status();
}

#[cfg(unix)]
fn clone_stdout_as_stderr_target() -> Option<Stdio> {
    use std::os::fd::AsFd;
    std::io::stdout()
        .as_fd()
        .try_clone_to_owned()
        .ok()
        .map(Stdio::from)
}

#[cfg(not(unix))]
fn clone_stdout_as_stderr_target() -> Option<Stdio> {
    None
}
