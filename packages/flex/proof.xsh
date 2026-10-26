##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

error ScriptError = Failed(kind: Str, message: Str)

const lexer = r"""%option noyywrap nounput noinput yylineno
%x COMMENT
%{
#include <stdio.h>
static int words, numbers, comments;
%}
DIGIT [0-9]
%%
"/*"                   { BEGIN(COMMENT); }
<COMMENT>"*/"          { comments++; BEGIN(INITIAL); }
<COMMENT>.|\n          { }
{DIGIT}+               { numbers++; printf("number %s\n", yytext); }
[A-Za-z_][A-Za-z0-9_]* { words++; printf("word %s line %d\n", yytext, yylineno); }
[ \t\n]+               { }
.                      { printf("char %c\n", yytext[0]); }
%%
int main(void) {
  yylex();
  printf("words=%d numbers=%d comments=%d\n", words, numbers, comments);
  return 0;
}
"""

const scanner_input = "alpha 42 /* skip 7\n more */ beta_2+9\ngamma\n"

const scanner_expected = """word alpha line 1
number 42
word beta_2 line 2
char +
number 9
word gamma line 3
words=3 numbers=2 comments=1
"""

const gnu_outputs = [
  {name: "words.c", sha256: "16155f0d15411f2b37af60b262fb1c7d1de3304e4d317dcf3019aa7e7e536285"},
  {name: "words.h", sha256: "31ac026fbbdd94178fd3b7f1d9da2bde5a3b792844f1fb4a6b9ebf8a2963e97e"},
]

proc compile_root_c_program(rootfs: Path, source: Path, output: Path) {
  let arch = pm_util.target_arch()?
  let cc = process.which("cc")?
  let lib = fp"{rootfs}/usr/lib"
  run $cc f"--target={arch}-linux-musl" f"--sysroot={rootfs}" "-dynamic" f"-I{rootfs}/usr/include" f"-L{lib}" \
    f"-Wl,-rpath,{lib}" f"-Wl,-dynamic-linker,{lib}/ld-musl-{arch}.so.1" $source "-o" $output
}

proc prove_scanner(rootfs: Path, flex: Path) {
  tempdir tmp at fp"{rootfs}/var/tmp/proof-flex" {
    fp"{tmp}/words.l".write(lexer)
    let stderr = fp"{tmp}/flex.stderr"

    env ({M4: fp"{rootfs}/usr/bin/m4".display()}) {
      cd $tmp {
        let status = process.run(
          process.command_argv(flex, [flex, "--header-file=words.h", "-o", "words.c", "words.l"], stderr:),
        )?

        if ! status.ok {
          return Err(ScriptError.Failed(kind: "proof-flex", message: f"flex failed: {stderr.read_text()?}"))?
        }
      }
    }

    for output in gnu_outputs {
      let file = fp"{tmp}/{output.name}"

      if ! file.exists() {
        return Err(ScriptError.Failed(kind: "proof-flex", message: f"flex did not write {output.name}"))?
      }

      let digest = hash.sha256(file)?.hex()

      if digest != output.sha256 {
        return Err(ScriptError.Failed(kind: "proof-flex", message: f"{output.name} differs from GNU flex 2.6.4 output: sha256 {digest}"))?
      }
    }

    let scanner = fp"{tmp}/words"
    compile_root_c_program(rootfs, fp"{tmp}/words.c", scanner)
    let input = fp"{tmp}/input.txt"
    input.write(scanner_input)
    let out = run.text $scanner < $input

    if out != scanner_expected {
      return Err(ScriptError.Failed(kind: "proof-flex", message: f"scanner output:\n{out}"))?
    }
  }
}

proc main(rootfs = /rootfs) [fs, process, env, error] -> Result[Unit, Error] {
  let flex = fp"{rootfs}/usr/bin/flex"
  let lex = fp"{rootfs}/usr/bin/lex"

  if ! flex.exists() {
    return Err(ScriptError.Failed(kind: "proof-flex", message: f"missing flex: {flex}"))?
  }

  if ! lex.exists() {
    return Err(ScriptError.Failed(kind: "proof-flex", message: f"missing lex symlink: {lex}"))?
  }

  proof.target_elf(rootfs, p"usr/bin/flex", "flex")

  if pm_util.build_arch()? == pm_util.target_arch()? {
    let out = run.text $flex "--version"

    if "flex 2.6.4" not in out {
      return Err(ScriptError.Failed(kind: "proof-flex", message: f"flex --version: {out.trim()}"))?
    }

    prove_scanner(rootfs, flex)
    print "flex ok: generated scanner matches GNU flex 2.6.4 and runs"
  } else {
    print "flex ok: cross-built "${pm_util.target_arch()?}
  }
}
