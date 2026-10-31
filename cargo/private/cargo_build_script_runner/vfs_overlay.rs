// Copyright 2026 The Bazel Authors. All rights reserved.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// https://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! Action-local copies of JSON VFS overlays for cwd-changing build scripts.
//!
//! Opt-in only. This is not a YAML parser. Ordinary compiler actions and their
//! dependency files retain the original overlays and execroot-relative names.

use std::collections::HashMap;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use tinyjson::JsonValue;

fn absolute(path: &str) -> bool {
    let b = path.as_bytes();
    path.starts_with('/')
        || path.starts_with("\\\\")
        || (b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':'
            && matches!(b[2], b'/' | b'\\'))
}

fn anchored(path: &str, base: &Path) -> Result<String, String> {
    if cfg!(windows) && !absolute(path)
        && (path.starts_with('\\') || path.as_bytes().get(1) == Some(&b':')) {
        return Err("Windows rooted or drive-relative VFS paths are not supported".into());
    }
    if absolute(path) {
        Ok(path.to_owned())
    } else {
        Ok(base.join(path).to_string_lossy().into_owned())
    }
}

fn boolean(value: Option<&JsonValue>, default: bool) -> Result<bool, String> {
    match value {
        None => Ok(default),
        Some(JsonValue::Boolean(value)) => Ok(*value),
        Some(JsonValue::Number(value)) if *value == 0.0 => Ok(false),
        Some(JsonValue::Number(value)) if *value == 1.0 => Ok(true),
        Some(JsonValue::String(value)) => match value.to_ascii_lowercase().as_str() {
            "true" | "yes" | "on" | "1" => Ok(true),
            "false" | "no" | "off" | "0" => Ok(false),
            _ => Err("invalid VFS boolean".into()),
        },
        _ => Err("invalid VFS boolean".into()),
    }
}

fn rewrite_entry(
    entry: &mut JsonValue,
    root_base: &Path,
    external_base: &Path,
    is_root: bool,
    overlay_relative: bool,
) -> Result<(), String> {
    let object = entry.get_mut::<HashMap<String, JsonValue>>()
        .ok_or("expected VFS entry object")?;
    if is_root {
        let name = object.get_mut("name").and_then(JsonValue::get_mut::<String>)
            .ok_or("expected VFS root name")?;
        *name = anchored(name, root_base)?;
    }
    if let Some(external) = object.get_mut("external-contents") {
        let external = external.get_mut::<String>().ok_or("expected VFS external path")?;
        // LLVM prefixes even absolute paths when overlay-relative=true.
        // Reject that unusual form rather than silently changing its meaning.
        if overlay_relative && absolute(external) {
            return Err("overlay-relative=true with an absolute external path is not supported".into());
        }
        *external = anchored(external, external_base)?;
    }
    if let Some(contents) = object.get_mut("contents") {
        let contents = contents.get_mut::<Vec<JsonValue>>().ok_or("expected VFS contents array")?;
        for child in contents {
            rewrite_entry(child, root_base, external_base, false, overlay_relative)?;
        }
    }
    Ok(())
}

/// Preserve the original lookup bases, not the temporary overlay's directory.
/// No canonicalize(): execution inputs may be symlinks into a shared CAS.
pub fn rebase_json(source: &str, original: &Path, exec_root: &Path) -> Result<String, String> {
    let mut document: JsonValue = source.parse().map_err(|error| format!(
        "cargo-rebase-json-vfs-overlays requires JSON overlays, not arbitrary YAML: {error}"
    ))?;
    let object = document.get_mut::<HashMap<String, JsonValue>>().ok_or("expected VFS object")?;
    if object.get("version") != Some(&JsonValue::Number(0.0)) {
        return Err("only VFS overlay version 0 is supported".into());
    }
    let original_dir = original.parent().ok_or("overlay has no parent directory")?;
    let root_base = match object.get("root-relative") {
        None => exec_root,
        Some(JsonValue::String(value)) if value.eq_ignore_ascii_case("cwd") => exec_root,
        Some(JsonValue::String(value)) if value.eq_ignore_ascii_case("overlay-dir") => original_dir,
        _ => return Err("unknown VFS root-relative mode".into()),
    };
    let overlay_relative = boolean(object.get("overlay-relative"), false)?;
    let external_base = if overlay_relative { original_dir } else { exec_root };
    let roots = object.get_mut("roots").and_then(JsonValue::get_mut::<Vec<JsonValue>>)
        .ok_or("expected VFS roots array")?;
    for root in roots {
        rewrite_entry(root, root_base, external_base, true, overlay_relative)?;
    }
    object.insert("root-relative".into(), JsonValue::String("cwd".into()));
    object.insert("overlay-relative".into(), JsonValue::Boolean(false));
    document.stringify().map_err(|error| error.to_string())
}

/// Files owned exclusively by this invocation; remove before capturing OUT_DIR.
#[derive(Default)]
pub struct PreparedOverlays(Vec<PathBuf>);

impl PreparedOverlays {
    pub fn from_env(exec_root: &Path, out_dir: &Path) -> Result<Self, String> {
        let mut prepared = Self::default();
        let Some(mapping) = env::var_os("RULES_RUST_JSON_VFS_OVERLAYS") else {
            return Ok(prepared);
        };
        let mapping: JsonValue = mapping.to_str().ok_or("VFS mapping is not UTF-8")?
            .parse().map_err(|error| format!("invalid VFS mapping: {error}"))?;
        let mapping = mapping.get::<HashMap<String, JsonValue>>().ok_or("expected VFS mapping object")?;
        for (source, destination) in mapping {
            let source = exec_root.join(source);
            let destination = exec_root.join(destination.get::<String>().ok_or("expected VFS output path")?);
            if destination.parent() != Some(out_dir)
                || !destination.file_name().and_then(|name| name.to_str()).is_some_and(|name| name.starts_with(".rules_rust_vfs_")) {
                return Err("VFS copy must be a runner-owned file directly inside OUT_DIR".into());
            }
            let contents = fs::read_to_string(&source).map_err(|error| format!("{}: {error}", source.display()))?;
            let contents = rebase_json(&contents, &source, exec_root)
                .map_err(|error| format!("{}: {error}", source.display()))?;
            let mut file = OpenOptions::new().write(true).create_new(true).open(&destination)
                .map_err(|error| format!("{}: {error}", destination.display()))?;
            prepared.0.push(destination);
            file.write_all(contents.as_bytes()).map_err(|error| error.to_string())?;
        }
        Ok(prepared)
    }

    pub fn remove(mut self) -> Result<(), String> {
        for path in &self.0 {
            fs::remove_file(path).map_err(|error| format!("{}: {error}", path.display()))?;
        }
        self.0.clear();
        Ok(())
    }
}

impl Drop for PreparedOverlays {
    fn drop(&mut self) {
        for path in &self.0 {
            let _ = fs::remove_file(path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rewrite(source: &str) -> JsonValue {
        rebase_json(source, Path::new("/exec/overlays/headers.json"), Path::new("/exec"))
            .unwrap().parse().unwrap()
    }

    fn assert_path(value: &JsonValue, expected: &str) {
        assert_eq!(Path::new(value.get::<String>().unwrap()), Path::new(expected));
    }

    #[test]
    fn cwd_relative_roots_and_external_paths_become_absolute() {
        let value = rewrite(r#"{"version":0,"case-sensitive":false,"roots":[
            {"type":"directory","name":"SDK space","contents":[
                {"type":"file","name":"Header.H","external-contents":"SDK space/header.h"}]}]}"#);
        assert_path(&value["roots"][0]["name"], "/exec/SDK space");
        assert_eq!(value["roots"][0]["contents"][0]["name"], JsonValue::String("Header.H".into()));
        assert_path(&value["roots"][0]["contents"][0]["external-contents"], "/exec/SDK space/header.h");
        assert_eq!(value["case-sensitive"], JsonValue::Boolean(false));
    }

    #[test]
    fn overlay_directory_bases_refer_to_original_not_copy() {
        let value = rewrite(r#"{"version":0,"root-relative":"overlay-dir","overlay-relative":true,
            "use-external-names":false,"redirecting-with":"fallback","roots":[
            {"type":"directory-remap","name":"virtual","external-contents":"real"}]}"#);
        assert_path(&value["roots"][0]["name"], "/exec/overlays/virtual");
        assert_path(&value["roots"][0]["external-contents"], "/exec/overlays/real");
        assert_eq!(value["use-external-names"], JsonValue::Boolean(false));
        assert_eq!(value["redirecting-with"], JsonValue::String("fallback".into()));
        assert_eq!(value["overlay-relative"], JsonValue::Boolean(false));
    }

    #[test]
    fn absolute_roots_and_external_paths_are_preserved() {
        let value = rewrite(r#"{"version":0,"roots":[{"type":"file","name":"C:/sdk/Header.h",
            "external-contents":"/physical/Header.h","use-external-name":false}]}"#);
        assert_eq!(value["roots"][0]["name"], JsonValue::String("C:/sdk/Header.h".into()));
        assert_eq!(value["roots"][0]["external-contents"], JsonValue::String("/physical/Header.h".into()));
        assert_eq!(value["roots"][0]["use-external-name"], JsonValue::Boolean(false));
    }

    #[test]
    fn unsupported_forms_fail_explicitly() {
        for source in [
            "version: 0\nroots: []",
            r#"{"version":1,"roots":[]}"#,
            r#"{"version":0,"root-relative":"unknown","roots":[]}"#,
            r#"{"version":0,"overlay-relative":true,"roots":[{"type":"file","name":"f","external-contents":"/f"}]}"#,
        ] {
            assert!(rebase_json(source, Path::new("/exec/o.json"), Path::new("/exec")).is_err());
        }
    }

    #[test]
    fn llvm_numeric_boolean_spellings_are_accepted() {
        for (value, expected) in [(0.0, false), (1.0, true)] {
            assert_eq!(boolean(Some(&JsonValue::Number(value)), false), Ok(expected));
        }
    }

    #[test]
    #[cfg(windows)]
    fn ambiguous_windows_paths_are_rejected() {
        for path in [r"\sdk", "C:sdk"] {
            assert!(anchored(path, Path::new(r"C:\exec")).is_err());
        }
    }
}
