# Inference erasure

This reference records parameter-annotation erasure for Laputa's practical
root and the applied G4 view. It separates annotations that are contracts from
annotations the compiler cannot infer yet, gives a runnable witness for each
compiler class, and records the Laputa side of the frozen 1,040 checkpoint.

## Pins

| Item | Value |
|---|---|
| Laputa applied-view source | `d1fda6c722a2532184cf02edf07df1885d610c12`, tree `5270fd66519395ab9bfa9fdb48eefe3d07f24020` |
| Laputa erasure-source predecessor | `aa947851c4048f2d3ae5e1302e2738afdd4a181a`, tree `a3cd2b3772c7f08a7e0c938ed8c81e4d7386e397`; `pm/generation.xsh` is byte-identical from `aa94785` through `d1fda6c` |
| XSH compiler and applied-view decision | `24de61dd0522083645d8e88fd00a8d9d49ac965a`, tree `66e264fea43b0868a6687439a7bd1b242b6e30c2` |
| Built `xsh` | sha256 `ad0c36cdba0f7f06e79b44b134b4911e019ab23c0352046136962ee7f008d8fa` |
| Built `xsht` | sha256 `82273eb615d9a7f3382e7cb9cabd5599b26f831444bcbe642bebf8f2103d0869` |
| Fixed-compiler candidate | `732664cd19a01a69548ef6fd263f19d472f7d045`, tree `94303d7fd428e927c2cf8582fb1f1639e003c7c2`; unmerged `inference/map-key` |
| Fixed-compiler products | `xsh` sha256 `0159739a539c17f07135391e897a2e129a2a0a213184eb877d69c013e8238869`; `xsht` sha256 `67c7e678454644a2c6ed9a0a6ca737c20abe234c7357e996a811f97d92fe5928` |
| Laputa practical root | `pm/generation.xsh` |
| Parameter sites | 57: 38 private and 19 exported |
| Applied view | 37 private parameter sites at `24de61dd0` (12 `pure`, 25 `proc`); 38 at fixed candidate `732664cd1` |

The applied-view decision is XSH `24de61dd0`: private `pure` and private `proc`
parameters are eligible. Exported parameters, private `proc` returns, effect
clauses, and `Map`/`.require()` locals remain retained. The earlier 12-site
private-`pure` view is superseded.

The only Laputa root in the practical inventory is `pm/generation.xsh`. Laputa
`pm/plan_json.xsh` belongs to the frozen 1,040 view and was not touched by the
practical measurement. `pm/generation_adapter.xsh` and
`tests/pm/pm_generation.xsh` are behavior-checked but are not erasure roots.

## Measurement

The inventory was generated with the pinned `inventory.sh` and `inventory.rs`
against the XSH `24de61dd0` compiler and the Laputa `d1fda6c` tree:

```sh
bash dev/performance/corpus/inventory.sh \
  "$XSH_ROOT" 24de61dd0522083645d8e88fd00a8d9d49ac965a \
  "$XSH_ROOT" 24de61dd0522083645d8e88fd00a8d9d49ac965a \
  "$LAPUTA_ROOT" d1fda6c722a2532184cf02edf07df1885d610c12 \
  "$INVENTORY"
```

The inventory holds 724 spans: 668 annotations and 56 effect clauses. The
Laputa slice holds 57 parameter sites: 38 private and 19 exported. Its sha256 is
`15184bb86416df93a3a271e3978db8fd77a4b5fb882d4cbb967e6317180ba05d`;
the 37-site selector list has sha256
`6ee26c9772b39a01bd5d0d29e3d735b4ac1290764659f2de652cdfa0aab8d5b2`.

Erasure used the built `xsht` and a `git archive` export of `d1fda6c`:

```sh
python3 -B dev/performance/corpus/erase_sites.py "$INVENTORY" \
  --root "laputa=$SCRATCH/laputa" --xsht "$XSHT" \
  --scratch "$SCRATCH/erase" --jobs 8 --timeout 300
```

The 57 Laputa parameter sites produce:

```text
single-site erasure: 55/57 pass
  18/19 parameter proc exported
  25/26 parameter proc private
  12/12 parameter pure private
failing causes:
  1 parameter check.map-key-type
  1 parameter check.type-mismatch
joint erasure of every site that passed alone:
  laputa/pm/generation.xsh: 55 sites, fail {'compact.indexed-build: this function cannot be compiled yet: generic expression is outside the supported paramete': 1}
```

The private-only scope has 38 sites:

```text
single-site erasure: 37/38 pass
  25/26 parameter proc private
  12/12 parameter pure private
failing causes:
  1 parameter check.map-key-type
joint erasure of every site that passed alone:
  laputa/pm/generation.xsh: 37 sites, pass
```

The 37 sites that pass alone and jointly are the applied view. Site 32 is the
only private parameter outside it. The four private `GenerationPlan value`
sites and the exported `compose.value` site are in the 55-site all-parameter
joint, but that joint is exported-inclusive; see below.

### Fixed-compiler re-run

XSH `732664cd1` on `inference/map-key` fixes the site 32
`check.map-key-type` class. It is not merged into `master`. With the same
inventory and Laputa tree, the fixed compiler produces:

```text
single-site erasure: 38/38 pass
  26/26 parameter proc private
  12/12 parameter pure private
joint erasure of every site that passed alone:
  laputa/pm/generation.xsh: 38 sites, pass
```

All 57 parameter sites produce:

```text
single-site erasure: 56/57 pass
  18/19 parameter proc exported
  26/26 parameter proc private
  12/12 parameter pure private
failing causes:
  1 parameter check.type-mismatch
joint erasure of every site that passed alone:
  laputa/pm/generation.xsh: 56 sites, fail {'compact.indexed-build: this function cannot be compiled yet: generic expression is outside the supported paramete': 1}
```

Only site 54 remains a single-site failure. The 56-site joint still fails on
the exported-inclusive five-site set because `compose.value` stays retained.
The 38-site applied view, the 37 selectors plus site 32, prepares at
`732664cd1`; its root checks, six exact selectors, and behavior pass. Its
interface gate reports one more private generalization,
`generation_runtime_artifacts`, for 18 private helpers total. Its reduced
Laputa digest is
`bef6ef28f4e16ca699a6304d1896f48551e5192dc445678fe962667e35dfab0b`
over 1,670 entries; the original remains
`2972c5870784cdb55d32bc5001fefcdc3dc8f914d41d3b1fd6338dac47414aee`.
When `732664cd1` is merged, `SITE_IDS` becomes 38 and site 32 leaves the G4
table.

## Applied view

At the pinned `24de61dd0` compiler, `SITE_IDS` is the following 37 exact
`project|path|kind|line|owner` selectors, 12 `pure` and 25 private `proc`
parameters. It excludes site 32, `generation_runtime_artifacts.value`, which is
the G4 `check.map-key-type` item at that compiler. The fixed candidate adds it
for 38.

```text
laputa|pm/generation.xsh|parameter|48|pure generation_overlay_config_path parameter overlay_root,laputa|pm/generation.xsh|parameter|52|pure generation_receipt_path parameter output_root,laputa|pm/generation.xsh|parameter|60|pure generation_sha256_text_is_valid parameter value,laputa|pm/generation.xsh|parameter|64|proc generation_require_sha256 parameter value,laputa|pm/generation.xsh|parameter|64|proc generation_require_sha256 parameter label,laputa|pm/generation.xsh|parameter|70|pure generation_canonical_field parameter value,laputa|pm/generation.xsh|parameter|74|pure generation_sorted_unique parameter values,laputa|pm/generation.xsh|parameter|89|proc generation_require_profile_name parameter value,laputa|pm/generation.xsh|parameter|95|proc generation_require_overlay_path parameter value,laputa|pm/generation.xsh|parameter|95|proc generation_require_overlay_path parameter label,laputa|pm/generation.xsh|parameter|107|proc generation_validate_symlink_target parameter path_value,laputa|pm/generation.xsh|parameter|107|proc generation_validate_symlink_target parameter target,laputa|pm/generation.xsh|parameter|133|proc generation_validate_profile parameter value,laputa|pm/generation.xsh|parameter|151|proc generation_digest parameter value,laputa|pm/generation.xsh|parameter|178|proc generation_validate_plan parameter value,laputa|pm/generation.xsh|parameter|233|proc generation_runtime_artifacts parameter runtime_roots,laputa|pm/generation.xsh|parameter|308|pure generation_plan_dto parameter value,laputa|pm/generation.xsh|parameter|322|proc generation_plan_from_dto parameter value,laputa|pm/generation.xsh|parameter|412|proc generation_overlay_entries parameter overlay_root,laputa|pm/generation.xsh|parameter|454|pure generation_same_directory_metadata parameter entry,laputa|pm/generation.xsh|parameter|454|pure generation_same_directory_metadata parameter package_entry,laputa|pm/generation.xsh|parameter|463|pure generation_replacement_preserves_file_metadata parameter entry,laputa|pm/generation.xsh|parameter|464|pure generation_replacement_preserves_file_metadata parameter package_entry,laputa|pm/generation.xsh|parameter|476|proc generation_preflight_overlay parameter entries,laputa|pm/generation.xsh|parameter|477|proc generation_preflight_overlay parameter root_plan,laputa|pm/generation.xsh|parameter|478|proc generation_preflight_overlay parameter profile,laputa|pm/generation.xsh|parameter|535|proc generation_store_artifacts parameter value,laputa|pm/generation.xsh|parameter|535|proc generation_store_artifacts parameter store_root,laputa|pm/generation.xsh|parameter|568|proc generation_apply_overlay parameter output_root,laputa|pm/generation.xsh|parameter|568|proc generation_apply_overlay parameter entries,laputa|pm/generation.xsh|parameter|603|pure generation_artifact_dto parameter value,laputa|pm/generation.xsh|parameter|607|pure generation_receipt_dto parameter value,laputa|pm/generation.xsh|parameter|622|proc generation_artifact_from_dto parameter value,laputa|pm/generation.xsh|parameter|626|proc generation_receipt_from_dto parameter value,laputa|pm/generation.xsh|parameter|639|proc generation_validate_receipt parameter value,laputa|pm/generation.xsh|parameter|659|proc generation_receipt_for parameter value,laputa|pm/generation.xsh|parameter|660|proc generation_receipt_for parameter root_receipt
```

The fixed-compiler candidate adds one selector:

```text
laputa|pm/generation.xsh|parameter|232|proc generation_runtime_artifacts parameter value
```

`prepare_views.sh` rebuilt the original and reduced trees from `24de61dd0` and
`d1fda6c` and applied exactly these 37 Laputa spans. The XSH files are
unchanged. The reduced Laputa view digest is
`40b4d00500d1c38a9cb178e25de100fe0287b4ba4abcdaa53f31a1018e786e9e`
over 1,670 entries; the original is
`2972c5870784cdb55d32bc5001fefcdc3dc8f914d41d3b1fd6338dac47414aee`.
The old 12-Laputa-site view is superseded.

The applied-view receipt commands were:

```sh
bash dev/performance/corpus/prepare_views.sh \
  "$XSH_ROOT" 24de61dd0522083645d8e88fd00a8d9d49ac965a \
  "$LAPUTA_ROOT" d1fda6c722a2532184cf02edf07df1885d610c12 \
  "$INVENTORY" "$SITE_IDS" "$VIEWS"
bash dev/performance/corpus/check_views.sh \
  "$XSH_ROOT" 24de61dd0522083645d8e88fd00a8d9d49ac965a \
  "$XSH_ROOT" 24de61dd0522083645d8e88fd00a8d9d49ac965a \
  "$LAPUTA_ROOT" d1fda6c722a2532184cf02edf07df1885d610c12 \
  "$XSH" "$XSHT" "$XSH_SHA256" "$XSHT_SHA256" \
  "$INVENTORY" "$SITE_IDS" "$VIEWS"
```

`prepare_views.sh` returned 0. `check_views.sh` checked the 12 XSH and three
Laputa roots and the six exact behavior selectors in both views. Those root and
behavior checks passed. The Laputa interface gate then failed on private-helper
contract generalization and returned 2; that difference is recorded below.

## Applied-view interface difference

`xsht check --compare-with` compares the reduced Laputa view against the
original. It reports contract mismatches for 17 private helpers:

```text
generation_apply_overlay
generation_artifact_dto
generation_artifact_from_dto
generation_canonical_field
generation_digest
generation_plan_dto
generation_plan_from_dto
generation_preflight_overlay
generation_receipt_dto
generation_receipt_for
generation_receipt_from_dto
generation_replacement_preserves_file_metadata
generation_same_directory_metadata
generation_store_artifacts
generation_validate_plan
generation_validate_profile
generation_validate_receipt
```

Every candidate is a `forall` generalization of the original closed schema.
At the fixed-compiler candidate the list adds `generation_runtime_artifacts`,
for 18 private helpers total. No exported callable is in the mismatch set:
`compose`, `write_generation_plan`, `read_generation_plan`,
`read_generation_receipt`, and `read_generation_receipt_file` keep their
contracts. The XSH interface qualification passed. This is a private-helper
type-interface difference, not a runtime or exported-API difference; the
current `check_views.sh` gate therefore exits 2 for the applied view.

This difference is accepted. The generalized declarations are private helpers,
and the runtime behavior and exported contracts are unchanged. The interface
gate is recorded as a tool limitation, not a reason to retain the private
`proc` parameters. The pinned `24de61dd0` applied view stays at 37 sites; the
fixed-compiler view is 38.

The six callable probes tell the same story. The four XSH probes still reveal
`Pure`. Two Laputa private helpers change from `Pure` to generic callable
schemes:

```text
generation_sorted_unique: forall T0. pure(values: T0) -> List[Str]
generation_plan_dto: forall T0, R0, R1, R2. pure(value: {..}) -> GenerationPlanDto
```

Keeping private `proc` parameters in the applied view therefore preserves
behavior and exported contracts but not the inferred private contracts of the
helpers whose parameters are erased.

## Practical behavior

The reduced view was checked directly with the same products:

```sh
xsht check pm/plan_json.xsh pm/generation.xsh pm/generation_adapter.xsh
xsht test --exact 'tests/pm/pm_generation.xsh::test_generation_plan_and_receipt_are_deterministic_for_root_order_and_duplicates'
xsht test --exact 'tests/pm/pm_generation.xsh::test_generation_plan_json_round_trips_and_rejects_changed_identity'
```

Results:

```text
xsht check: 3 files, check and lower pass
test_generation_plan_and_receipt_are_deterministic_for_root_order_and_duplicates ... ok 142ms
test_generation_plan_json_round_trips_and_rejects_changed_identity ... ok 56ms
test result: ok. 1 passed; 0 failed; 0 skipped
```

No runtime behavior difference was observed. The two selectors exercise the
exported `compose` and `write_generation_plan` API, including the
`write_generation_plan.path_value` call site that retains its exported path
parameter. `pm/plan_json.xsh`, `pm/generation.xsh`, and
`pm/generation_adapter.xsh` all pass the reduced-view check.

## Residual failures

### `check.map-key-type` at `pm/generation.xsh:235:37`

```text
err[check.map-key-type]: Map comprehension keys require an ordered scalar key
  pm/generation.xsh:235:37
    var nodes: Map[types.PlanNode] = {node.name: node for node in value.nodes}
                                      ^^^^^^^^^ Map comprehension keys require an ordered scalar key
```

Site 32, line 232, `proc generation_runtime_artifacts` parameter
`value: types.BuildPlan`. Minimal erased set: site 32 alone.

Classification: missing inference and a G4 item. The local `Map[types.PlanNode]`
is `Map[Str, types.PlanNode]`, and the key expression is the `Str` field
`node.name`. With `value: types.BuildPlan` the comprehension item is a
`PlanNode`. Without it, `value.nodes` is unresolved, so the field read has no
resolved key type and the checker rejects the unresolved key instead of
deriving `Str`. This is a private helper that reads only `value.nodes`; no
public contract requires the annotation. After XSH fixes this class, re-run the
erasure: expect 38/38 private parameter sites and add site 32 to `SITE_IDS`.

Runnable witness:

```xsh
pure f(value) { {node.name: node for node in value.nodes} }
```

`xsht check` reports the same `check.map-key-type` diagnostic on the
comprehension.

### `check.type-mismatch` at `pm/generation.xsh:338:3`

```text
err[check.type-mismatch]: no registered method matches this body contract
  pm/generation.xsh:338:3
    path_value.write_atomic(json.encode(generation_plan_dto(value))? + "\n")
    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ no registered method matches this body contract
```

Site 54, line 335, `export proc write_generation_plan` parameter
`path_value: Path`. Minimal erased set: site 54 alone. This is a retained
exported contract. The parameter is part of an exported procedure's API and
declares a filesystem path.

Compiler class: an unresolved receiver used through `.parent` before a write
method does not ground the receiver, so the later write obligation has no
matching candidate. Replacing the first call with `p.mkdir()` makes the same
program pass, which isolates the `.parent` path. The gap is secondary because
the exported parameter is retained; no erasure is planned.

Runnable witness:

```xsh
proc f(p) [fs, error] {
  p.parent.mkdir()
  p.write_atomic("")
}
```

`xsht check` reports the same `check.type-mismatch` diagnostic at
`p.write_atomic("")`.

### `compact.indexed-build` at `pm/generation.xsh:725:3`

```text
err[compact.indexed-build]: this function cannot be compiled yet: generic expression is outside the supported parameter projection path
  pm/generation.xsh:725:3
    with staging_root = fs.tempdir_in(output_root.parent)? {
    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ this function cannot be compiled yet: generic expression is outside the supported parameter projection path
```

This is the all-parameter joint failure. Its minimal erased set is five
`value: types.GenerationPlan` parameters:

| Site | Line | Procedure |
| ---: | ---: | --- |
| 26 | 151 | `generation_digest` |
| 29 | 178 | `generation_validate_plan` |
| 80 | 535 | `generation_store_artifacts` |
| 97 | 659 | `generation_receipt_for` |
| 106 | 696 | `compose` |

The set is unique among those five: erasing any four passes. Erasing all five
leaves `compose` without an annotated callee that grounds `value`, so `compose`
stays generic and lowering rejects the `with` expression whose body carries the
type parameter.

Retention classification: exported-contract-only. Site 106 `compose.value` is
an exported contract and stays retained; `xsht check --compare-with` reports
`compose: contract mismatch` and `checked body contract mismatch` when it is
erased. Because it stays, the five-site joint is outside the applied view. The
four private members, sites 26, 29, 80, and 97, pass alone and in the 37-site
private joint and are in the applied view. The joint failure is not an
applied-view failure.

Runnable witness for the lowering class:

```xsh
proc f(value) [fs, error] { with t = fs.tempdir()? { value }? }
```

`xsht check` reports the same `compact.indexed-build` diagnostic.

Runnable Laputa witness for the exact five-site set:

```sh
scratch=.work/tmp/laputa-joint
rm -rf "$scratch" && mkdir -p "$scratch"
git -C /home/josh/d/laputa-systems/laputa archive d1fda6c | tar -x -C "$scratch"
cd "$scratch"
python3 - <<'PY'
from pathlib import Path

path = Path("pm/generation.xsh")
lines = path.read_text().splitlines(keepends=True)
for line in (151, 178, 535, 659, 696):
    lines[line - 1] = lines[line - 1].replace(": types.GenerationPlan", "")
path.write_text("".join(lines))
PY
"$XSHT" check pm/generation.xsh
```

The checker reaches the same `pm/generation.xsh:725:3` diagnostic.

## Retained-site classification

| Site | Line | Parameter | Visibility | Alone | Applied view | Classification | Reason |
| ---: | ---: | --- | --- | --- | --- | --- | --- |
| 32 | 232 | `generation_runtime_artifacts.value: types.BuildPlan` | private | fail at `24de61dd0`; pass at `732664cd1` | excluded at `24de61dd0`; included at `732664cd1` | fixed G4 `check.map-key-type` candidate | unresolved map comprehension key; add when `732664cd1` merges |
| 54 | 335 | `write_generation_plan.path_value: Path` | exported | fail | excluded | retained exported contract | exported path parameter; `.parent`/write gap is secondary |
| 26 | 151 | `generation_digest.value: types.GenerationPlan` | private | pass | included | applied | no contract; joint only with exported `compose.value` |
| 29 | 178 | `generation_validate_plan.value: types.GenerationPlan` | private | pass | included | applied | no contract; joint only with exported `compose.value` |
| 80 | 535 | `generation_store_artifacts.value: types.GenerationPlan` | private | pass | included | applied | no contract; joint only with exported `compose.value` |
| 97 | 659 | `generation_receipt_for.value: types.GenerationPlan` | private | pass | included | applied | no contract; joint only with exported `compose.value` |
| 106 | 696 | `compose.value: types.GenerationPlan` | exported | pass | excluded | retained exported contract | exported API; interface comparison fails when erased |

All 19 exported parameter annotations are retained as API contracts; sites 54
and 106 are the two with compiler witnesses. At the pinned `24de61dd0` compiler
the other 37 parameter sites are the applied private set above, and site 32 is
the only private parameter outside it. At the fixed-compiler candidate
`732664cd1`, site 32 passes alone and in the 38-site joint; it joins the
applied view when that commit is merged. Private `proc` returns, effect
clauses, and `Map`/`.require()` locals are retained by the same decision but
are outside this parameter table. No other parameter annotation is retained.

## XSH G4 handoff

| Missing-inference class | Witness | First diagnostic | Laputa set |
| --- | --- | --- | --- |
| Map comprehension key from an unresolved field read | `pure f(value) { {node.name: node for node in value.nodes} }` | `check.map-key-type` | 32, fixed by unmerged `732664cd1`; 38/38 at that commit, add on merge |
| Receiver grounding through `.parent` before a write | `proc f(p) [fs, error] { p.parent.mkdir(); p.write_atomic("") }` | `check.type-mismatch` | 54, exported contract; secondary gap, no erasure |
| `with` in a generic procedure | `proc f(value) [fs, error] { with t = fs.tempdir()? { value }? }` | `compact.indexed-build` | 26, 29, 80, 97, 106, exported-inclusive joint; outside the applied view because `compose.value` is retained |

Retain the exported `write_generation_plan.path_value: Path` and
`compose.value: types.GenerationPlan` annotations as contracts. The applied
private parameters remain in the applied view even though their helper
contracts generalize; the four private `GenerationPlan value` annotations are
not retained once `compose.value` stays. Merge `732664cd1` and pin the merged
XSH `master`, at which point `SITE_IDS` becomes 38. Re-run after the current
`rm` slice and each later compiler slice; the `rm` slice is gated now.

## Frozen 1,040 view

The frozen view is separate from the practical cohort. Its denominator and
retained table are unchanged.

| Item | Value |
|---|---|
| XSH source | `ddc17d3d53c819c343f9ecaa738ac67d59e9033a`, tree `a86e818c2d7e7c725266ecec3231a951e817546f` |
| Laputa source | `ca658ce1da9d89c55209c25268dfdf687ff4fdc6`, tree `a086629b1b54499e0f7b43082c73416a7dfe155d` |
| Retained table | `15243e97f6fd751016ab28690ada2cadb6fc973a`, tree `9a9c054ea1ef1b34d90c641756cb020f2205ebf0`; 1,843 rows plus header, sha256 `f8cfd371e7c435bd23013e49943607b856c5e93a6267b175731821b1200f9083` |
| Accepting compiler | `0fe1469d1808b5f963bd841165af6c10f2c3e93b`, tree `79fdb956ee01e3bf4cced9b85ff109bcb8b7d662` |
| Frozen check products | `xsh` sha256 `3e4c404b1db7a017cd30864360f6b88c6d6f169d2a8f2de35c05621149a63ae1`; `xsht` sha256 `a2c639cf368b128018a27f87ebc7cfda52ce9463dcb9f58a67ea9eac8413b4d9`; both built from `0fe1469d` |
| Original view | 14,287 entries, sha256 `e3429dcf2abe9524754a28458651443bc56523b50130268a1c1ff44c03e36899` |
| Accepted reduced view | 14,287 entries, sha256 `b67b498467a1dfe613573690288a8c514b9c03d0f895a4a3b20e4fd3b55968f9` |

The view held 9,194 AST sites in 48 loaded files from eleven roots. The accepted
view removes 499 locals and 541 internal annotations, 1,040 removals total. The
149 `Map[...] = {}` annotations and all 202 private effect clauses remain
retained. The reconstructed digests match the recorded frozen digests.

The Laputa side is `pm/plan_json.xsh` at `ca658ce1`: original sha256
`cad62a65c5537ce5b24ac1ad8b69b94baca6d4a31bc6e2ecbc3f656bbb001a77`,
reduced sha256
`d37d9a1f399fa28dc7925ec508f76e6aafa1346112ff11501e0603896f49bfce`.
The retained table, denominator, and view digests were not changed.

The current `check_views.sh` at `24de61dd0` cannot drive the frozen check with
the accepting `0fe1469d` products:

```text
xsht: unknown `xsht check` option '--compare-with'
```

XSH `0fe1469d` predates paired interface qualification. The frozen-era adapter
`d5f7b6267`, run from its own checkout with its cohort, fixture, witness, and
tree-comparison helpers, is contemporaneous with that compiler. With the same
XSH and Laputa sources, retained table, views, and `0fe1469d` products it
passes:

```sh
bash dev/performance/corpus/check_views.sh --frozen \
  "$COMPILER_ROOT" 0fe1469d1808b5f963bd841165af6c10f2c3e93b \
  "$XSH_ROOT" ddc17d3d53c819c343f9ecaa738ac67d59e9033a \
  "$LAPUTA_ROOT" ca658ce1da9d89c55209c25268dfdf687ff4fdc6 \
  "$XSH_PRODUCT" "$XSHT_PRODUCT" "$XSH_SHA256" "$XSHT_SHA256" \
  "$RETAINED" "$VIEWS" \
  --selector xsh 'tests/xsh/system-report.xsh::test_system_report_memory_reports_malformed_and_oversized_meminfo_fields' \
  --selector laputa 'tests/pm/pm_generation.xsh::test_generation_plan_and_receipt_are_deterministic_for_root_order_and_duplicates'
```

```text
paired frozen corpus: 11 roots and 2 exact selectors passed in both views
```

This pin is accepted: the frozen check stays with the `d5f7b6267` adapter and
`0fe1469d` products. A newer adapter pin is not needed for the frozen
checkpoint; the current adapter's `--compare-with` requirement is recorded as a
tooling limit.

The historical 1,040 receipt recorded products `xsh`
`38b848c828591d6aa46a902d0404dfe42298e36cc2a6c6512eb2af9c1f460736` and
`xsht` `23ca0dd9ccb8b9723f41d199ab41d4a242c90c96277ce83e13b002e67b23a2b2`
for the accepting compiler. The check above used a fresh source-qualified build
of the same revision and records its own product hashes.

## Limits

The practical measurement uses `xsht check`, including lowering, plus the
behavior selectors above, not full runtime or installer coverage. It covers the
practical erasure root only. No XSH edit and no push were made. The frozen
denominator and retained table were not changed.

The `check.map-key-type` fix is verified at unmerged `732664cd1`; merge it and
pin the merged XSH `master` to make `SITE_IDS` 38. The current `rm` slice and
each later compiler slice remain gated re-runs. Keep the
`write_generation_plan.path_value` `.parent` witness and the `compose.value`
`--compare-with` evidence as exported-contract and secondary compiler gaps; do
not erase them. The applied view's private-helper contract generalization is an
accepted interface difference, not a runtime behavior difference.
