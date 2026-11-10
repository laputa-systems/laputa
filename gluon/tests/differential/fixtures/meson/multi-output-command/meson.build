project('multi-output-command', 'c')
python3 = find_program('python3')
custom_target('split',
  input: ['a.h', 'b.h'],
  output: ['joined.h', 'count.txt'],
  command: [python3, files('split.py'), '@OUTPUT@', '@INPUT@'],
  build_by_default: true,
  install: true,
  install_dir: 'share/split')
