#if defined(__GXX_RTTI) || defined(__cpp_rtti)
#error cpp_rtti=false ignored
#endif
#if defined(__EXCEPTIONS) || defined(__cpp_exceptions)
#error cpp_eh=none ignored
#endif
#if !defined(FROM_CPP_OPTION) || defined(FROM_C_OPTION)
#error wrong C++ option arguments
#endif
extern "C" int helper(void) { return 0; }
