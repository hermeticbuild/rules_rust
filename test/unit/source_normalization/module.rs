macro_rules! value {
    (/// This is ignored in a macro matcher, unlike a doc attribute.
     literal) => {
        42
    };
}

pub fn value() -> u32 {
    value!(literal)
}
