project('install-plan', 'c', version: '1.0.0')

executable('app', 'main.c', install: true)
static_library('st', 'st.c', install: true)
shared_library('sh', 'sh.c', install: true)

install_headers('include/inst/header.h', subdir: 'inst')
install_headers('keep/keep.h', preserve_path: true)

install_data(
  'data/data.txt',
  rename: 'renamed.txt',
  install_dir: get_option('datadir') / 'install-plan',
  install_mode: ['rw-r-----'],
)

conf = configuration_data()
conf.set('VALUE', '42')
configure_file(
  input: 'conf.h.in',
  output: 'conf.h',
  configuration: conf,
  install: true,
  install_dir: get_option('includedir'),
)

custom_target(
  'generated',
  input: 'data/custom.txt',
  output: 'generated.txt',
  command: [find_program('sh'), '-c', 'cat @INPUT@ > @OUTPUT@'],
  install: true,
  install_dir: get_option('datadir') / 'install-plan',
)

install_subdir('assets', install_dir: get_option('datadir') / 'install-plan')
install_symlink('app-link', pointing_to: 'app', install_dir: get_option('bindir'))
install_man('man/install-plan.1')
install_emptydir(get_option('datadir') / 'install-plan/empty')
