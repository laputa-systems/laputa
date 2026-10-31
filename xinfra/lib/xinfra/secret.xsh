##! Secret references resolved only at apply time.

use xinfra.model
use xinfra.redact
use xinfra.validate

## Resolve one secret reference to bytes.
export proc resolve(reference: model.SecretRef) [fs, env, error] -> Result[Bytes, Error] {
  match reference {
    model.FromEnv(name) => {
      let value = env.get(name)?
      Ok(bytes.from_text(value))
    }
    model.FromFile(source_path) => {
      let metadata = source_path.metadata()?
      if metadata.mode.bit_and(0o077) != 0 {
        return Err(error.failure(f"secret file {source_path.display()} is group- or world-readable"))
      }
      source_path.read_bytes()
    }
  }
}

## Digest the exact bytes a prepared source contributes.
export proc digest(source: validate.PreparedSource) [fs, env, error] -> Result[Str, Error] {
  match source {
    validate.Local(value) => Ok(value.digest),
    validate.Content(value) => Ok(value.digest),
    validate.Templated(value) => Ok(value.digest),
    validate.Secret(reference) => Ok(hash.sha256(resolve(reference)?).hex()),
  }
}

## Collects every resolvable secret value for output redaction.
export proc redactor(deployment: validate.Deployment) [fs, env, error] -> redact.Redactor {
  var result = redact.empty()
  for source in deployment.sources.values() {
    match source {
      validate.Secret(reference) => {
        match resolve(reference) {
          Ok(value) => {
            match value.utf8() {
              Ok(text) => { result = redact.with_secret(result, text) },
              Err(_) => {}
            }
          }
          Err(_) => {}
        }
      }
      _ => {}
    }
  }
  result
}

## Whether a prepared source resolves a secret at apply time.
export pure is_secret(source: validate.PreparedSource) -> Bool {
  match source {
    validate.Secret(_) => true,
    _ => false,
  }
}
