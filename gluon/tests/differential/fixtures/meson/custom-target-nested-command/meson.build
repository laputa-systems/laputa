project('custom-target-nested-command', 'c')
python = find_program('python3')
generated = custom_target('generated',
  command: [python, files('gen.py'), '@OUTPUT@'],
  output: 'generated.c',
  build_by_default: true)
executable('app', generated)
