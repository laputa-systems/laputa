project('shlib-static-deps', 'c', version: '1.0')

core = static_library('core', 'core.c')
shared_library('probe', 'probe.c', link_with: core, install: true)
