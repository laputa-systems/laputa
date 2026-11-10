#if defined(ONLY_C) || !defined(ONLY_CPP) || !defined(BOTH)
#error wrong C++ arguments
#endif
extern "C" int helper(void) { return 0; }
