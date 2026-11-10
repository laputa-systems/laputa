#include "config.h"

int LLVM_VERSION_SYMBOL;
int LLVM_RTTI_SYMBOL;

#ifdef NDEBUG
int ndebug_reached_compile;
#endif
#ifdef LLVM_FROM_CPPFLAGS
int llvm_cppflags_used;
#endif
#ifdef LLVM_FROM_CFLAGS
int llvm_cflags_used;
#endif
#if LLVM_MISSING_FOUND
int llvm_missing_module_found;
#endif

int main(void) { return 0; }
