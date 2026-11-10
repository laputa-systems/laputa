project('wayland-scan-xml', 'c')
wl = import('unstable-wayland')
protocol = wl.scan_xml('sample.xml', client: true, server: true)
executable('prog', 'main.c', protocol, dependencies: dependency('wayland-client'))
