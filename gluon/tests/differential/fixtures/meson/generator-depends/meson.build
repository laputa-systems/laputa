project('generator-depends', 'c')
gen = generator(find_program('python3'),
  output: '@PLAINNAME@.c',
  arguments: ['-c', 'import sys; open(sys.argv[1], "w").write("int x=1;")', '@OUTPUT@'])
dt = custom_target('dep', output: 'dep.txt', command: ['python3', '-c', 'print("dep")'], input: 'input.h')
gen_out = gen.process('input.h', depends: [dt])
executable('hello', 'main.c', gen_out)
