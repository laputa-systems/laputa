#if !defined(FROM_C_OPTION) || defined(FROM_CPP_OPTION)
#error wrong C option arguments
#endif
extern char linked_marker;
int helper(void);
int main(void) { return helper() + (&linked_marker == 0); }
