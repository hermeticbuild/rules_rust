//! Resolve stable workspace stamps without making rustc depend on the stable status file.

use std::collections::HashMap;
use tinyjson::JsonValue;

pub(crate) fn resolve(args: impl Iterator<Item = String>) -> Result<(), String> {
    let mut args = args;
    let mut output = None;
    let mut env_files = Vec::new();
    let mut environment = HashMap::new();
    let mut stable = Vec::new();
    while let Some(flag) = args.next() {
        let value = args
            .next()
            .ok_or_else(|| format!("missing value for {flag}"))?;
        match flag.as_str() {
            "--output" => output = Some(value),
            "--env" => {
                let (key, content) = value.split_once('=').ok_or("--env requires KEY=VALUE")?;
                environment.insert(key.to_owned(), content.to_owned());
            }
            "--env-file" => env_files.push(value),
            "--stable-status-file" => stable = crate::util::read_stamp_status_to_array(value)?,
            _ => return Err(format!("unknown stamp environment flag: {flag}")),
        }
    }
    // Match process_wrapper's ordering: file values override the action env;
    // later files override earlier files. The compiler wrapper applies volatile
    // stamps after loading this file.
    environment.extend(crate::options::env_from_files(env_files).map_err(|e| e.to_string())?);
    let environment = resolve_environment(environment, stable.into_iter());
    let output = output.ok_or("missing --output")?;
    std::fs::write(output, encode(environment)?).map_err(|e| e.to_string())
}

fn resolve_environment(
    mut environment: HashMap<String, String>,
    mappings: impl Iterator<Item = (String, String)>,
) -> HashMap<String, String> {
    let original = environment.clone();
    substitute(&mut environment, mappings);
    // Keep the compiler action's own execution environment for unchanged keys.
    // In particular, remote executors can replace PATH with worker-local paths.
    // Serializing that environment here would leak this action's execroot.
    environment.retain(|key, value| original.get(key) != Some(value));
    environment
}

fn substitute(
    environment: &mut HashMap<String, String>,
    mappings: impl Iterator<Item = (String, String)>,
) {
    for (key, replacement) in mappings {
        let placeholder = format!("{{{key}}}");
        for value in environment.values_mut() {
            *value = value.replace(&placeholder, &replacement);
        }
    }
}

fn encode(environment: HashMap<String, String>) -> Result<String, String> {
    // Arrays give tinyjson deterministic ordering while preserving arbitrary
    // newlines, backslashes and quotes in values. Do not expand ${pwd} here.
    let mut pairs: Vec<_> = environment.into_iter().collect();
    pairs.sort_by(|a, b| a.0.cmp(&b.0));
    JsonValue::Array(
        pairs
            .into_iter()
            .map(|(k, v)| JsonValue::Array(vec![JsonValue::String(k), JsonValue::String(v)]))
            .collect(),
    )
    .stringify()
    .map_err(|e| e.to_string())
}

fn decode(contents: &str) -> Result<HashMap<String, String>, String> {
    let value: JsonValue = contents
        .parse()
        .map_err(|e| format!("invalid stamp environment: {e}"))?;
    let JsonValue::Array(pairs) = value else {
        return Err("stamp environment must be an array".to_owned());
    };
    let mut environment = HashMap::new();
    for pair in pairs {
        let JsonValue::Array(pair) = pair else {
            return Err("stamp environment entry must be a pair".to_owned());
        };
        match pair.as_slice() {
            [JsonValue::String(key), JsonValue::String(value)] => {
                environment.insert(key.clone(), value.clone());
            }
            _ => return Err("stamp environment entry must contain two strings".to_owned()),
        }
    }
    Ok(environment)
}

pub(crate) fn read_environment(path: &str) -> Result<HashMap<String, String>, String> {
    decode(&std::fs::read_to_string(path).map_err(|e| e.to_string())?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deterministic_lossless_encoding() {
        let pairs = [
            ("Z".to_owned(), "line 1\nline 2\\\"=x".to_owned()),
            ("A".to_owned(), "${pwd}/{UNKNOWN}".to_owned()),
        ];
        let forward = HashMap::from(pairs.clone());
        let backward = pairs.iter().cloned().rev().collect::<HashMap<_, _>>();
        let encoded = encode(forward.clone()).unwrap();
        assert_eq!(encoded, encode(backward).unwrap());
        assert_eq!(decode(&encoded).unwrap(), forward);
    }

    #[test]
    fn only_consumed_stamp_values_affect_output() {
        let original = HashMap::from([
            (
                "STAMP".to_owned(),
                "{STABLE_USED}/{VOLATILE_USED}".to_owned(),
            ),
            ("PATH".to_owned(), "${pwd}/{UNKNOWN}".to_owned()),
        ]);
        let resolve = |unused: &str| {
            let mut environment = original.clone();
            substitute(
                &mut environment,
                [
                    ("STABLE_USED".to_owned(), "release".to_owned()),
                    ("UNUSED".to_owned(), unused.to_owned()),
                ]
                .iter()
                .cloned(),
            );
            encode(environment).unwrap()
        };
        assert_eq!(resolve("before"), resolve("after"));
        let resolved = decode(&resolve("unused")).unwrap();
        assert_eq!(resolved["STAMP"], "release/{VOLATILE_USED}");
        assert_eq!(resolved["PATH"], "${pwd}/{UNKNOWN}");
    }

    #[test]
    fn unchanged_values_are_not_overridden() {
        let original = HashMap::from([
            ("PATH".to_owned(), "${pwd}/tools".to_owned()),
            ("STAMP".to_owned(), "{STABLE_USED}".to_owned()),
        ]);
        let resolved = resolve_environment(
            original,
            [("STABLE_USED".to_owned(), "release".to_owned())]
                .iter()
                .cloned(),
        );
        assert_eq!(
            resolved,
            HashMap::from([("STAMP".to_owned(), "release".to_owned())])
        );
    }

    #[test]
    fn unused_stamps_produce_an_empty_override() {
        let original = HashMap::from([("PATH".to_owned(), "${pwd}/tools".to_owned())]);
        assert!(resolve_environment(
            original,
            [("STABLE_UNUSED".to_owned(), "release".to_owned())]
                .iter()
                .cloned(),
        )
        .is_empty());
    }

    #[test]
    fn preserves_sequential_substitution_order() {
        let original = HashMap::from([("STAMP".to_owned(), "{FIRST}/{SECOND}".to_owned())]);
        let resolved = resolve_environment(
            original,
            [
                ("FIRST".to_owned(), "{SECOND}".to_owned()),
                ("SECOND".to_owned(), "release".to_owned()),
                ("SECOND".to_owned(), "volatile".to_owned()),
            ]
            .iter()
            .cloned(),
        );
        assert_eq!(resolved["STAMP"], "release/release");
    }

    #[test]
    fn rejects_invalid_resolver_arguments() {
        for args in [
            vec!["--unknown", "value"],
            vec!["--env", "missing-equals"],
            vec!["--output"],
            vec![],
        ] {
            assert!(resolve(args.into_iter().map(str::to_owned)).is_err());
        }
    }

    #[test]
    fn rejects_invalid_environment_records() {
        for input in ["{}", "[1]", "[[\"a\"]]", "[[\"a\",3]]"] {
            assert!(decode(input).is_err(), "{}", input);
        }
    }
}
