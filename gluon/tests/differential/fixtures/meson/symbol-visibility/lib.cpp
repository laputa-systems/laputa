struct Counter { int next(int x) { return x + 1; } };
int internal_helper(int x) { return Counter().next(x); }
__attribute__((visibility("default"))) int exported(int x) { return internal_helper(x); }
