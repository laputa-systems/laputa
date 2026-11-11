##! The controller side of file content: measuring it for comparison and
##! choosing how its bytes reach the host.

use infra.compare
use infra.model

## Read what a content source holds, as a digest and size. A local file is
## hashed as a stream and never loaded; a missing file or unset variable is an
## error before any mutation.
export proc measure(content: model.Content) [fs, env, error] -> Result[compare.Material, Error] {
  match content {
    model.Inline(data) => Ok(compare.Material(digest: hash.sha256(data).hex(), size: data.len()))
    model.FromFile(source) => {
      ctx f"reading {source}" {
        let digest = hash.sha256(source)?
        Ok(compare.Material(digest: digest.hex(), size: source.metadata()?.size))
      }
    }
    model.SecretEnv(name) => {
      let text = ctx f"environment variable {name}" { env.get(name)? }
      let data = bytes.from_text(text)
      Ok(compare.Material(digest: hash.sha256(data).hex(), size: data.len()))
    }
    model.Rendered(source) => {
      let data = render(source)?
      Ok(compare.Material(digest: hash.sha256(data).hex(), size: data.len()))
    }
  }
}

proc render(source: model.TemplateSource) [fs, error] -> Result[Bytes, Error] {
  ctx f"rendering {source.file}" {
    let text = source.file.read_text()?
    let data = json.decode(source.json)?
    Ok(bytes.from_text(template.render(text, data)?))
  }
}

## The bytes of an in-memory source, or none for a file that is streamed.
export proc inline_bytes(content: model.Content) [fs, env, error] -> Result[Bytes?, Error] {
  match content {
    model.Inline(data) => Ok(data)
    model.FromFile(_) => Ok(null)
    model.SecretEnv(name) => Ok(bytes.from_text(env.get(name)?))
    model.Rendered(source) => Ok(render(source)?)
  }
}

## The local file a source streams from, or none for an in-memory source.
export pure streamed_path(content: model.Content) -> Path? {
  match content {
    model.FromFile(source) => source
    else => null
  }
}
