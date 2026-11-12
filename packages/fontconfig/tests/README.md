# Check Fontconfig reproducibility

Resolve one Fontconfig plan with the package-tools environment described in
[Development](../../../docs/DEVELOPMENT.md). Prepare two separate stores containing
the plan's verified dependency and proof artifacts. Omit Fontconfig from both
stores so both builds compile it.

Run the same plan against each store:

```sh
xsh pm.xsh -- repo build "$PLAN" --store "$FIRST_STORE" -j 1
xsh pm.xsh -- repo build "$PLAN" --store "$SECOND_STORE" -j 1
```

Extract each library into its own payload root:

```sh
xsh pm.xsh -- store extract "$PLAN" --store "$FIRST_STORE" --package fontconfig \
  --path usr/lib/libfontconfig.so.1.17.0 --output "$FIRST_ROOT/usr/lib/libfontconfig.so.1.17.0"
xsh pm.xsh -- store extract "$PLAN" --store "$SECOND_STORE" --package fontconfig \
  --path usr/lib/libfontconfig.so.1.17.0 --output "$SECOND_ROOT/usr/lib/libfontconfig.so.1.17.0"
```

Keep the dependency receipts and executor identical. Neither build may reuse the
other's objects or ELF output. Use different absolute paths for both builds.

From `packages/fontconfig`, run the focused native regression with absolute roots:

```sh
LAPUTA_FONTCONFIG_REPRO_FIRST_ROOT="$FIRST_ROOT" \
LAPUTA_FONTCONFIG_REPRO_SECOND_ROOT="$SECOND_ROOT" \
  xsht test tests/reproducibility.xsh
```

The test compares the complete ELF bytes and checks that assertion diagnostics
retain their source filenames relative to the source root.
