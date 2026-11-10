int internal_helper(int x) { return x + 1; }
__attribute__((visibility("default"))) int exported(int x) { return internal_helper(x); }
