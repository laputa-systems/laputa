##! Contract coverage for the libdisplay-info recipe's port of gen-search-table.py.
use packages.libdisplay-info.PKGBUILD as libdisplay_info_recipe

test test_pnp_table_keys_ids_by_their_bytes [error] { |_|
  let source = libdisplay_info_recipe.pnp_id_table_source("DEL\tDell Inc.\nAAA\tAAA Corp\n")

  # "AAA" is 0x414141 and "DEL" is 0x44454c; the full name survives even when
  # it repeats the ID, and the cases are sorted by ID.
  assert """    case 4276545: return "AAA Corp";
    case 4474188: return "Dell Inc.";""" in source
}

test test_pnp_table_keeps_the_last_name_and_skips_malformed_ids [error] { |_|
  let source = libdisplay_info_recipe.pnp_id_table_source("ABC\tFirst\nABCD\tToo long\nABC\tSecond\n")

  assert """return "Second";""" in source
  assert "First" not in source
  assert "Too long" not in source
}

test test_pnp_table_escapes_bytes_outside_plain_text [error] { |_|
  let source = libdisplay_info_recipe.pnp_id_table_source("CAF\tSoftware Café??=\n")

  # Each byte of the UTF-8 name is escaped on its own, so the C string keeps
  # the name's bytes, and `?` cannot start a trigraph.
  assert r"""return "Software Caf\303\251\077\077\075";""" in source
}
