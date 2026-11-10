#if !defined(ONLY_C) || defined(ONLY_CPP) || !defined(BOTH)
#error wrong C arguments
#endif
int helper(void);
int main(void) { return helper(); }
