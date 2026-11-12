project('postconf-script', 'c')

meson.add_postconf_script('postconf-script.py')

executable(
  'postconf-app',
  'main.c',
  include_directories: include_directories('.'),
)
