//! This binary mocks the output of rustc when run with `--error-format=json` and `--json=artifacts`.

fn main() {
    eprintln!(r#"{{"rendered": "should be\nin output"}}"#);
    match std::env::args().nth(1).as_deref() {
        Some("error") => {
            eprintln!("ERROR!\nthis should all\nappear in output.");
            std::process::exit(1);
        }
        Some("exit-137") => std::process::exit(137),
        #[cfg(unix)]
        Some("abort") => std::process::abort(),
        _ => {}
    }
    eprintln!(r#"{{"emit": "metadata"}}"#);
    std::thread::sleep(std::time::Duration::from_secs(1));
    eprintln!(r#"{{"rendered": "should not be in output"}}"#);
}
