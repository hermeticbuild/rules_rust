// Copyright 2020 The Bazel Authors. All rights reserved.
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

mod flags;
mod options;
mod output;
mod rustc;
mod util;

use std::collections::HashMap;
#[cfg(windows)]
use std::collections::{HashSet, VecDeque};
use std::fmt;
use std::fs::{self, copy, OpenOptions};
use std::io;
#[cfg(any(windows, test))]
use std::path::Path;
use std::path::PathBuf;
use std::process::{exit, Command, Stdio};
#[cfg(windows)]
use std::time::{SystemTime, UNIX_EPOCH};

use tinyjson::JsonValue;

use crate::options::options;
use crate::output::{process_output, LineOutput};
use crate::rustc::ErrorFormat;
#[cfg(windows)]
use crate::util::read_file_to_array;

const ARTIFACT_SCAN_BUFFER_SIZE: usize = 4 * 1024 * 1024;

#[derive(Debug)]
struct ProcessWrapperError(String);

impl fmt::Display for ProcessWrapperError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "process wrapper error: {}", self.0)
    }
}

impl std::error::Error for ProcessWrapperError {}

macro_rules! debug_log {
    ($($arg:tt)*) => {
        if std::env::var_os("RULES_RUST_PROCESS_WRAPPER_DEBUG").is_some() {
            eprintln!($($arg)*);
        }
    };
}

#[cfg(windows)]
struct TemporaryDirectoryGuard {
    path: Option<PathBuf>,
}

#[cfg(windows)]
impl TemporaryDirectoryGuard {
    fn new(path: Option<PathBuf>) -> Self {
        Self { path }
    }

    fn take(&mut self) -> Option<PathBuf> {
        self.path.take()
    }
}

#[cfg(windows)]
impl Drop for TemporaryDirectoryGuard {
    fn drop(&mut self) {
        if let Some(path) = self.path.take() {
            let _ = fs::remove_dir_all(path);
        }
    }
}

#[cfg(not(windows))]
struct TemporaryDirectoryGuard;

#[cfg(not(windows))]
impl TemporaryDirectoryGuard {
    fn new(_: Option<PathBuf>) -> Self {
        TemporaryDirectoryGuard
    }

    fn take(&mut self) -> Option<PathBuf> {
        None
    }
}

/// Matching on what rustc can actually use within a given `-Ldependency=` directory
#[cfg(any(windows, test))]
const CRATE_SEARCH_ARTIFACT_EXTENSIONS: &[&str] =
    &["rlib", "rmeta", "dll", "lib", "a", "so", "dylib"];

#[cfg(any(windows, test))]
fn is_crate_search_artifact(file_name: &str) -> bool {
    match Path::new(file_name).extension() {
        Some(extension) => {
            let extension = extension.to_string_lossy().to_ascii_lowercase();
            CRATE_SEARCH_ARTIFACT_EXTENSIONS.contains(&extension.as_str())
        }
        None => false,
    }
}

#[cfg(windows)]
fn get_dependency_search_paths_from_args(
    initial_args: &[String],
) -> Result<(Vec<PathBuf>, Vec<String>), ProcessWrapperError> {
    let mut dependency_paths = Vec::new();
    let mut filtered_args = Vec::new();
    let mut argfile_contents: HashMap<String, Vec<String>> = HashMap::new();

    let mut queue: VecDeque<(String, Option<String>)> = initial_args
        .iter()
        .map(|arg| (arg.clone(), None))
        .collect();

    while let Some((arg, parent_argfile)) = queue.pop_front() {
        let target = match &parent_argfile {
            Some(p) => argfile_contents.entry(format!("{}.filtered", p)).or_default(),
            None => &mut filtered_args,
        };

        if arg == "-L" {
            let next_arg = queue.front().map(|(a, _)| a.as_str());
            if let Some(path) = next_arg.and_then(|n| n.strip_prefix("dependency=")) {
                dependency_paths.push(PathBuf::from(path));
                queue.pop_front();
            } else {
                target.push(arg);
            }
        } else if let Some(path) = arg.strip_prefix("-Ldependency=") {
            dependency_paths.push(PathBuf::from(path));
        } else if let Some(argfile_path) = arg.strip_prefix('@') {
            let lines = read_file_to_array(argfile_path).map_err(|e| {
                ProcessWrapperError(format!("unable to read argfile {}: {}", argfile_path, e))
            })?;

            for line in lines {
                queue.push_back((line, Some(argfile_path.to_string())));
            }

            target.push(format!("@{}.filtered", argfile_path));
        } else {
            target.push(arg);
        }
    }

    for (path, content) in argfile_contents {
        fs::write(&path, content.join("\n")).map_err(|e| {
            ProcessWrapperError(format!("unable to write filtered argfile {}: {}", path, e))
        })?;
    }

    Ok((dependency_paths, filtered_args))
}

#[cfg(windows)]
fn consolidate_dependency_search_paths(
    args: &[String],
) -> Result<(Vec<String>, Option<PathBuf>), ProcessWrapperError> {
    let (dependency_paths, mut filtered_args) = get_dependency_search_paths_from_args(args)?;

    if dependency_paths.is_empty() {
        return Ok((filtered_args, None));
    }

    let unique_suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let dir_name = format!(
        "rules_rust_process_wrapper_deps_{}_{}",
        std::process::id(),
        unique_suffix
    );

    let base_dir = std::env::current_dir().map_err(|e| {
        ProcessWrapperError(format!("unable to read current working directory: {}", e))
    })?;
    let unified_dir = base_dir.join(&dir_name);
    fs::create_dir_all(&unified_dir).map_err(|e| {
        ProcessWrapperError(format!(
            "unable to create unified dependency directory {}: {}",
            unified_dir.display(),
            e
        ))
    })?;

    let mut seen = HashSet::new();
    for path in dependency_paths {
        let entries = fs::read_dir(&path).map_err(|e| {
            ProcessWrapperError(format!(
                "unable to read dependency search path {}: {}",
                path.display(),
                e
            ))
        })?;

        for entry in entries {
            let entry = entry.map_err(|e| {
                ProcessWrapperError(format!(
                    "unable to iterate dependency search path {}: {}",
                    path.display(),
                    e
                ))
            })?;
            let file_name = entry.file_name();
            let file_name_lower = file_name.to_string_lossy().to_ascii_lowercase();
            if !is_crate_search_artifact(&file_name_lower) {
                continue;
            }

            let file_type = entry.file_type().map_err(|e| {
                ProcessWrapperError(format!(
                    "unable to inspect dependency search path {}: {}",
                    path.display(),
                    e
                ))
            })?;
            if !(file_type.is_file() || file_type.is_symlink()) {
                continue;
            }

            if !seen.insert(file_name_lower) {
                continue;
            }

            let dest = unified_dir.join(&file_name);
            let src = entry.path();
            match fs::hard_link(&src, &dest) {
                Ok(_) => {}
                Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(err) => {
                    debug_log!(
                        "failed to hardlink {} to {} ({}), falling back to copy",
                        src.display(),
                        dest.display(),
                        err
                    );
                    fs::copy(&src, &dest).map_err(|copy_err| {
                        ProcessWrapperError(format!(
                            "unable to copy {} into unified dependency dir {}: {}",
                            src.display(),
                            dest.display(),
                            copy_err
                        ))
                    })?;
                }
            }
        }
    }

    filtered_args.push(format!("-Ldependency={}", unified_dir.display()));

    Ok((filtered_args, Some(unified_dir)))
}

#[cfg(not(windows))]
fn consolidate_dependency_search_paths(
    args: &[String],
) -> Result<(Vec<String>, Option<PathBuf>), ProcessWrapperError> {
    Ok((args.to_vec(), None))
}

fn json_warning(line: &str) -> JsonValue {
    JsonValue::Object(HashMap::from([
        (
            "$message_type".to_string(),
            JsonValue::String("diagnostic".to_string()),
        ),
        ("message".to_string(), JsonValue::String(line.to_string())),
        ("code".to_string(), JsonValue::Null),
        (
            "level".to_string(),
            JsonValue::String("warning".to_string()),
        ),
        ("spans".to_string(), JsonValue::Array(Vec::new())),
        ("children".to_string(), JsonValue::Array(Vec::new())),
        ("rendered".to_string(), JsonValue::String(line.to_string())),
    ]))
}

fn process_line(
    mut line: String,
    format: ErrorFormat,
) -> Result<LineOutput, String> {
    // LLVM can emit lines that look like the following, and these will be interspersed
    // with the regular JSON output. Arguably, rustc should be fixed not to emit lines
    // like these (or to convert them to JSON), but for now we convert them to JSON
    // ourselves.
    if line.contains("is not a recognized feature for this target (ignoring feature)")
        || line.starts_with(" WARN ")
    {
        if let Ok(json_str) = json_warning(&line).stringify() {
            line = json_str;
        } else {
            return Ok(LineOutput::Skip);
        }
    }
    rustc::process_json(line, format)
}

/// Search a byte stream in linear time with Knuth–Morris–Pratt:
/// https://en.wikipedia.org/wiki/Knuth%E2%80%93Morris%E2%80%93Pratt_algorithm
fn contains_byte_sequence(reader: &mut impl io::Read, needle: &[u8]) -> io::Result<bool> {
    if needle.is_empty() {
        return Ok(true);
    }

    // fallback_lengths[index] is the longest proper prefix of needle[..=index]
    // that is also a suffix, so mismatches do not rescan previously read bytes.
    let mut fallback_lengths = vec![0; needle.len()];
    let mut fallback_length = 0;
    for (index, &byte) in needle.iter().enumerate().skip(1) {
        while fallback_length > 0 && byte != needle[fallback_length] {
            fallback_length = fallback_lengths[fallback_length - 1];
        }
        if byte == needle[fallback_length] {
            fallback_length += 1;
        }
        fallback_lengths[index] = fallback_length;
    }

    let mut buffer = vec![0; ARTIFACT_SCAN_BUFFER_SIZE];
    // Keep matched between reads so matches can cross buffer boundaries.
    let mut matched = 0;
    loop {
        let bytes_read = reader.read(&mut buffer)?;
        if bytes_read == 0 {
            return Ok(false);
        }

        for &byte in &buffer[..bytes_read] {
            while matched > 0 && byte != needle[matched] {
                matched = fallback_lengths[matched - 1];
            }
            if byte == needle[matched] {
                matched += 1;
                if matched == needle.len() {
                    return Ok(true);
                }
            }
        }
    }
}

fn check_output_for_working_dir(
    output_path: &str,
    working_dir: &str,
) -> Result<(), ProcessWrapperError> {
    let mut output = fs::File::open(output_path)
        .map_err(|error| ProcessWrapperError(format!("failed to open {output_path}: {error}")))?;
    let contains_working_dir = contains_byte_sequence(&mut output, working_dir.as_bytes())
        .map_err(|error| ProcessWrapperError(format!("failed to scan {output_path}: {error}")))?;

    if contains_working_dir {
        return Err(ProcessWrapperError(format!(
            "compiled Rust output {output_path} embeds the absolute working directory {working_dir}. \
             Do not retain env!(\"CARGO_MANIFEST_DIR\") or env!(\"OUT_DIR\") in compiled code; \
             include_str!() and include_bytes!() may use those values only for compile-time file \
             access"
        )));
    }

    Ok(())
}

fn main() -> Result<(), ProcessWrapperError> {
    let opts = options().map_err(|e| ProcessWrapperError(e.to_string()))?;

    let (child_arguments, dep_dir_cleanup) =
        consolidate_dependency_search_paths(&opts.child_arguments)?;
    let mut temp_dir_guard = TemporaryDirectoryGuard::new(dep_dir_cleanup);

    let mut command = Command::new(opts.executable);
    command
        .args(child_arguments)
        .env_clear()
        .envs(opts.child_environment)
        .stdout(if let Some(stdout_file) = opts.stdout_file {
            OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .open(stdout_file)
                .map_err(|e| ProcessWrapperError(format!("unable to open stdout file: {}", e)))?
                .into()
        } else {
            Stdio::inherit()
        })
        .stderr(Stdio::piped());
    debug_log!("{:#?}", command);
    let mut child = command
        .spawn()
        .map_err(|e| ProcessWrapperError(format!("failed to spawn child process: {}", e)))?;

    let mut stderr: Box<dyn io::Write> = if let Some(stderr_file) = opts.stderr_file {
        Box::new(
            OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .open(stderr_file)
                .map_err(|e| ProcessWrapperError(format!("unable to open stderr file: {}", e)))?,
        )
    } else {
        Box::new(io::stderr())
    };

    let mut child_stderr = child.stderr.take().ok_or(ProcessWrapperError(
        "unable to get child stderr".to_string(),
    ))?;

    let mut output_file: Option<std::fs::File> = if let Some(output_file_name) = opts.output_file {
        Some(
            OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .open(output_file_name)
                .map_err(|e| ProcessWrapperError(format!("Unable to open output_file: {}", e)))?,
        )
    } else {
        None
    };

    let result = if let Some(format) = opts.rustc_output_format {
        process_output(
            &mut child_stderr,
            stderr.as_mut(),
            output_file.as_mut(),
            move |line| process_line(line, format),
        )
    } else {
        // Process output normally by forwarding stderr
        process_output(
            &mut child_stderr,
            stderr.as_mut(),
            output_file.as_mut(),
            move |line| Ok(LineOutput::Message(line)),
        )
    };
    result.map_err(|e| ProcessWrapperError(format!("failed to process stderr: {}", e)))?;

    let status = child
        .wait()
        .map_err(|e| ProcessWrapperError(format!("failed to wait for child process: {}", e)))?;
    let code = status.code().unwrap_or(1);
    if let Some(exit_code_file) = &opts.captured_exit_code_file {
        fs::write(exit_code_file, format!("{code}\n")).map_err(|e| {
            ProcessWrapperError(format!(
                "failed to write captured exit code to {}: {}",
                exit_code_file, e
            ))
        })?;
    }

    if code == 0 {
        for output_path in &opts.check_output_for_working_dir {
            check_output_for_working_dir(output_path, &opts.working_dir)?;
        }
        if let Some(tf) = opts.touch_file {
            OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .open(tf)
                .map_err(|e| ProcessWrapperError(format!("failed to create touch file: {}", e)))?;
        }
        if let Some((copy_source, copy_dest)) = opts.copy_output {
            copy(&copy_source, &copy_dest).map_err(|e| {
                ProcessWrapperError(format!(
                    "failed to copy {} into {}: {}",
                    copy_source, copy_dest, e
                ))
            })?;
        }
    }

    if let Some(path) = temp_dir_guard.take() {
        let _ = fs::remove_dir_all(path);
    }

    if opts.captured_exit_code_file.is_some() {
        Ok(())
    } else {
        exit(code)
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_contains_byte_sequence_with_overlapping_prefix() {
        let mut contents = io::Cursor::new(b"aaaaaab".as_slice());
        assert!(contains_byte_sequence(&mut contents, b"aaaab").unwrap());
    }

    #[test]
    fn test_contains_byte_sequence_across_buffer_boundary() {
        let working_dir = b"/sandbox/execroot/_main";
        let mut contents = vec![0xff; ARTIFACT_SCAN_BUFFER_SIZE - 3];
        contents.extend_from_slice(working_dir);
        contents.extend_from_slice(&[0x00, 0xfe]);
        let mut contents = io::Cursor::new(contents);
        assert!(contains_byte_sequence(&mut contents, working_dir).unwrap());
    }

    #[test]
    fn test_contains_byte_sequence_without_match() {
        let mut contents = io::Cursor::new(b"/sandbox/manifests".as_slice());
        assert!(!contains_byte_sequence(&mut contents, b"/sandbox/manifest/").unwrap());
    }

    #[test]
    fn test_is_crate_search_artifact_skips_transient_and_irrelevant_files() {
        for file_name in [
            // LLVM's atomic-output temporary for a concurrently linked sibling target.
            "ijent_util-subscriber_contract-test.exe.tmp8ceb5a4",
            "libfoo-1a2b3c.rlib.tmp0f1e2d3",
            "foo.rcgu.o",
            "foo.exe",
            "foo.pdb",
            "foo.d",
            "foo.rustc-output",
            "noextension",
        ] {
            assert!(
                !is_crate_search_artifact(file_name),
                "{} should not be linked into the unified dependency dir",
                file_name
            );
        }
    }

    #[test]
    fn test_is_crate_search_artifact_keeps_crate_artifacts() {
        for file_name in [
            "libfoo-1a2b3c.rlib",
            "libfoo-1a2b3c.rmeta",
            // Pipelined hollow rlib emitted into the `_meta/` subdirectory.
            "libfoo_meta.rlib",
            "foo.dll",
            // Import library rustc emits alongside a Windows cdylib.
            "foo.dll.lib",
            "libfoo.a",
            "FOO.RLIB",
        ] {
            assert!(
                is_crate_search_artifact(file_name),
                "{} should be linked into the unified dependency dir",
                file_name
            );
        }
    }

    fn parse_json(json_str: &str) -> Result<JsonValue, String> {
        json_str.parse::<JsonValue>().map_err(|e| e.to_string())
    }

    #[test]
    fn test_process_line_diagnostic_json() -> Result<(), String> {
        let LineOutput::Message(msg) = process_line(
            r#"
                {
                    "$message_type": "diagnostic",
                    "rendered": "Diagnostic message"
                }
            "#
            .to_string(),
            ErrorFormat::Json,
        )?
        else {
            return Err("Expected a LineOutput::Message".to_string());
        };
        assert_eq!(
            parse_json(&msg)?,
            parse_json(
                r#"
                {
                    "$message_type": "diagnostic",
                    "rendered": "Diagnostic message"
                }
            "#
            )?
        );
        Ok(())
    }

    #[test]
    fn test_process_line_diagnostic_rendered() -> Result<(), String> {
        let LineOutput::Message(msg) = process_line(
            r#"
                {
                    "$message_type": "diagnostic",
                    "rendered": "Diagnostic message"
                }
            "#
            .to_string(),
            ErrorFormat::Rendered,
        )?
        else {
            return Err("Expected a LineOutput::Message".to_string());
        };
        assert_eq!(msg, "Diagnostic message");
        Ok(())
    }

    #[test]
    fn test_process_line_noise() -> Result<(), String> {
        for text in [
            "'+zaamo' is not a recognized feature for this target (ignoring feature)",
            " WARN rustc_errors::emitter Invalid span...",
        ] {
            let LineOutput::Message(msg) = process_line(
                text.to_string(),
                ErrorFormat::Json,
            )?
            else {
                return Err("Expected a LineOutput::Message".to_string());
            };
            assert_eq!(
                parse_json(&msg)?,
                parse_json(&format!(
                    r#"{{
                        "$message_type": "diagnostic",
                        "message": "{0}",
                        "code": null,
                        "level": "warning",
                        "spans": [],
                        "children": [],
                        "rendered": "{0}"
                    }}"#,
                    text
                ))?
            );
        }
        Ok(())
    }

}
