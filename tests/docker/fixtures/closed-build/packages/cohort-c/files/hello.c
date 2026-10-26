#include <emmintrin.h>
#include <stdio.h>
int main(void) {
    __m128i value = _mm_set1_epi32(7);
    __m128i doubled = _mm_add_epi32(value, value);
    if (_mm_cvtsi128_si32(doubled) != 14) return 1;
    puts("declared C payload");
    return 0;
}
