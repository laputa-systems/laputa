project('cpp-builtin-options', 'c', 'cpp',
  default_options: [
    'cpp_rtti=false',
    'cpp_eh=none',
    'c_args=-DFROM_C_OPTION',
    'cpp_args=-DFROM_CPP_OPTION',
    'cpp_link_args=-Wl,--defsym=linked_marker=0',
  ])
executable('prog', 'main.c', 'helper.cpp')
