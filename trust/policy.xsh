##! Strict reader for the installed Laputa TLS distrust policy.

## Policy input failed its versioned line contract.
export error PolicyError = InvalidData(message: Str)

## A parsed distrust generation and its blocked SubjectPublicKeyInfo digests.
export type TrustPolicy = {generation: Str, blocked_spki_sha256: List[Str]}

pure policy_sha256_is_valid(value: Str) -> Bool {
  value.byte_len() == 64 and value == value.lower() and value.delete("0123456789abcdef") == ""
}

## Whether `value` is a canonical positive unsigned 64-bit decimal string.
export pure policy_u64_text_is_valid(value: Str) -> Bool {
  let length = value.byte_len()
  if length == 0 or length > 20 or value.starts_with("0") {
    return false
  }

  if value.delete("0123456789") != "" {
    return false
  }

  length < 20 or value <= "18446744073709551615"
}

## Whether canonical unsigned decimal `left` is greater than `right`.
export pure policy_u64_is_greater(left: Str, right: Str) -> Bool {
  left.byte_len() > right.byte_len() or (left.byte_len() == right.byte_len() and left > right)
}

## Parses one strict UTF-8 policy with a trailing LF and unique lowercase hashes.
export proc parse(data: Bytes) [error] -> Result[TrustPolicy, Error] {
  guard ! data.is_empty() and data.len() <= 1048576 else {
    return Err(PolicyError.InvalidData("policy size is invalid"))
  }

  let text = data as Str
  guard text.ends_with("\n") and "\r" not in text else {
    return Err(PolicyError.InvalidData("policy must use LF-terminated UTF-8 lines"))
  }

  let lines = text.byte_slice(0, text.byte_len() - 1).split("\n")
  guard lines.len() >= 2 and lines[0] == "laputa-trust-policy-v1" else {
    return Err(PolicyError.InvalidData("policy header is invalid"))
  }

  let generation_fields = lines[1].split(" ")
  guard generation_fields.len() == 2 and generation_fields[0] == "generation" and policy_u64_text_is_valid(generation_fields[1]) else {
    return Err(PolicyError.InvalidData("policy generation is invalid"))
  }

  var blocked: List[Str] = []
  var seen: Set[Str] = set.empty()
  for line in lines[2..lines.len()] {
    let fields = line.split(" ")
    guard fields.len() == 2 and fields[0] == "blocked-spki-sha256" and policy_sha256_is_valid(fields[1]) else {
      return Err(PolicyError.InvalidData("policy contains an unknown or malformed field"))
    }

    guard fields[1] not in seen else {
      return Err(PolicyError.InvalidData("policy repeats a blocked SPKI hash"))
    }

    blocked += [fields[1]]
    seen = seen.add(fields[1])
  }

  {generation: generation_fields[1], blocked_spki_sha256: blocked}
}
