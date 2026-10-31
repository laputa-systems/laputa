##! Remote file staging and validation.

use xinfra.remote as remote
use xinfra.secret as secret
use xinfra.transport as transport
use xinfra.validate

## Stream a prepared source into an owned staging path.
export proc write(
  session: transport.Session,
  destination: Path,
  source: validate.PreparedSource,
  elevate: List[Str] = [],
) -> Result[Unit, Error] {
  match source {
    validate.Local(value) => {
      let result = match transport.upload_file(session, destination, value.path, 180000, elevate) {
        Ok(value) => value,
        Err(message) => { return Err(error.failure(message)) },
      }
      return Err(error.failure(result.stderr.utf8() ?? "")) when result.exit_code != 0
      Ok()
    }
    validate.Content(value) => {
      let result = match transport.write_bytes(session, destination, bytes.from_text(value.text), 60000, elevate) {
        Ok(value) => value,
        Err(message) => { return Err(error.failure(message)) },
      }
      return Err(error.failure(result.stderr.utf8() ?? "")) when result.exit_code != 0
      Ok()
    }
    validate.Templated(value) => {
      let result = match transport.write_bytes(session, destination, bytes.from_text(value.text), 60000, elevate) {
        Ok(value) => value,
        Err(message) => { return Err(error.failure(message)) },
      }
      return Err(error.failure(result.stderr.utf8() ?? "")) when result.exit_code != 0
      Ok()
    }
    validate.Secret(reference) => {
      let data = secret.resolve(reference)?
      let result = match transport.write_bytes(session, destination, data, 60000, elevate) {
        Ok(value) => value,
        Err(message) => { return Err(error.failure(message)) },
      }
      if result.exit_code != 0 {
        return Err(error.failure(result.stderr.utf8() ?? ""))
      }
      match remote.set_metadata(session, destination, 0o600, null, null, elevate) {
        Ok(_) => Ok(),
        Err(failure) => Err(failure),
      }
    }
  }
}

## Run one validator argv with the staged path appended.
export proc validate(
  session: transport.Session,
  argv: List[Str],
  staged: Path,
  elevate: List[Str] = [],
) -> Result[Unit, Error] {
  if argv.is_empty() {
    return Err(error.failure("validator argv is empty"))
  }
  var command = argv
  command += [staged.display()]
  let result = match transport.exec(session, elevate + command, 60000) {
    Ok(value) => value,
    Err(message) => { return Err(error.failure(message)) },
  }
  return Err(error.failure(result.stderr.utf8() ?? "")) when result.exit_code != 0
  Ok()
}
