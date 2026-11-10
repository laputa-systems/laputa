project('wayland-find-protocol', 'c')
wl = import('unstable-wayland')
protocols = [
  wl.find_protocol('text-input', state: 'unstable', version: 1),
  wl.find_protocol('text-input', state: 'unstable', version: 3),
  wl.find_protocol('xdg-shell', state: 'unstable', version: 5),
  wl.find_protocol('xdg-shell', state: 'unstable', version: 6),
  wl.find_protocol('fifo', state: 'staging', version: 1),
]
sources = []
foreach xml : protocols
  sources += wl.scan_xml(xml)
endforeach
executable('prog', 'main.c', sources, dependencies: dependency('wayland-client'))
