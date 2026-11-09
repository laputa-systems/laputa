project('preprocess-custom-target', 'c')

cc = meson.get_compiler('c')
pre = cc.preprocess(
  'foo.h',
  include_directories: include_directories('.'),
  compile_args: ['-DPREPROCESSED=1'],
)
generated = custom_target(
  'extract',
  input: pre,
  output: 'generated.h',
  command: ['cutout.py', '@INPUT@', '@OUTPUT@'],
)
executable('use', 'main.c', generated)
