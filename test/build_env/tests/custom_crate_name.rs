#[test]
fn cargo_env_vars() {
    assert_eq!(env!("CARGO_PKG_AUTHORS"), "");
    assert_eq!(env!("CARGO_PKG_DESCRIPTION"), "");
    assert_eq!(env!("CARGO_PKG_HOMEPAGE"), "");
    assert_eq!(env!("CARGO_PKG_NAME"), "cargo_pkg_env_test");
    assert_eq!(env!("CARGO_PKG_VERSION"), "1.2.3-alpha.1+build.5");
    assert_eq!(env!("CARGO_PKG_VERSION_MAJOR"), "1");
    assert_eq!(env!("CARGO_PKG_VERSION_MINOR"), "2");
    assert_eq!(env!("CARGO_PKG_VERSION_PATCH"), "3");
    assert_eq!(env!("CARGO_PKG_VERSION_PRE"), "alpha.1");
    assert_eq!(env!("CARGO_CRATE_NAME"), "custom_crate_name");
}
