##! PM configure operations and shared package-manager policy.
# Generates a config.h from a config.h.in by processing autoconf #undef lines.
#
# defines maps variable name → C token (e.g. "1", "0", "\"pkgconf\"").
# Lines of the form '#undef VAR' are replaced:
#   - VAR in defines → '#define VAR value'
#   - VAR not in defines → '/* #undef VAR */'
# All other lines (comments, '/* #undef */' commented forms, blank) pass through.
## Exported PM declaration `config_h`.
export proc config_h(in_path: Path, out_path: Path, defines: Map[Str]) [fs, error] -> Result[Unit, Error] {
  let content = in_path.read_text()?
  let lines = content.split("\n")
  var out_lines = []

  for line in lines {
    if line.starts_with("#undef ") {
      let varname = line.replace("#undef ", with: "").trim()

      if varname in defines {
        let value = defines.get(varname)?
        out_lines += [f"#define {varname} {value}"]
      } else {
        out_lines += [f"/* #undef {varname} */"]
      }
    } else {
      out_lines += [line]
    }
  }

  out_path.parent.mkdir()
  out_path.write(out_lines.join("\n"))
}

# Substitutes @VAR@ placeholders in an autoconf .in file and writes the result.
# vars is a list of [name, value] pairs; name is the placeholder without @.
# Unknown @VAR@ tokens are left as-is.
## Exported PM declaration `substitute`.
export proc substitute(in_path: Path, out_path: Path, vars: List[List[Str]]) [fs, error] -> Result[Unit, Error] {
  var content = in_path.read_text()?

  for pair in vars {
    let key = pair[0]
    let value = pair[1]
    content = content.replace(f"@{key}@", with: value)
  }

  out_path.parent.mkdir()
  out_path.write(content)
}
