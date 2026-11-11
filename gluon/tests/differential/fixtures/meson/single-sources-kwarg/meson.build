project('single-sources-kwarg', 'c')

lib = static_library('answer', sources: 'lib.c')
executable('use', sources: 'main.c', link_with: lib)
