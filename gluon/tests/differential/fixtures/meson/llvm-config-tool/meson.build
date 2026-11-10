project('llvm-config-tool', 'c', 'cpp')
llvm = dependency(
  'llvm',
  method : 'config-tool',
  version : '>= 23',
  modules : ['mcjit', 'core'],
  optional_modules : ['native', 'no-such-module'],
  static : true,
)
missing = dependency('llvm', method : 'config-tool', modules : ['no-such-module'], required : false)
conf = configuration_data()
conf.set('LLVM_VERSION_SYMBOL', 'llvm_version_' + llvm.version().replace('.', '_'))
conf.set('LLVM_RTTI_SYMBOL', 'llvm_rtti_' + llvm.get_variable(configtool : 'has-rtti'))
conf.set10('LLVM_MISSING_FOUND', missing.found())
configure_file(output : 'config.h', configuration : conf)
executable('prog', 'main.c', dependencies : llvm)
