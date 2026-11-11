project('install-custom-dylib', 'c')

custom_target(
  'stub',
  output: 'libstub.dylib',
  command: [find_program('sh'), '-c', 'printf stub > @OUTPUT@'],
  install: true,
  install_dir: get_option('libdir'),
)
