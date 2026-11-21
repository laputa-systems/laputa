##! Canonical text encoding and SHA-256 identities used by durable records.

## Whether text is a lowercase hexadecimal SHA-256 digest.
export pure digest_is_sha256(value: Str) -> Bool {
  value.byte_len() == 64 and value == value.lower() and value.delete("0123456789abcdef") == ""
}

## Escape one field in a canonical tab-separated record.
export pure digest_canonical_field(value: Str) -> Str {
  value.replace("\\", with: "\\\\").replace("\t", with: "\\t").replace("\n", with: "\\n")
}

## Hash sorted record lines with the durable final newline.
export proc digest_sorted_lines(lines: List[Str]) [error] -> Result[Str, Error] {
  bytes.from_text((lines |> sort).join("\n") + "\n").sha256().hex()
}
