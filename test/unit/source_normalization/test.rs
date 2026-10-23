#[test]
fn normalized_library_preserves_modules_assets_and_macros() {
    assert_eq!(library::message(), "hello\n");
}
