use anyhow::{Context, Result, bail, ensure};
use std::{
    collections::HashMap,
    env,
    ffi::OsString,
    fs,
    path::{Component, Path, PathBuf},
};

fn main() -> Result<()> {
    let mut args: Vec<_> = env::args_os().skip(1).collect();
    if args.len() == 1
        && let Some(path) = args[0].to_str().and_then(|arg| arg.strip_prefix('@'))
    {
        args = fs::read_to_string(path)
            .with_context(|| format!("reading argument file {path}"))?
            .lines()
            .map(OsString::from)
            .collect();
    }
    let (output, inputs) = args.split_first().context(
        "usage: rust-source-normalize OUTPUT_DIR [copy|normalize INPUT RELATIVE_PATH ...]",
    )?;
    let (inputs, trailing) = inputs.as_chunks::<3>();
    ensure!(
        trailing.is_empty(),
        "expected MODE INPUT RELATIVE_PATH triples"
    );
    fs::create_dir_all(output)?;
    let mut sources = HashMap::new();
    for [mode, input, relative] in inputs {
        let normalize = match mode.to_str() {
            Some("copy") => false,
            Some("normalize") => true,
            _ => bail!("unknown input mode {mode:?}"),
        };
        let relative = Path::new(relative);
        ensure!(
            relative
                .components()
                .all(|c| matches!(c, Component::Normal(_) | Component::CurDir)),
            "expected a path within the output directory: {relative:?}"
        );
        stage(
            Path::new(input),
            &Path::new(output).join(relative),
            normalize,
            &mut sources,
        )
        .with_context(|| format!("staging {input:?}"))?;
    }
    Ok(())
}

fn stage(
    input: &Path,
    output: &Path,
    normalize: bool,
    sources: &mut HashMap<PathBuf, PathBuf>,
) -> Result<()> {
    if input.is_dir() {
        fs::create_dir_all(output)?;
        for entry in fs::read_dir(input)? {
            let entry = entry?;
            stage(
                &entry.path(),
                &output.join(entry.file_name()),
                normalize,
                sources,
            )?;
        }
    } else {
        if let Some(previous) = sources.insert(output.to_owned(), input.to_owned()) {
            ensure!(
                previous == input,
                "conflicting sources {previous:?} and {input:?} for {output:?}"
            );
            // A copied asset may be read-only; replace it when normalizing an overlap.
            fs::remove_file(output)?;
        }
        fs::create_dir_all(output.parent().context("output has no parent")?)?;
        if normalize && input.extension().is_some_and(|ext| ext == "rs") {
            let source = fs::read_to_string(input)?;
            // Source globs can contain templates or Rust fragments. Leave files
            // syn cannot parse for rustc to interpret if they are actually used.
            let normalized = rust_source_normalize::normalize(&source).unwrap_or(source);
            fs::write(output, normalized)?;
        } else {
            fs::copy(input, output)?;
        }
    }
    Ok(())
}
