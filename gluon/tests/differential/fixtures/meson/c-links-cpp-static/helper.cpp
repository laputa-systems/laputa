extern "C" int helper(void) { try { throw 1; } catch (int) { return 0; } }
