use std::os::unix::process::ExitStatusExt;
use std::process::Command;

fn main() {
    if std::env::args().any(|arg| arg == "--panic-child") {
        panic!("panic=abort runtime probe");
    }
    let status = Command::new(std::env::current_exe().unwrap())
        .arg("--panic-child")
        .status()
        .unwrap();
    assert_eq!(status.signal(), Some(6), "expected SIGABRT: {status}");
}
