project('install-fixture-rpath', 'c', version : '2.3.4')

foo = shared_library(
  'foo',
  'foo.c',
  version : '2.3.4',
  soversion : '2',
  install : true,
)

app = executable(
  'app',
  'main.c',
  link_with : foo,
  install : true,
  install_rpath : '/opt/install-rpath/lib',
)
