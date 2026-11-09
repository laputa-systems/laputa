project('install-fixture', 'c', version : '2.3.4')

install_headers('include/foo/foo.h', subdir : 'foo')

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
)

pkgconfig = import('pkgconfig')
pkgconfig.generate(
  foo,
  name : 'foo',
  description : 'install fixture',
  subdirs : ['foo'],
)

conf = configuration_data()
conf.set('VERSION', meson.project_version())
configure_file(
  input : 'version.in',
  output : 'version.txt',
  configuration : conf,
  install_dir : get_option('datadir') / 'install-fixture',
)
