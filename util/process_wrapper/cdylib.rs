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

//! Preserve rustc's ELF link metadata and native inputs for a Bazel-owned link.

use std::fs;
use std::io;
use std::path::Path;

pub(crate) const EXPORT_FILE_ENV: &str = "RULES_RUST_CDYLIB_EXPORT_FILE";
pub(crate) const SYMBOLS_FILE_ENV: &str = "RULES_RUST_CDYLIB_SYMBOLS_FILE";
pub(crate) const NATIVE_DIR_ENV: &str = "RULES_RUST_CDYLIB_NATIVE_DIR";

pub(crate) fn capture_exports(
    output: &Path,
    symbols_output: &Path,
    native_dir: &Path,
    args: Vec<String>,
) -> io::Result<()> {
    let mut expanded = Vec::new();
    for arg in args {
        if let Some(path) = arg.strip_prefix('@') {
            // rustc's GNU response files have one argument per line and escape
            // spaces and backslashes with a backslash.
            for line in fs::read_to_string(path)?.lines() {
                let mut chars = line.chars();
                let mut value = String::new();
                while let Some(c) = chars.next() {
                    value.push(if c == '\\' {
                        chars.next().ok_or_else(|| {
                            io::Error::new(io::ErrorKind::InvalidData, "truncated linker escape")
                        })?
                    } else {
                        c
                    });
                }
                expanded.push(value);
            }
        } else {
            expanded.push(arg);
        }
    }
    let scripts: Vec<_> = expanded
        .iter()
        .filter_map(|arg| arg.strip_prefix("-Wl,--version-script="))
        .collect();
    if scripts.len() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "expected one rustc cdylib export script, found {}",
                scripts.len()
            ),
        ));
    }
    let temp_dir = Path::new(scripts[0]).parent().unwrap();
    // rustc's synthetic object roots dependency exports and weak language
    // items. The version script alone does not pull them out of lazy archives.
    let symbols: Vec<_> = expanded
        .iter()
        .filter(|arg| {
            let path = Path::new(arg);
            path.parent() == Some(temp_dir)
                && path.file_name().is_some_and(|name| name == "symbols.o")
        })
        .collect();
    if symbols.len() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("expected one rustc symbols object, found {}", symbols.len()),
        ));
    }
    fs::copy(scripts[0], output)?;
    fs::copy(symbols[0], symbols_output)?;
    fs::create_dir_all(native_dir)?;
    // A build script attached directly to the cdylib has not been packed into
    // an rlib. rustc passes its static libraries by name under OUT_DIR.
    let out_dir = std::env::var_os("OUT_DIR").and_then(|path| fs::canonicalize(path).ok());
    let mut local_search_dirs = Vec::new();
    for (index, arg) in expanded.iter().enumerate() {
        let dir = if arg == "-L" {
            expanded.get(index + 1).map(String::as_str)
        } else {
            arg.strip_prefix("-L")
        };
        if let (Some(dir), Some(out_dir)) = (dir, &out_dir) {
            if let Ok(dir) = fs::canonicalize(dir) {
                if dir.starts_with(out_dir) {
                    local_search_dirs.push(dir);
                }
            }
        }
    }
    let mut whole_archive = false;
    let mut static_linkage = false;
    for (index, arg) in expanded.iter().enumerate() {
        match arg.as_str() {
            "-Wl,--whole-archive" => whole_archive = true,
            "-Wl,--no-whole-archive" => whole_archive = false,
            "-Wl,-Bstatic" | "-Bstatic" => static_linkage = true,
            "-Wl,-Bdynamic" | "-Bdynamic" => static_linkage = false,
            _ => {}
        }
        let path = Path::new(arg);
        let archive =
            if path.parent() == Some(temp_dir) && path.extension().is_some_and(|ext| ext == "a") {
                Some(path.to_owned())
            } else if static_linkage {
                arg.strip_prefix("-l").and_then(|name| {
                    let filename = name
                        .strip_prefix(':')
                        .map(str::to_owned)
                        .unwrap_or_else(|| format!("lib{name}.a"));
                    local_search_dirs
                        .iter()
                        .map(|dir| dir.join(&filename))
                        .find(|path| path.is_file())
                })
            } else {
                None
            };
        if let Some(path) = archive {
            let kind = if whole_archive { "whole" } else { "lazy" };
            let name = format!(
                "{index:08}-{kind}-{}",
                path.file_name().unwrap().to_string_lossy()
            );
            fs::copy(&path, native_dir.join(name))?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static NEXT_ID: AtomicUsize = AtomicUsize::new(0);

    struct Scratch(std::path::PathBuf);

    impl Scratch {
        fn new() -> Self {
            let root = std::env::var_os("TEST_TMPDIR")
                .map(std::path::PathBuf::from)
                .unwrap_or_else(std::env::temp_dir);
            let path = root.join(format!(
                "cdylib-{}-{}",
                std::process::id(),
                NEXT_ID.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }

    #[test]
    fn captures_compiler_policy_verbatim_from_response_file() {
        let scratch = Scratch::new();
        let script = scratch.0.join("exports with spaces");
        let response = scratch.0.join("linker-arguments");
        let output = scratch.0.join("captured.exports");
        let symbols = scratch.0.join("symbols.o");
        let symbols_output = scratch.0.join("captured.symbols.o");
        fs::write(&symbols, b"compiler-generated object").unwrap();
        let policy = "{ global: local_c_api; dependency_c_api; local: *; };\n";
        fs::write(&script, policy).unwrap();
        let argument = format!("-Wl,--version-script={}", script.display());
        let escaped = argument.replace('\\', "\\\\").replace(' ', "\\ ");
        fs::write(
            &response,
            format!("{escaped}\n{}\n-shared\n", symbols.display()),
        )
        .unwrap();
        capture_exports(
            &output,
            &symbols_output,
            &scratch.0.join("native"),
            vec![format!("@{}", response.display())],
        )
        .unwrap();
        assert_eq!(fs::read_to_string(output).unwrap(), policy);
        assert_eq!(
            fs::read(symbols_output).unwrap(),
            fs::read(symbols).unwrap()
        );
    }

    #[test]
    fn rejects_missing_or_ambiguous_export_policy() {
        let scratch = Scratch::new();
        let output = scratch.0.join("captured.exports");
        for args in [
            vec!["-shared".to_owned()],
            vec![
                "-Wl,--version-script=first".to_owned(),
                "-Wl,--version-script=second".to_owned(),
            ],
        ] {
            assert_eq!(
                capture_exports(
                    &output,
                    &scratch.0.join("captured.symbols.o"),
                    &scratch.0.join("native"),
                    args
                )
                .unwrap_err()
                .kind(),
                io::ErrorKind::InvalidData
            );
            assert!(!output.exists());
        }
    }
}
