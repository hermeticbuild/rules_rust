#[cfg(target_os = "linux")]
fn main() {
    use std::os::unix::process::ExitStatusExt;
    use std::process::Command;

    const CHILD_ENV: &str = "RULES_RUST_PANIC_ABORT_CHILD";
    if std::env::var_os(CHILD_ENV).is_some() {
        panic!("the configured panic strategy must abort this child process");
    }

    let status = Command::new(std::env::current_exe().unwrap())
        .env(CHILD_ENV, "1")
        .status()
        .unwrap();
    assert_eq!(status.signal(), Some(6), "expected SIGABRT, got {status:?}");
}

#[cfg(not(target_os = "linux"))]
fn main() {
    panic!("this test is Linux-only");
}
