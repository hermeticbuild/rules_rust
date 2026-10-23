#![deny(unused_braces)]

mod module;

pub fn message() -> &'static str {
    assert_eq!(module::value(), 42);
    assert_eq!(
        include_str!("message.txt"),
        include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/message.txt")),
    );
    include_str!("message.txt")
}
