project('pkgconfig-generate', 'c', version: '2.3.4')

zlib = dependency('zlib', version: '>=1.2')

pub = library(
  'pub',
  'lib.c',
  version: '2.3.4',
  soversion: '2',
  dependencies: zlib,
  install: true,
)

helper = static_library('helper', 'helper.c', install: true)
priv = static_library('priv', 'priv.c', link_with: helper, install: true)

shared_only = shared_library(
  'pub2',
  'pub2.c',
  dependencies: zlib,
  install: true,
)

pkg = import('pkgconfig')
pkg.generate(
  pub,
  name: 'pkgconfig-generate',
  description: 'pkgconfig.generate keyword coverage',
  url: 'https://example.invalid/pkgconfig-generate',
  version: '2.3.4',
  subdirs: ['sub'],
  variables: {'answer': '42', 'flavor': 'vanilla'},
  libraries: pub,
  libraries_private: priv,
  requires: ['base >= 1.0'],
  conflicts: ['oldpkg'],
)

pkg.generate(
  shared_only,
  name: 'pkgconfig-generate-shared-only',
  description: 'shared_library does not expose its dependencies',
  version: '2.3.4',
  libraries: shared_only,
)
