//! The build script's `RUSTC` found the standard library.

#[test]
fn build_script_rustc_found_std() {
    assert!(!env!("RUSTC_FOUND_STD").is_empty());
}
