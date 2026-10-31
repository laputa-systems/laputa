# Inference erasure

This reference records parameter-annotation erasure for Laputa's practical
root. It separates annotations that are contracts from annotations the compiler
cannot infer yet, and gives a runnable witness for each compiler class.

## Pins

| Item | Value |
|---|---|
| Laputa | `aa947851c4048f2d3ae5e1302e2738afdd4a181a`, tree `a3cd2b3772c7f08a7e0c938ed8c81e4d7386e397` |
| XSH compiler | `db4cffc3bad2e52edec161369c57ece4f2ba75eb`, tree `dbc606733de0f6667661b7538f61182bbad1221e` |
| Built `xsht` | sha256 `522efce063e0be5ad990cab4050ef928520bede789543bea29066da388457dd7` |
| Laputa practical root | `pm/generation.xsh` |
| Parameter sites | 57: 38 private and 19 exported |

XSH `abc9619e8` was still on `inference/optional-argument` and not merged into
`master`, so this measurement uses `db4cffc3b`. XSH `master` at `f18496fbc`
differs from that commit only in `full-inference-campaign.md`.

The only Laputa root in the practical inventory is `pm/generation.xsh`. Laputa
`pm/plan_json.xsh` belongs to the frozen 1,040-annotation view and was not
touched. `pm/generation_adapter.xsh` and `tests/pm/pm_generation.xsh` are
behavior-checked by the practical adapter but are not erasure roots.

## Measurement

The inventory came from the pinned `dev/performance/corpus/inventory.rs` with
`laputa` rooted at the Laputa revision. The erasure used the pinned
`dev/performance/corpus/erase_sites.py` against a `git archive` export of that
revision and the `xsht` built from the XSH pin:

```sh
git -C /home/josh/d/laputa-systems/xsh archive db4cffc3b | tar -x -C "$SCRATCH/src/xsh"
(cd "$SCRATCH/src/xsh" && CARGO_TARGET_DIR="$SCRATCH/target" \
  cargo build --offline --profile verification -p xsht)

cd "$SCRATCH/src/xsh/dev/performance/corpus"
python3 -B erase_sites.py "$SCRATCH/laputa-parameter-sites.tsv" \
  --root "laputa=$SCRATCH/export/laputa" \
  --xsht "$SCRATCH/target/verification/xsht" \
  --scratch "$SCRATCH/erase" --jobs 8 --timeout 300
```

The 57 parameter sites produce:

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

The private-only scope has 38 sites: 37 of 38 erase alone, and the joint erasure
of the 37 that pass alone succeeds. The applied practical views accept only
private `pure` type annotations (`apply_spans.py` rejects exported sites and
`proc` declarations), so their 12 Laputa parameter sites all erase alone and
jointly. The remaining rows below are `proc` parameters outside the applied
view, or exported parameters outside it as well.

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

Classification: missing inference. The local `Map[types.PlanNode]` is
`Map[Str, types.PlanNode]`, and the key expression is the `Str` field
`node.name`. With `value: types.BuildPlan` the comprehension item is a
`PlanNode`. Without it, `value.nodes` is unresolved, so the field read has no
resolved key type and the checker rejects the unresolved key instead of
deriving `Str`. This is a private helper that reads only `value.nodes`; no
public contract requires the annotation.

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
`path_value: Path`. Minimal erased set: site 54 alone.

Retention classification: intentional contract. The parameter is part of an
exported procedure's API and declares a filesystem path. The single-site
failure is a separate missing-inference class that matters only if exported
parameters become eligible for erasure.

Compiler class: an unresolved receiver used through `.parent` before a write
method does not ground the receiver, so the later write obligation has no
matching candidate. Replacing the first call with `p.mkdir()` makes the same
program pass, which isolates the `.parent` path.

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

This is the joint failure. Its minimal erased set is five `value:
types.GenerationPlan` parameters:

| Site | Line | Procedure |
|---:|---:|---|
| 26 | 151 | `generation_digest` |
| 29 | 178 | `generation_validate_plan` |
| 80 | 535 | `generation_store_artifacts` |
| 97 | 659 | `generation_receipt_for` |
| 106 | 696 | `compose` |

The set is unique among those five: erasing any four passes. Erasing all five
leaves `compose` without an annotated callee that grounds `value`, so `compose`
stays generic and lowering rejects the `with` expression whose body carries the
type parameter.

Retention classification: site 106 is an intentional contract. `compose` is
exported, and `xsht check --compare-with` reports `compose: contract mismatch`
and `checked body contract mismatch` when its `value: types.GenerationPlan`
annotation is erased. Keeping that one annotation removes the joint failure and
leaves the other four private annotations erasable. Sites 26, 29, 80 and 97 are
missing inference only in the all-parameter erasure; they pass alone and in the
private-only joint.

Runnable witness for the lowering class:

```xsh
proc f(value) [fs, error] { with t = fs.tempdir()? { value }? }
```

`xsht check` reports the same `compact.indexed-build` diagnostic.

Runnable Laputa witness for the exact five-site set:

```sh
scratch=.work/tmp/laputa-joint
rm -rf "$scratch" && mkdir -p "$scratch"
git -C /home/josh/d/laputa-systems/laputa archive aa947851 | tar -x -C "$scratch"
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

| Site | Line | Parameter | Visibility | Alone | Joint role | Classification | Reason |
|---:|---:|---|---|---|---|---|---|
| 32 | 232 | `generation_runtime_artifacts.value: types.BuildPlan` | private | fail | — | missing inference | unresolved map comprehension key |
| 54 | 335 | `write_generation_plan.path_value: Path` | exported | fail | — | intentional contract | exported path parameter; compiler gap is secondary |
| 26 | 151 | `generation_digest.value: types.GenerationPlan` | private | pass | member | missing inference | no contract; erasable once `compose.value` stays |
| 29 | 178 | `generation_validate_plan.value: types.GenerationPlan` | private | pass | member | missing inference | no contract; erasable once `compose.value` stays |
| 80 | 535 | `generation_store_artifacts.value: types.GenerationPlan` | private | pass | member | missing inference | no contract; erasable once `compose.value` stays |
| 97 | 659 | `generation_receipt_for.value: types.GenerationPlan` | private | pass | member | missing inference | no contract; erasable once `compose.value` stays |
| 106 | 696 | `compose.value: types.GenerationPlan` | exported | pass | member | intentional contract | exported API; interface comparison fails when erased |

The other 50 parameter sites erase alone and are not retained. The root has no
optional, nominal `Error`, or CLI-entry parameter annotation, so the two
exported annotations are the only contract retentions.

## XSH G4 handoff

| Missing-inference class | Witness | First diagnostic | Laputa set |
|---|---|---|---|
| Map comprehension key from an unresolved field read | `pure f(value) { {node.name: node for node in value.nodes} }` | `check.map-key-type` | 32 |
| Receiver grounding through `.parent` before a write | `proc f(p) [fs, error] { p.parent.mkdir(); p.write_atomic("") }` | `check.type-mismatch` | 54 |
| `with` in a generic procedure | `proc f(value) [fs, error] { with t = fs.tempdir()? { value }? }` | `compact.indexed-build` | 26, 29, 80, 97, 106 |

Retain the exported `write_generation_plan.path_value: Path` and
`compose.value: types.GenerationPlan` annotations as contracts. The four private
`GenerationPlan value` annotations are not retained once `compose.value` stays,
so they do not belong in the compiler queue. The joint failure requires `proc`
parameters, which the applied practical views reject, so it does not block the
current G4 views; it is a real gap if `proc` parameters become eligible.

## Limits

The measurement uses `xsht check`, including lowering and verification, not
runtime behavior. It covers the practical erasure root only; the frozen 1,040
view, XSH sources, and other Laputa roots were not changed. No XSH edit and no
push were made.
