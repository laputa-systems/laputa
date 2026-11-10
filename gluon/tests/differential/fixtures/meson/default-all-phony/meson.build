project('default-all-phony', 'c')
executable('prog', 'main.c')
custom_target('note', output: 'note.txt', command: ['touch', '@OUTPUT@'], build_by_default: true)
