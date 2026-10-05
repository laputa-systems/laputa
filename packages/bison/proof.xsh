##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

error ScriptError = Failed(kind: Str, message: Str)

type Grammar = {file: Str, argv: List[Str], outputs: List[Str]}

type GeneratedFile = {name: Str, sha256: Str}

# An LALR(1) calculator on the yacc.c skeleton with the features real
# grammars lean on: a pure parser with parameters, locations, %union types,
# named references, %printer/%destructor, error recovery, and a header.
const calc_grammar = r"""%code requires {
  typedef struct { int line; int column; } proof_place;
}
%code provides {
  int proof_parse_text(const char *text);
}
%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
%}
%define api.pure full
%define api.prefix {proof_}
%define parse.error detailed
%define parse.trace
%locations
%param {const char **cursor}
%union {
  long number;
  char name;
}
%code {
  static int proof_lex(PROOF_STYPE *value, PROOF_LTYPE *place, const char **cursor);
  static void proof_error(PROOF_LTYPE *place, const char **cursor, const char *message);
  static long variables[26];
}
%token <number> NUMBER "number"
%token <name> NAME "variable"
%token ASSIGN ":="
%nterm <number> expr
%left '+' '-'
%left '*' '/'
%precedence NEG
%printer { fprintf(yyo, "%ld", $$); } <number>
%destructor { (void) $$; } <number>
%initial-action { @$.first_line = @$.last_line = 1; }
%%
input:
  %empty
| input line
;
line:
  '\n'
| expr[value] '\n'         { printf("%ld\n", $value); }
| NAME ":=" expr '\n'      { variables[$1 - 'a'] = $3; printf("%c=%ld\n", $1, $3); }
| error '\n'               { yyerrok; printf("error at line %d\n", @1.first_line); }
;
expr:
  NUMBER
| NAME                     { $$ = variables[$1 - 'a']; }
| expr '+' expr            { $$ = $1 + $3; }
| expr '-' expr            { $$ = $1 - $3; }
| expr '*' expr            { $$ = $1 * $3; }
| expr '/' expr            { if ($3 == 0) { proof_error(&@3, cursor, "division by zero"); YYERROR; } $$ = $1 / $3; }
| '-' expr %prec NEG       { $$ = -$2; }
| '(' expr ')'             { $$ = $2; }
;
%%
static int proof_lex(PROOF_STYPE *value, PROOF_LTYPE *place, const char **cursor) {
  const char *p = *cursor;
  while (*p == ' ')
    p++;
  place->first_line = place->last_line;
  if (*p == '\0') {
    *cursor = p;
    return PROOF_EOF;
  }
  if (*p >= '0' && *p <= '9') {
    value->number = strtol(p, (char **) &p, 10);
    *cursor = p;
    return NUMBER;
  }
  if (*p >= 'a' && *p <= 'z') {
    value->name = *p;
    *cursor = p + 1;
    return NAME;
  }
  if (p[0] == ':' && p[1] == '=') {
    *cursor = p + 2;
    return ASSIGN;
  }
  if (*p == '\n')
    place->last_line++;
  *cursor = p + 1;
  return *p;
}

static void proof_error(PROOF_LTYPE *place, const char **cursor, const char *message) {
  (void) cursor;
  printf("line %d: %s\n", place->first_line, message);
}

int proof_parse_text(const char *text) {
  return proof_parse(&text);
}

int main(void) {
  return proof_parse_text("1 + 2 * 3\n(4 + 5) * -2\nx := 7\nx * x - 1\n1 +\n8 / 0\n");
}
"""

const calc_expected = r"""7
-18
x=7
48
line 5: syntax error, unexpected '\n', expecting number or variable or '-' or '('
error at line 5
line 6: division by zero
error at line 6
"""

# A %glr-parser grammar on glr.c: a reduce/reduce conflict only the second
# token after 'x' resolves, and an ambiguity merged by %merge.
const glr_grammar = r"""/* After 'x' with 'y' ahead, LALR(1) cannot choose between reducing to `a'
   or `b'; the GLR parser splits and the third token picks the survivor. An
   ambiguous sum is merged by %merge. */
%glr-parser
%expect-rr 1
%expect 1
%{
#include <stdio.h>
static int yylex(void);
static void yyerror(const char *message);
static int pick(int left, int right);
static const char *input = "xyz\nxyw\nn+n+n\n";
%}
%define api.value.type {int}
%%
lines:
  %empty
| lines line
;
line:
  a 'y' 'z' '\n'           { puts("a-path"); }
| b 'y' 'w' '\n'           { puts("b-path"); }
| sum '\n'                 { printf("sum %d\n", $1); }
;
a: 'x' ;
b: 'x' ;
sum:
  'n'                      { $$ = 1; }
| sum '+' sum %merge <pick> { $$ = $1 + $3; }
;
%%
static int pick(int left, int right) {
  printf("merged %d %d\n", left, right);
  return left;
}

static int yylex(void) {
  return *input ? *input++ : 0;
}

static void yyerror(const char *message) {
  printf("error: %s\n", message);
}

int main(void) {
  return yyparse();
}
"""

const glr_expected = r"""a-path
b-path
merged 3 3
sum 3
"""

# The lalr1.cc skeleton with variants, token constructors, and locations.
# The proof root has no C++ library, so its output is checked by digest.
const list_grammar = r"""%skeleton "lalr1.cc"
%require "3.8"
%header
%define api.namespace {proof}
%define api.parser.class {list_parser}
%define api.token.constructor
%define api.value.type variant
%define parse.assert
%locations
%code requires {
#include <string>
#include <vector>
}
%code {
namespace proof {
list_parser::symbol_type yylex();
}
}
%token <std::string> WORD
%token END 0
%nterm <std::vector<std::string>> words
%%
start: words { for (const auto &w : $1) { (void) w; } };
words:
  %empty { }
| words WORD { $$ = $1; $$.push_back($2); }
;
%%
namespace proof {
void list_parser::error(const location_type &, const std::string &) {}
}
"""

const grammars: List[Grammar] = [
  {file: "calc.y", argv: ["-Wall", "-o", "calc.c", "--defines=calc.h", "calc.y"], outputs: ["calc.c", "calc.h"]},
  {file: "glr.y", argv: ["-Wall", "-o", "glr.c", "glr.y"], outputs: ["glr.c"]},
  {file: "list.yy", argv: ["-Wall", "-o", "list.cc", "list.yy"], outputs: ["list.cc", "list.hh", "location.hh"]},
]

# sha256 of GNU bison 3.8.2's output for `grammars` with upstream's skeletons:
# every generated file must match it byte for byte.
const gnu_outputs: List[GeneratedFile] = [
  {name: "calc.c", sha256: "fd7ab25921795a1be7c73c39e5ebcf9d52e3dbc3f0c97044c31c7d521e5d2cb7"},
  {name: "calc.h", sha256: "6caf6cbc025e6be258e7eeda28db75dbbcce45fb4cdf925cd7b66ad94e22575f"},
  {name: "glr.c", sha256: "412ab134812df0b60d9938c4f312fb8b5845c0b8fa96ba50f14f3838149c5ba3"},
  {name: "list.cc", sha256: "ca8adfc87f38e4b0703af9aa9280541473273b10454400e6a97d31b06ad1a50d"},
  {name: "list.hh", sha256: "c991f25cd4cf9dc0de608c919c362da602d63a89038ab908cab0c6691d7eb352"},
  {name: "location.hh", sha256: "41e4940385a37f8b2aa292dc51620c0f28f0c6680392050cc67cd7d356853b08"},

]

pure grammar_text(file: Str) -> Str {
  match file {
    "calc.y" => calc_grammar
    "glr.y" => glr_grammar
    _ => list_grammar
  }
}

# Compile C against the proof root's own musl: the runner's `cc` builds with
# the root as sysroot and records the root's dynamic linker, so the program
# exercises the root's libc rather than the runner's. Native targets only.
proc compile_root_c_program(rootfs: Path, source: Path, output: Path) [process, env, error] {
  let arch = pm_util.target_arch()?
  let cc = process.which("cc")?
  let lib = fp"{rootfs}/usr/lib"
  run $cc f"--target={arch}-linux-musl" f"--sysroot={rootfs}" "-dynamic" f"-I{rootfs}/usr/include" f"-L{lib}" f"-Wl,-rpath,{lib}" f"-Wl,-dynamic-linker,{lib}/ld-musl-{arch}.so.1" $source "-o" $output ?
}

proc run_parser(rootfs: Path, tmp: Path, source: Str, expected: Str) [fs, process, env, error] {
  let program = fp"{tmp}/{source}.bin"
  compile_root_c_program(rootfs, fp"{tmp}/{source}", program)?
  let out = run.text $program ?

  if out != expected {
    return Err(ScriptError.Failed(kind: "proof-bison", message: f"{source} parser output:\n{out}"))?
  }
}

proc prove_grammars(rootfs: Path, bison: Path) [fs, process, env, error] {
  let tmp = fp"{rootfs}/var/tmp/proof-bison"
  fs.remove(tmp, missing_ok: true)?
  fs.mkdir(tmp)?
  defer fs.remove(tmp, missing_ok: true)?
  let stderr = fp"{tmp}/bison.stderr"

  # Name the root's m4 and skeletons so the proof cannot pass on another m4
  # or data directory the runner happens to provide.
  env ({
    M4: fp"{rootfs}/usr/bin/m4".display(),
    BISON_PKGDATADIR: fp"{rootfs}/usr/share/bison".display(),
  }) {
    for grammar in grammars {
      fs.write(fp"{tmp}/{grammar.file}", grammar_text(grammar.file))?

      cd $tmp {
        let status = process.run(process.command_argv(bison, [bison.display()].extend(grammar.argv), stderr:))?
        let diagnostics = stderr.read_text()?

        if ! status.ok or diagnostics != "" {
          return Err(ScriptError.Failed(kind: "proof-bison", message: f"bison {grammar.file}: {diagnostics}"))?
        }
      }?
    }
  }?

  for output in gnu_outputs {
    let file = fp"{tmp}/{output.name}"

    if ! fs.exists(file)? {
      return Err(ScriptError.Failed(kind: "proof-bison", message: f"bison did not write {output.name}"))?
    }

    let digest = hash.sha256(file)?.hex()

    if digest != output.sha256 {
      return Err(ScriptError.Failed(kind: "proof-bison", message: f"{output.name} differs from GNU bison 3.8.2 output: sha256 {digest}"))?
    }
  }

  run_parser(rootfs, tmp, "calc.c", calc_expected)?
  run_parser(rootfs, tmp, "glr.c", glr_expected)?
}

proc main(rootfs: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(rootfs, "bison")?
  proof.target_elf(rootfs, p"usr/bin/bison", "bison")?
  let bison = fp"{rootfs}/usr/bin/bison"

  if pm_util.build_arch()? == pm_util.target_arch()? {
    let version = run.text $bison "--version" ?

    if "GNU Bison) 3.8.2" not in version {
      return Err(ScriptError.Failed(kind: "proof-bison", message: f"bison --version: {version.trim()}"))?
    }

    prove_grammars(rootfs, bison)?
    print "bison ok: yacc.c, glr.c, and lalr1.cc output matches GNU bison 3.8.2; parsers run"
  } else {
    print "bison ok: cross-built "${pm_util.target_arch()?}
  }
}

main(@args)?
