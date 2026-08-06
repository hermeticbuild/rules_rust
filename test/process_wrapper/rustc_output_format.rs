#[cfg(test)]
mod test {
    use std::fs;
    use std::path::PathBuf;
    use std::process::{Command, Output};
    use std::str;

    use runfiles::Runfiles;

    fn run_fake_rustc(process_wrapper_args: &[&str], fake_rustc_args: &[&str]) -> Output {
        let r = Runfiles::create().unwrap();
        let fake_rustc = runfiles::rlocation!(r, env!("FAKE_RUSTC_RLOCATIONPATH")).unwrap();

        let process_wrapper =
            runfiles::rlocation!(r, env!("PROCESS_WRAPPER_RLOCATIONPATH")).unwrap();

        Command::new(process_wrapper)
            .args(process_wrapper_args)
            .arg("--")
            .arg(fake_rustc)
            .args(fake_rustc_args)
            .output()
            .unwrap()
    }

    /// Run `fake_rustc` under `process_wrapper` and return stderr.
    fn fake_rustc(
        process_wrapper_args: &[&str],
        fake_rustc_args: &[&str],
        should_succeed: bool,
    ) -> String {
        let output = run_fake_rustc(process_wrapper_args, fake_rustc_args);

        if should_succeed {
            assert!(
                output.status.success(),
                "unable to run process_wrapper: {} {}",
                str::from_utf8(&output.stdout).unwrap(),
                str::from_utf8(&output.stderr).unwrap(),
            );
        }

        String::from_utf8(output.stderr).unwrap()
    }

    fn artifact_path(name: &str) -> PathBuf {
        PathBuf::from(std::env::var_os("TEST_TMPDIR").expect("TEST_TMPDIR is not set")).join(name)
    }

    fn write_artifact(name: &str, contents: &[u8]) -> PathBuf {
        let path = artifact_path(name);
        fs::write(&path, contents).unwrap();
        path
    }

    fn working_dir() -> PathBuf {
        std::env::current_dir().expect("unable to read current working directory")
    }

    fn assert_stderr_contains_path(stderr: &str, path: &str) {
        assert!(
            stderr.contains(&path.escape_debug().to_string()),
            "missing path {}: {}",
            path,
            stderr,
        );
    }

    #[test]
    fn test_rustc_output_format_rendered() {
        let out_content = fake_rustc(&["--rustc-output-format", "rendered"], &[], true);
        assert!(
            out_content.contains("should be\nin output"),
            "output should contain the first rendered message",
        );
        assert!(
            out_content.contains("should not be in output"),
            "output should contain the second rendered message",
        );
        assert!(
            !out_content.contains(r#""rendered""#),
            "rendered mode should not print raw json",
        );
    }

    #[test]
    fn test_rustc_output_format_json() {
        let json_content = fake_rustc(&["--rustc-output-format", "json"], &[], true);
        assert_eq!(
            json_content,
            concat!(
                r#"{"rendered": "should be\nin output"}"#,
                "\n",
                r#"{"rendered": "should not be in output"}"#,
                "\n"
            )
        );
    }

    #[test]
    fn test_rustc_panic() {
        let rendered_content = fake_rustc(&["--rustc-output-format", "json"], &["error"], false);
        assert_eq!(
            rendered_content,
            r#"{"rendered": "should be\nin output"}
ERROR!
this should all
appear in output.
Error: ProcessWrapperError("failed to process stderr: error parsing rustc output as json")
"#
        );
    }

    #[test]
    fn test_working_dir_in_binary_artifact_is_rejected() {
        let working_dir = working_dir();
        let working_dir = working_dir.to_str().unwrap();
        let artifact = write_artifact("working-dir-present", working_dir.as_bytes());
        let artifact_name = artifact.to_str().unwrap();

        let output = run_fake_rustc(&["--check-output-for-working-dir", artifact_name], &[]);
        let stderr = String::from_utf8(output.stderr).unwrap();

        assert!(
            !output.status.success(),
            "embedded current working directory was accepted"
        );
        assert_stderr_contains_path(&stderr, working_dir);
        assert_stderr_contains_path(&stderr, artifact_name);
    }

    #[test]
    fn test_relative_paths_in_binary_artifact_are_allowed() {
        let artifact = write_artifact("relative-present", b"relative/crate/package");

        let output = run_fake_rustc(
            &["--check-output-for-working-dir", artifact.to_str().unwrap()],
            &[],
        );

        assert!(
            output.status.success(),
            "artifact containing only relative paths was rejected: {}",
            String::from_utf8_lossy(&output.stderr),
        );
    }

    #[test]
    fn test_working_dir_derived_out_dir_in_binary_artifact_is_rejected() {
        let out_dir = working_dir().join("bazel-out/cfg/bin/package/build_script.out_dir");
        let artifact = write_artifact("out-dir-present", out_dir.to_str().unwrap().as_bytes());
        let artifact_name = artifact.to_str().unwrap();

        let output = run_fake_rustc(&["--check-output-for-working-dir", artifact_name], &[]);
        let stderr = String::from_utf8(output.stderr).unwrap();

        assert!(
            !output.status.success(),
            "working-directory-derived OUT_DIR was accepted"
        );
        assert_stderr_contains_path(&stderr, artifact_name);
    }

    #[test]
    fn test_repeated_checked_outputs_reject_embedded_working_dir() {
        let working_dir = working_dir();
        let working_dir = working_dir.to_str().unwrap();
        let clean_artifact = write_artifact("repeated-clean", b"\0artifact without a path\xff");
        let rejected_artifact = write_artifact("repeated-rejected", working_dir.as_bytes());
        let rejected_name = rejected_artifact.to_str().unwrap();

        let output = run_fake_rustc(
            &[
                "--check-output-for-working-dir",
                clean_artifact.to_str().unwrap(),
                "--check-output-for-working-dir",
                rejected_name,
            ],
            &[],
        );
        let stderr = String::from_utf8(output.stderr).unwrap();

        assert!(
            !output.status.success(),
            "embedded current working directory in second artifact was accepted"
        );
        assert_stderr_contains_path(&stderr, rejected_name);
    }

    #[test]
    fn test_failed_child_does_not_check_missing_artifact() {
        let missing_artifact = artifact_path("missing-after-failure");
        let missing_name = missing_artifact.to_str().unwrap();

        let output = run_fake_rustc(
            &["--check-output-for-working-dir", missing_name],
            &["error"],
        );
        let stderr = String::from_utf8(output.stderr).unwrap();

        assert!(
            !output.status.success(),
            "failed child process was accepted"
        );
        assert!(
            stderr.contains("ERROR!"),
            "missing child process failure: {}",
            stderr
        );
        assert!(
            !stderr.contains(missing_name),
            "missing artifact masked the child process failure: {}",
            stderr
        );
    }
}
