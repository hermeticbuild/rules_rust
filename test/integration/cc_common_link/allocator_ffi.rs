#[no_mangle]
pub extern "C" fn allocate_and_sum(count: usize) -> usize {
    let values: Vec<usize> = (0..count).collect();
    std::hint::black_box(&values);
    values.iter().sum()
}

#[test]
fn heap_allocation() {
    assert_eq!(allocate_and_sum(10), 45);
}
