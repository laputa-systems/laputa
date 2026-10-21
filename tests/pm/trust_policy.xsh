use trust.policy as trust_policy

test trust_policy_accepts_the_incident_blocks_and_empty_policy {
  let installed = trust_policy.parse(p"packages/ca-certificates/files/trust-policy".read_bytes()?)?
  assert installed.generation == "1"
  assert installed.blocked_spki_sha256 == [
    "43bffa19d6ef651451f6841e019931e96f6f2eaeff28ab4b6f1ce4576de2717b",
    "49dd353dc2b919a3770645117d0e60c16115e7d1bc259eefe734b00ea434fe5f",
    "5c0660a2b164910d8ff589c18e14552e9e0ec237dcefe2cb736d41a4811f81a0",
    "63ecefee431d49523bc1136c4e72d0206a477086caf606cd5cf025686c109cf8",
    "e0254c7fcdc265e2f0f8a428dabb75ab4ae039b4872d62f5ee57f0877d5a8a41",
    "ebed6475c2c2d80fcb199f3fe8dd6e6b3ce60b77eb15d4e42c3dec0c6f5b5105",
  ]

  let empty = trust_policy.parse(bytes.from_text("laputa-trust-policy-v1\ngeneration 2\n"))?
  assert empty.generation == "2" and empty.blocked_spki_sha256.is_empty()
  assert trust_policy.policy_u64_text_is_valid("18446744073709551615")
  assert ! trust_policy.policy_u64_text_is_valid("18446744073709551616")
  assert ! trust_policy.policy_u64_text_is_valid("01")
  assert ! trust_policy.policy_u64_text_is_valid("0")
  assert trust_policy.policy_u64_is_greater("10", "9")
  assert ! trust_policy.policy_u64_is_greater("9", "10")
}

test trust_policy_rejects_noncanonical_or_ambiguous_lines {
  let duplicate = "laputa-trust-policy-v1\ngeneration 1\nblocked-spki-sha256 43bffa19d6ef651451f6841e019931e96f6f2eaeff28ab4b6f1ce4576de2717b\nblocked-spki-sha256 43bffa19d6ef651451f6841e019931e96f6f2eaeff28ab4b6f1ce4576de2717b\n"
  for body in [
    "laputa-trust-policy-v1\ngeneration 1",
    "laputa-trust-policy-v1\ngeneration 0\n",
    "laputa-trust-policy-v1\ngeneration 01\n",
    "laputa-trust-policy-v1\ngeneration 18446744073709551616\n",
    "laputa-trust-policy-v1\ngeneration 1\nunknown-field value\n",
    "laputa-trust-policy-v1\ngeneration 1\nblocked-spki-sha256 43BFFA19D6EF651451F6841E019931E96F6F2EAEFF28AB4B6F1CE4576DE2717B\n",
    duplicate,
    "laputa-trust-policy-v1\r\ngeneration 1\r\n",
  ] {
    assert trust_policy.parse(bytes.from_text(body)) is Err(_)
  }
}
