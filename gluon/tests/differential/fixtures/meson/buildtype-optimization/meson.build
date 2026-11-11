project('buildtype-optimization', 'c')

assert(get_option('buildtype') == 'debugoptimized', 'buildtype')
assert(get_option('optimization') == '2', 'optimization')
assert(get_option('debug') == true, 'debug')

executable('app', 'main.c')
