##! XSH module `PKGBUILD` package and build operations.
## Package recipe export.
export const name = "libseat"

## Explicit payload or metapackage classification.
export const package_kind = "meta"

## Exported declaration `ver`.
export const ver = "0.9.3"

## Exported declaration `rel`.
export const rel = "8"

## Exported declaration `deps`.
export const deps = ["seatd"]

## Exported declaration `mkdeps_host`.
export let mkdeps_host = []

## Exported declaration `upstream_sources`.
export let upstream_sources = []

## Exported declaration `filetree`.
export let filetree = []
