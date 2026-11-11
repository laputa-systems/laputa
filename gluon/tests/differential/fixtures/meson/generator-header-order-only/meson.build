project('generator-header-order-only', 'c')

generator = generator(
  find_program('gen.py'),
  output: '@BASENAME@.h',
  arguments: ['@INPUT@', '@OUTPUT@'],
)
headers = generator.process('value.in')

executable('use', 'main.c', headers)
