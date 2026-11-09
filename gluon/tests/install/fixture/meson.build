project('install-fixture', 'c', version : '2.3.4')

install_headers('include/foo/foo.h', subdir : 'foo')

foo = shared_library(
  'foo',
  'foo.c',
  version : '2.3.4',
  soversion : '2',
  install : true,
)

pkgconfig = import('pkgconfig')
pkgconfig.generate(
  foo,
  name : 'foo',
  description : 'install fixture',
  subdirs : ['foo'],
)
