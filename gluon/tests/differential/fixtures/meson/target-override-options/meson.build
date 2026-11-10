project('target-override-options', 'c', 'cpp', default_options: ['c_std=c99', 'cpp_std=c++17'])
executable('newer', 'newer.cpp', 'newer.c', override_options: ['cpp_std=c++20', 'c_std=c11'])
executable('older', 'older.cpp')
