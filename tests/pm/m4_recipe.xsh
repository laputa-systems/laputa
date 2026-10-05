##! Regression coverage for the XSH m4: its package proof and GNU m4 1.4
##! compatibility on the constructs bison's and flex's skeletons use.
proc runner() -> Result[Path] {
  let configured = (e"XSH_HOST" ?? "").trim()

  if configured != "" {
    let selected = fp"{configured}"

    return selected when selected.exists()?
  }

  process.which("xsh")?
}

type M4Run = {ok: Bool, code: Int, stdout: Str, stderr: Str}

proc run_m4(ctx: TestContext, name: Str, input: Str, argv: List[Str] = []) -> Result[M4Run] {
  let root = test.temp_dir(ctx, name:)?
  let source = fp"{root}/input.m4"
  let stdout = fp"{root}/stdout"
  let stderr = fp"{root}/stderr"
  let xsh = runner()?
  source.write(input)

  let status = process.run(
    process.command_argv(
      xsh,
      [xsh.display(), "packages/m4/files/m4.xsh", "--"].extend(argv).push(source.display()),
      stdout:,
      stderr:,
    ),
  )?

  {ok: status.ok, code: if status.exited() { status.exit_code()? } else { -1 }, stdout: stdout.read_text()?, stderr: stderr.read_text()?}
}

# Expected text below is GNU m4 1.4.20's output for the same input.
const gnu_corpus = r"""define(`fact', `ifelse(`$1', `0', `1', `eval($1 * fact(decr($1)))')')dnl
fact(5) fact(10)
define(`forloop', `pushdef(`$1', `$2')_forloop($@)popdef(`$1')')dnl
define(`_forloop', `$4`'ifelse($1, `$3', `', `define(`$1', incr($1))$0($@)')')dnl
forloop(`i', `1', `5', `[i]')
define(`foreach', `pushdef(`$1')_foreach($@)popdef(`$1')')dnl
define(`_arg1', `$1')dnl
define(`_foreach', `ifelse(`$2', `()', `', `define(`$1', _arg1$2)$3`'$0(`$1', (shift$2), `$3')')')dnl
foreach(`x', `(a, b, c)', `<x>')
define(`nest', `[$@] [$*] [$#]')dnl
nest(`a', `b,c', ``q'')
define(`count', `$#')count count() count(,) count(`a',`b',`c')
pushdef(`p', `one')pushdef(`p', `two')p popdef(`p')p popdef(`p')p
define(`alias', defn(`define'))alias(`viaalias', `ok')viaalias
define(`L', defn(`len'))L(`abcd')
indir(`fact', `3') builtin(`eval', `7 * 6')
divert(2)two
divert(1)one
divert(3)three
divert`'zero
undivert(3, 1)
divnum
changequote(`[[', `]]')dnl
[[quoted, with `ticks']] [[nested [[inner]] text]]
changequote`'dnl
changecom(`/*', `*/')dnl
/* define(`gone') stays */ `gone'
changecom`'dnl
# not a comment: fact(3)
changecom(`#')dnl
# a comment: fact(3)
define(`wrap', `($1)')wrap(# comma, paren )
 x)
wrap(`leading', `trailing ')
translit(`hello world', `a-y', `b-z') translit(`abc', `abc') translit(`a-b', `-', `_')
patsubst(`int foo_bar(int a)', `\([a-z]+\)_\([a-z]+\)', `\2_\1')
patsubst(`  lots   of   space  ', `  *', ` ')
regexp(`GNUs not Unix', `\w\(\w+\)$', `*\&* *\1*')
regexp(`abc', `b') regexp(`abc', `z')
format(`%s=%d [%5s] [%-5s] [%05d] [%x]', `n', `42', `ab', `cd', `7', `255')
eval(`2 ** 10 + (7 % 3) * -1') eval(`0x1F | 0b100', `2', `8') eval(`1 < 2 && 3 >= 3 || 0')
len(`') len(`abc') index(`hello', `l') substr(`hello', `1', `3') substr(`hello', `3')
shift(`a', `b', `c') ifdef(`fact', `defined', `undefined') ifdef(`nope', `defined', `undefined')
define(`cat', `$1$2$3')cat(`a', `b')
ifelse(`a', `b', `1', `a', `a', `2', `3') ifelse(`x', `y', `no') ifelse(`one')
m4wrap(`first wrapped
')m4wrap(`second wrapped
')dnl
__line__
define(`multi', `line1
line2')multi
undefine(`multi')multi
define(`$weird', `w')indir(`$weird')
`'define(`dq', ``$1'')dq(`x')
"""

const gnu_corpus_output = r"""120 3628800
[1][2][3][4][5]
<a><b><c>
[a,b,c,`q'] [a,b,c,q] [3]
0 1 2 3
two one p
ok
4
6 42
zero
three
one

0
quoted, with `ticks' nested [[inner]] text
/* define(`gone') stays */ gone
# not a comment: 6
# a comment: fact(3)
(# comma, paren )
 x)
(leading)
ifmmp xpsme  a_b
int bar_foo(int a)
 lots of space 
*Unix* *nix*
1 -1
n=42 [   ab] [cd   ] [00007] [ff]
1023 00011111 1
0 3 2 ell lo
b,c defined undefined
ab
2  
49
line1
line2
multi
w
x
second wrapped
first wrapped
two
"""

const cat_heredoc = r"""changequote([, ])dnl
before
syscmd([cat <<'_m4eof'
@complain(in order@)
_m4eof
])dnl
sysval
after
"""

const cat_heredoc_output = r"""before
@complain(in order@)
0
after
"""

test test_m4_proof_reads_its_file_operand_and_handles_directory_rejection [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "m4-proof-file-operand")?
  let m4 = fp"{root}/usr/bin/m4"
  let stderr = fp"{root}/proof.stderr"
  let xsh = runner()?
  m4.parent.mkdir()

  # The proof invokes the staged runner as an executable.  Its shebang points
  # at this host test runner solely so the behavior can be checked without a
  # target rootfs; the package payload still ships `#!/bin/xsh`.
  let staged = p"packages/m4/files/m4.xsh".read_text()?.replace("#!/bin/xsh", f"#!{xsh}")
  m4.write(staged, mode: 0o755)

  let status = process.run(
    process.command_argv(
      xsh,
      [xsh, "packages/m4/proof.xsh", "--", root],
      stderr:,
    ),
  )?
  if ! status.ok {
    test.fail(stderr.read_text()?)
  }
}

# Recursion, `$@` requoting, pushdef stacks, builtin tokens, numbered
# diversions, comment and quote changes, regexes, eval, and LIFO m4wrap.
test test_m4_matches_gnu_m4_on_skeleton_constructs [fs, process, env, error] { |ctx|
  let result = run_m4(ctx, "m4-gnu-corpus", gnu_corpus)?
  assert result.ok, result.stderr
  assert result.stderr == ""
  assert result.stdout == gnu_corpus_output
}

# bison's `b4_cat` writes diagnostics through `syscmd` with a `cat`
# here-document; it must reach stdout in order without a shell.
test test_m4_syscmd_cat_heredoc_keeps_output_order [fs, process, env, error] { |ctx|
  let result = run_m4(ctx, "m4-cat-heredoc", cat_heredoc)?
  assert result.ok, result.stderr
  assert result.stdout == cat_heredoc_output
}

# m4exit ends the run with its status, flushing diversion 0 and discarding
# other diversions and wrapped text, as GNU m4 does.
test test_m4exit_status_and_discarded_diversions [fs, process, env, error] { |ctx|
  let result = run_m4(ctx, "m4-exit", "m4wrap(`wrapped')divert(1)one\ndivert(0)zero\nm4exit(3)after\n")?
  assert result.code == 3
  assert result.stdout == "zero\n"
}

# Failures are loud: a nonzero status and a diagnostic, never truncated
# output with success.
test test_m4_unterminated_call_fails [fs, process, env, error] { |ctx|
  let result = run_m4(ctx, "m4-unterminated", "define(`x', `y')x(\nmore\n")?
  assert ! result.ok
  assert "end of file in argument list" in result.stderr
}

test test_m4_unterminated_quote_fails [fs, process, env, error] { |ctx|
  let result = run_m4(ctx, "m4-unterminated-quote", "`never closed\n")?
  assert ! result.ok
  assert "end of file in string" in result.stderr
}

test test_m4_infinite_recursion_fails [fs, process, env, error] { |ctx|
  let result = run_m4(ctx, "m4-recursion", "define(`f', `$1')define(`r', `f(r(1))')r(1)\n")?
  assert ! result.ok
  assert "recursion limit" in result.stderr
}

test test_m4_regex_back_reference_fails_loudly [fs, process, env, error] { |ctx|
  let result = run_m4(ctx, "m4-backref", "patsubst(`aa', `\\(a\\)\\1', `x')\n")?
  assert ! result.ok
  assert "back-reference" in result.stderr
}
