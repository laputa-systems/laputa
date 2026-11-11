project('cmake-probe-cwd', 'c')
dep = dependency('gluon_absent_package', method: 'cmake', required: false)
assert(not dep.found())
executable('app', 'main.c')
