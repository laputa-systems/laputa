project('install-script', 'c')

install_data('payload.txt', install_dir: get_option('datadir') / 'script-fixture')

meson.add_install_script('install-script.py', 'payload.txt', install_tag: 'runtime')
