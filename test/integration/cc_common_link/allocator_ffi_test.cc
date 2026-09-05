#include <stddef.h>

extern "C" size_t allocate_and_sum(size_t count);

int main() { return allocate_and_sum(10) == 45 ? 0 : 1; }
