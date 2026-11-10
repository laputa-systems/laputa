#if __cplusplus < 202002L
#error cpp_std override ignored
#endif
extern "C" int c_part(void);
int main() { return c_part(); }
