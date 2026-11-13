fn main() {
    assert_eq!(
        include_str!(concat!(env!("OUT_DIR"), "/stamp-marker.txt")),
        "marker"
    );
    println!("{}", env!("STAMP"));
}
