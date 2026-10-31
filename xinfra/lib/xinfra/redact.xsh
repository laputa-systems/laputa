##! Exact-secret redaction for human and structured output.

## One run's known secret values, never written to output.
export type Redactor = {secrets: List[Str] = []}

## Returns a redactor with no known secrets.
export pure empty() -> Redactor {
  Redactor(secrets: [])
}

pure insert_longest_first(value: Str, values: List[Str]) -> List[Str] {
  var ordered: List[Str] = []
  var placed = false
  for item in values {
    if ! placed and value.byte_len() > item.byte_len() {
      ordered += [value]
      placed = true
    }

    ordered += [item]
  }

  if ! placed {
    ordered += [value]
  }

  ordered
}

pure ordered(secrets: List[Str]) -> List[Str] {
  var result: List[Str] = []
  for secret in secrets {
    if ! secret.is_empty() and ! (secret in result) {
      result = insert_longest_first(secret, result)
    }
  }

  result
}

## Adds one exact secret value to a redactor.
export pure with_secret(redactor: Redactor, secret: Str) -> Redactor {
  Redactor(secrets: redactor.secrets + [secret])
}

## Replaces every known secret value with a fixed marker.
export pure redact(text: Str, redactor: Redactor) -> Str {
  var result = text
  for secret in ordered(redactor.secrets) {
    result = result.replace(secret, with: "[redacted]")
  }

  result
}
