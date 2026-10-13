# Make task graphs

`pm/make.xsh` translates Makefile-style source lists, compiler flags, link
flags, and targets into explicit typed graphs. It does not parse GNU Makefiles,
implement implicit rules, or run recursive make.

## Helpers

- `MakeTask` is the low-level graph unit; `check_tasks` validates it and
  `run_tasks` schedules it.
- `compile_*_task` and `link_*_task` construct individual steps.
- `compile_c_tasks`, `compile_lo_tasks`, and `compile_cxx_tasks` map explicit
  source lists to stable object names and return `tasks`, `objects`, and `deps`.
- `task_deps` derives dependencies from selected task outputs.
- `c_program`, `c_shared_library`, `c_static_library`, and `c_multi_program`
  return inspectable `tasks`, `objects`, `deps`, and `output` data.
  `c_multi_program` supports grouped mixed C/C++ sources and chooses a C++ link
  step when a linked group needs it.
- `discover_sources`, `pkg_config_flags`, and `install_header_tree` handle
  source discovery, typed pkg-config flags, and header installation.

`MakeTask.argv` carries paths and strings as individual process arguments,
never shell source. `PkgConfigFlags` keeps compiler and linker flags as string
lists. The scheduler validates dependencies, honors depfiles and command
stamps, rewrites native-cross compiler commands, and runs independent tasks
in parallel. A failed command cancels unfinished peers; completed-task stamps
are published only after the entire graph succeeds.

Keep build decisions visible in recipes. Helpers should remove repeated object
naming and dependency bookkeeping while returning ordinary task data that a
recipe can inspect and compose. `tests/pm/pm_make.xsh` checks the task contract;
see [testing](TESTING.md) for running focused suites.
