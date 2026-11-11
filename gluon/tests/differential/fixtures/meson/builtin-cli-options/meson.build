project('builtin-cli-options', 'c')

assert(get_option('buildtype') == 'release', 'buildtype')
assert(get_option('optimization') == '3', 'optimization')
assert(get_option('debug') == false, 'debug')
assert(get_option('prefix') == '/gluon-diff-prefix', 'prefix')
assert(get_option('libdir') == 'lib64', 'libdir')
assert(get_option('default_library') == 'shared', 'default_library')
assert(get_option('warning_level') == '1', 'warning_level')

executable('app', 'main.c')
