project('custom-target-command', 'c')

gen = executable('gen', 'gen.c')
script = find_program('script.py')

captured = custom_target(
  'captured',
  input: 'input.txt',
  output: 'captured.h',
  command: [script, files('input.txt')],
  capture: true,
)

generated = custom_target(
  'generated',
  input: 'input.txt',
  output: 'generated.h',
  command: [gen, '@INPUT@', '@OUTPUT@'],
)

executable('use', 'use.c', captured, generated)
