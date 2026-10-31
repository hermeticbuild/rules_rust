fn main() {
    assert!(cfg!(build_script_only));
    assert!(std::env::var("CARGO_CFG_TARGET_FEATURE")
        .unwrap()
        .split(',')
        .any(|feature| feature == "crt-static"));
    assert!(std::env::var_os("CARGO_CFG_BUILD_SCRIPT_ONLY").is_none());
}
