//! Tests for the bootstrap process wrapper.

use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;

use runfiles::Runfiles;

fn resolve_runfile(env_var: &str) -> String {
    let rfiles = Runfiles::create().unwrap();
    let rlocationpath = env::var(env_var).unwrap();
    runfiles::rlocation!(rfiles, rlocationpath.as_str())
        .unwrap()
        .display()
        .to_string()
}

#[test]
fn test_substitutes_pwd() {
    let wrapper = resolve_runfile("BOOTSTRAP_PROCESS_WRAPPER_RLOCATIONPATH");
    let probe = resolve_runfile("BOOTSTRAP_PROCESS_WRAPPER_PROBE_RLOCATIONPATH");
    let pwd = env::current_dir().unwrap().display().to_string();

    let output = Command::new(&wrapper)
        .arg("--")
        .arg(&probe)
        .arg("${pwd}/suffix")
        .output()
        .unwrap();

    assert!(
        output.status.success(),
        "wrapper failed: status={:?}, stderr={}",
        output.status,
        String::from_utf8_lossy(&output.stderr),
    );

    let stdout = String::from_utf8(output.stdout).unwrap();
    assert_eq!(stdout.trim_end(), format!("{}/suffix", pwd));
}

#[test]
fn test_substitutes_response_file_placeholders() {
    let wrapper = resolve_runfile("BOOTSTRAP_PROCESS_WRAPPER_RLOCATIONPATH");
    let probe = resolve_runfile("BOOTSTRAP_PROCESS_WRAPPER_PROBE_RLOCATIONPATH");
    let response_file_dir = Path::new(&env::var_os("TEST_TMPDIR").unwrap()).join("response files");
    fs::create_dir_all(&response_file_dir).unwrap();
    let response_file = response_file_dir.join("rustc.params");
    let response_file_contents =
        "pwd=${pwd}\r\noutput_base=${output_base}\r\nexec_root=${exec_root}\r\n";
    fs::write(&response_file, response_file_contents).unwrap();

    let expand_direct_arg = |arg: &str| {
        let output = Command::new(&wrapper)
            .arg("--")
            .arg(&probe)
            .arg(arg)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "wrapper failed: status={:?}, stderr={}",
            output.status,
            String::from_utf8_lossy(&output.stderr),
        );
        String::from_utf8(output.stdout)
            .unwrap()
            .lines()
            .next()
            .unwrap()
            .to_owned()
    };
    let expected_contents = format!(
        "pwd={}\r\noutput_base={}\r\nexec_root={}\r\n",
        expand_direct_arg("${pwd}"),
        expand_direct_arg("${output_base}"),
        expand_direct_arg("${exec_root}"),
    );

    let output = Command::new(&wrapper)
        .arg("--")
        .arg(&probe)
        .arg(format!("@{}", response_file.display()))
        .output()
        .unwrap();

    assert!(
        output.status.success(),
        "wrapper failed: status={:?}, stderr={}",
        output.status,
        String::from_utf8_lossy(&output.stderr),
    );

    let stdout = String::from_utf8(output.stdout).unwrap();
    let expanded_file = stdout.trim_end().strip_prefix('@').unwrap();
    assert_eq!(
        expanded_file,
        format!("{}.expanded", response_file.display()),
    );

    let expanded_contents = fs::read_to_string(expanded_file).unwrap();
    assert_eq!(expanded_contents, expected_contents);
    assert!(!expanded_contents.contains("${"));
    assert_eq!(
        fs::read_to_string(&response_file).unwrap(),
        response_file_contents
    );
}

#[test]
fn test_reports_missing_response_file() {
    let wrapper = resolve_runfile("BOOTSTRAP_PROCESS_WRAPPER_RLOCATIONPATH");
    let probe = resolve_runfile("BOOTSTRAP_PROCESS_WRAPPER_PROBE_RLOCATIONPATH");
    let response_file = Path::new(&env::var_os("TEST_TMPDIR").unwrap()).join("missing.params");

    let output = Command::new(wrapper)
        .arg("--")
        .arg(probe)
        .arg(format!("@{}", response_file.display()))
        .output()
        .unwrap();

    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("failed to open response file"));
}

#[test]
fn test_propagates_exit_code() {
    let wrapper = resolve_runfile("BOOTSTRAP_PROCESS_WRAPPER_RLOCATIONPATH");
    let probe = resolve_runfile("BOOTSTRAP_PROCESS_WRAPPER_PROBE_RLOCATIONPATH");

    let status = Command::new(wrapper)
        .arg("--")
        .arg(probe)
        .env("BOOTSTRAP_PROCESS_WRAPPER_PROBE_EXIT_CODE", "23")
        .status()
        .unwrap();

    assert_eq!(status.code(), Some(23));
}
