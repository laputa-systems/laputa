error ScriptError = Failed(kind: Str, message: Str)

# GNU m4 1.4 semantics bison's and flex's skeletons depend on: recursion,
# `$@` requoting, builtin tokens through `defn`, pushdef stacks, regexes with
# groups, numbered diversions, LIFO m4wrap, multi-character quotes, comments,
# and include through -I. The expected text is GNU m4 1.4.20's output.
const semantics_input = r"""divert(-1)
# Recursion, nested quoting, and argument rescanning.
define(`fact', `ifelse(`$1', `0', `1', `eval($1 * fact(decr($1)))')')
define(`forloop', `pushdef(`$1', `$2')_forloop($@)popdef(`$1')')
define(`_forloop', `$4`'ifelse($1, `$3', `', `define(`$1', incr($1))$0($@)')')
define(`args', `$# [$*] [$@]')
define(`alias', defn(`define'))
divert(0)dnl
factorial= fact(6)
loop= forloop(`i', `1', `4', `<i>')
argv= args(`a', `b,c', ``q'')
aliased= alias(`made', `by alias')made
stack= pushdef(`v', `outer')pushdef(`v', `inner')v popdef(`v')v
branch= ifelse(`a', `b', `no', `c', `c', `yes', `default')
subst= patsubst(`int foo_bar(void)', `\([a-z]+\)_\([a-z]+\)', `\2_\1')
match= regexp(`GNUs not Unix', `\w\(\w+\)$', `*\&* *\1*') regexp(`abc', `c')
upper= translit(`hello', `a-z', `A-Z')
printf= format(`%-4s|%04d|%x', `ab', `7', `255')
arith= eval(`(1 << 31) + 2 ** 3', `10') eval(`255', `16', `4')
inc= include(`proof-inc.m4')included_macro
divert(2)diverted two
divert(1)diverted one
divert(0)dnl
undivert(2)dnl
m4wrap(`wrapped last
')m4wrap(`wrapped first
')dnl
changequote(`[[', `]]')dnl
quotes= [[kept `ticks' and [[nested]] brackets]]
changequote`'dnl
comment= # fact(3) stays
lineno= __line__
"""

const semantics_include = r"""define(`included_macro', `from include')dnl
"""

const semantics_expected = r"""factorial= 720
loop= <1><2><3><4>
argv= 3 [a,b,c,q] [a,b,c,`q']
aliased= by alias
stack= inner outer
branch= yes
subst= int bar_foo(void)
match= *Unix* *nix* 2
upper= HELLO
printf= ab  |0007|ff
arith= -2147483640 00ff
inc= from include
diverted two
quotes= kept `ticks' and [[nested]] brackets
comment= # fact(3) stays
lineno= 32
wrapped first
wrapped last
diverted one
"""

# Flex's skeleton dialect: `-P` prefixed builtins, comments disabled, and
# `[[`/`]]` quotes, read from standard input as flex pipes it.
const prefixed_input = r"""m4_changecom`'m4_dnl
m4_changequote`'m4_dnl
m4_changequote([[,]])[[]]m4_dnl
m4_define([[M4_YY_PREFIX]], [[[[yy]]]])m4_dnl
m4_define([[M4_YY_SC]], [[[[#define INITIAL 0
]]]])m4_dnl
#line 1 "out.c"
m4_ifdef([[M4_YY_IN_HEADER]],,[[m4_dnl
m4_ifelse(M4_YY_PREFIX,yy,,
#define yy_create_buffer M4_YY_PREFIX[[_create_buffer]]
)m4_dnl
]])
M4_YY_SC
define dnl ifdef stay literal under -P
m4_define([[x]], [[m4_eval(6 * 7)]])x m4___line__ m4___file__
m4_ifelse(m4_index([[hello]], [[ll]]), [[2]], [[found]], [[missing]])
m4_patsubst([[a-b-c]], [[-]], [[+]]) m4_regexp([[abc]], [[b\(c\)]], [[\1!]])
m4_divert(1)[[later]]
m4_divert(0)[[now]]
m4_m4wrap([[wrapped
]])m4_dnl
"""

const prefixed_expected = r"""#line 1 "out.c"

#define INITIAL 0

define dnl ifdef stay literal under -P
42 15 stdin
found
a+b+c c!
now
wrapped
later
"""

proc expect_text(label: Str, actual: Str, expected: Str) {
  if actual != expected {
    return Err(ScriptError.Failed(kind: "proof-m4", message: f"{label}: output differs from GNU m4\n--- expected\n{expected}--- actual\n{actual}"))?
  }
}

proc main(rootfs = /rootfs) [fs, process, error] {
  let tmp = fp"{rootfs}/var/tmp/proof-m4"
  tmp.remove(missing_ok: true)
  tmp.mkdir()
  defer tmp.remove(missing_ok: true)
  let m4 = fp"{rootfs}/usr/bin/m4"

  return Err(ScriptError.Failed(kind: "proof-m4", message: f"missing m4: {m4}"))? unless m4.exists()

  fp"{tmp}/test.m4".write(
    """define(GREETING, hello from m4)GREETING
""",
  )

  # Construct the generated operand from text.  Interpolated `fp` literals
  # resolve as the current directory in the published runner and would pass
  # `proof-m4` itself instead of this file.
  let input = fp"{tmp}/test.m4"
  let out = run.text $m4 $input
  let trimmed = out.trim()

  if trimmed != "hello from m4" {
    return Err(ScriptError.Failed(kind: "proof-m4", message: f"unexpected output: {trimmed}"))?
  }

  # The include directory is reached only through -I, never the cwd.
  let include_dir = fp"{tmp}/include"
  include_dir.mkdir()
  fp"{include_dir}/proof-inc.m4".write(semantics_include)
  let semantics = fp"{tmp}/semantics.m4"
  semantics.write(semantics_input)
  let semantics_out = run.text $m4 "-I" $include_dir $semantics
  expect_text("semantics", semantics_out, semantics_expected)

  let prefixed = fp"{tmp}/prefixed.m4"
  prefixed.write(prefixed_input)
  let prefixed_out = run.text $m4 "-P" < $prefixed
  expect_text("prefixed", prefixed_out, prefixed_expected)

  # An unterminated macro call is a fatal error with a nonzero status, never
  # truncated output with success.
  let unterminated = fp"{tmp}/unterminated.m4"
  unterminated.write("define(`x', `y')x(\n")
  let unterminated_stderr = fp"{tmp}/unterminated.stderr"
  let unterminated_status = process.run(
    process.command_argv(m4, [m4, unterminated], stderr: unterminated_stderr),
  )?

  if unterminated_status.ok {
    return Err(ScriptError.Failed(kind: "proof-m4", message: "m4 accepted an unterminated argument list"))?
  }

  if "end of file in argument list" not in unterminated_stderr.read_text()? {
    return Err(ScriptError.Failed(kind: "proof-m4", message: "m4 rejected an unterminated call without its diagnostic"))?
  }

  # Positional operands must remain literal file inputs. A directory must not
  # be silently resolved as the proof cwd by the published XSH runner.
  let directory_stderr = fp"{tmp}/directory-input.stderr"
  let directory_input = process.run(
    process.command_argv(m4, [m4, tmp], stderr: directory_stderr),
  )?

  if directory_input.ok {
    return Err(ScriptError.Failed(kind: "proof-m4", message: "m4 accepted a directory input"))?
  }

  if "cannot read non-file input" not in directory_stderr.read_text()? {
    return Err(ScriptError.Failed(kind: "proof-m4", message: "m4 rejected a directory without its input diagnostic"))?
  }

  print "m4 ok: "${trimmed}
}

main(@args)
