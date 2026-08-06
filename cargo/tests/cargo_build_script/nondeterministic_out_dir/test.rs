//! include_str! resolves at compile time against the TreeArtifact captured by Bazel.
//! If the runner failed to strip config.log / *.d / *.pc files, the TreeArtifact hash
//! would change on every run, causing unnecessary rebuilds for all downstream crates.

use std::path::PathBuf;

const OUTPUT: &str = include_str!(concat!(env!("OUT_DIR"), "/output.txt"));

fn build_script_out_dir() -> PathBuf {
    let runfiles = runfiles::Runfiles::create().expect("unable to resolve test runfiles");
    let out_dir = std::env::var("BUILD_SCRIPT_OUT_DIR").expect("BUILD_SCRIPT_OUT_DIR is not set");
    runfiles::rlocation!(runfiles, &out_dir).expect("unable to resolve build script OUT_DIR")
}

#[test]
fn legitimate_output_survives_nondeterministic_file_removal() {
    assert_eq!(OUTPUT, "legitimate output");
    assert_eq!(
        std::fs::read_to_string(build_script_out_dir().join("output.txt")).unwrap(),
        OUTPUT,
    );
}

// Verify that volatile files written by the build script are absent from the
// captured OUT_DIR TreeArtifact. The build script wrote each of these; the
// cargo_build_script_runner must have removed them before Bazel snapshotted
// the directory.

#[test]
fn config_log_removed() {
    assert!(
        !build_script_out_dir().join("config.log").exists(),
        "config.log should have been removed from OUT_DIR"
    );
}

#[test]
fn config_status_removed() {
    assert!(
        !build_script_out_dir().join("config.status").exists(),
        "config.status should have been removed from OUT_DIR"
    );
}

#[test]
fn makefile_removed() {
    assert!(
        !build_script_out_dir().join("Makefile").exists(),
        "Makefile should have been removed from OUT_DIR"
    );
}

#[test]
fn makefile_config_removed() {
    assert!(
        !build_script_out_dir().join("Makefile.config").exists(),
        "Makefile.config should have been removed from OUT_DIR"
    );
}

#[test]
fn config_cache_removed() {
    assert!(
        !build_script_out_dir().join("config.cache").exists(),
        "config.cache should have been removed from OUT_DIR"
    );
}

#[test]
fn dot_d_files_removed() {
    assert!(
        !build_script_out_dir().join("foo.d").exists(),
        "foo.d should have been removed from OUT_DIR"
    );
    assert!(
        !build_script_out_dir().join("baz.d").exists(),
        "baz.d should have been removed from OUT_DIR"
    );
}

#[test]
fn dot_pc_file_removed() {
    assert!(
        !build_script_out_dir().join("foo.pc").exists(),
        "foo.pc should have been removed from OUT_DIR"
    );
}
