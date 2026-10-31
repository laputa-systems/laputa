#!/bin/sh
set -eu

prefix=${1:-${PREFIX:-/usr/local}}
case $prefix in
  /*) ;;
  *) prefix=$(pwd)/$prefix ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
libexec="$prefix/libexec/xinfra"

mkdir -p "$libexec" "$prefix/bin"
cp -R "$script_dir/bin" "$libexec/"
cp -R "$script_dir/lib" "$libexec/"
cp -R "$script_dir/docs" "$libexec/"
cp -R "$script_dir/examples" "$libexec/"
cp "$script_dir/xsht-config.ini" "$libexec/"
cp "$script_dir/README.md" "$libexec/"
cp "$script_dir/NOTICE" "$libexec/"
cp "$script_dir/LICENSE" "$libexec/"

cat > "$prefix/bin/xinfra" <<WRAPPER
#!/bin/sh
exec "\${XSH:-xsh}" "$libexec/bin/xinfra.xsh" "\$@"
WRAPPER
chmod 755 "$prefix/bin/xinfra"

printf 'installed xinfra under %s\n' "$libexec"
