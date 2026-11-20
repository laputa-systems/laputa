#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
. "$root/tests/differential/symbols.sh"
mkdir -p "$root/.work/tmp"
scratch=$(mktemp -d "$root/.work/tmp/symbols.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
for directory in first second; do
  mkdir "$scratch/$directory"
  printf 'int marker(void) { return 0; }\nint main(void) { return marker(); }\n' > "$scratch/$directory/input.c"
  "${CC:-cc}" -g "$scratch/$directory/input.c" -o "$scratch/$directory/app"
  defined_symbols "$scratch/$directory/app" > "$scratch/$directory/symbols"
done
test -s "$scratch/first/symbols"
cmp "$scratch/first/symbols" "$scratch/second/symbols"
printf 'int other(void) { return 0; }\nint main(void) { return other(); }\n' > "$scratch/second/input.c"
"${CC:-cc}" -g "$scratch/second/input.c" -o "$scratch/second/app"
defined_symbols "$scratch/second/app" > "$scratch/second/symbols"
if cmp -s "$scratch/first/symbols" "$scratch/second/symbols"; then
  echo 'different defined symbols compared equal' >&2
  exit 1
fi

"${CC:-cc}" -c "$scratch/first/input.c" -o "$scratch/first/original.o"
"${CC:-cc}" -c "$scratch/first/input.c" -o "$scratch/second/renamed.o"
ar rcs "$scratch/first/archive.a" "$scratch/first/original.o"
ar rcs "$scratch/second/archive.a" "$scratch/second/renamed.o"
defined_symbols "$scratch/first/archive.a" > "$scratch/first/archive-symbols"
defined_symbols "$scratch/second/archive.a" > "$scratch/second/archive-symbols"
test -s "$scratch/first/archive-symbols"
cmp "$scratch/first/archive-symbols" "$scratch/second/archive-symbols"

mkdir "$scratch/failing"
printf '#!/bin/sh\nprintf "partial T 0 0\\n"\nexit 7\n' > "$scratch/failing/nm"
chmod +x "$scratch/failing/nm"
if (set +o pipefail; PATH="$scratch/failing:$PATH" defined_symbols "$scratch/first/app") > "$scratch/failed-symbols"; then
  echo 'accepted a failed symbol extraction' >&2
  exit 1
fi
test ! -s "$scratch/failed-symbols"
