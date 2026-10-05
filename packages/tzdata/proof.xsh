##! XSH module `proof` package and build operations.
use pm.proof
use pm.util as pm_util

# The program formats two fixed instants, one in northern winter and one in
# northern summer, through localtime_r and strftime, so each zone must yield
# its standard and daylight offsets and abbreviations. musl loads an absolute
# TZ path as a TZif file, which points it at the proof root's zoneinfo rather
# than the container's.
#
# tzdata has no runtime dependencies, so the proof root holds no libc to link
# against. The program is therefore built with `--sysroot=/` against the
# proof container's own musl; the libc that reads the zones is musl either
# way, and only the TZif files under test come from the proof root.
const program = r"""#include <stdio.h>
#include <time.h>

int main(void) {
  const time_t instants[] = {1768478400, 1782907200}; /* 2026-01-15 and 2026-07-01, 12:00 UTC */
  char text[64];
  struct tm local;
  tzset();
  for (int i = 0; i < 2; i++) {
    if (!localtime_r(&instants[i], &local) || !strftime(text, sizeof text, "%Y-%m-%d %H:%M:%S %Z %z", &local)) {
      return 1;
    }
    puts(text);
  }
  return 0;
}
"""

const expected = [
  {
    zone: "Europe/Berlin",
    output: "2026-01-15 13:00:00 CET +0100\n2026-07-01 14:00:00 CEST +0200\n",
  },
  {
    zone: "America/New_York",
    output: "2026-01-15 07:00:00 EST -0500\n2026-07-01 08:00:00 EDT -0400\n",
  },
  {
    zone: "US/Eastern",
    output: "2026-01-15 07:00:00 EST -0500\n2026-07-01 08:00:00 EDT -0400\n",
  },
  {
    zone: "Asia/Tokyo",
    output: "2026-01-15 21:00:00 JST +0900\n2026-07-01 21:00:00 JST +0900\n",
  },
]

const tables = ["iso3166.tab", "leap-seconds.list", "leapseconds", "zone.tab", "zone1970.tab", "zonenow.tab"]

proc main(root: Path = /rootfs) [fs, process, env, error] {
  proof.package_metadata(root, "tzdata")
  let zoneinfo = fp"{root}/usr/share/zoneinfo"

  for table in tables {
    proof.ensure(fp"{zoneinfo}/{table}".exists()?, "tzdata-tables", f"missing {table}")
  }

  let zone1970 = fp"{zoneinfo}/zone1970.tab".read_text()?
  proof.ensure("\tEurope/Berlin\t" in zone1970, "tzdata-tables", "zone1970.tab lacks Europe/Berlin")

  let tzif = fs.walk(zoneinfo) |> where .kind == "file" and ! .name.ends_with(".tab") and .name != "leapseconds" and .name != "leap-seconds.list"
  proof.ensure(tzif.len() == 598, "tzdata-zones", f"expected 598 TZif files, found {tzif.len()}")

  for entry in tzif {
    let magic = entry.path.read_bytes()?.slice(0, 4)
    proof.ensure(magic == b"TZif", "tzdata-zones", f"{entry.path} is not a TZif file")
  }

  if pm_util.build_arch()? != pm_util.target_arch()? {
    print f"tzdata ok: 598 TZif zones and tables for {pm_util.target_arch()?}"
    return
  }

  let cc = process.which("cc")?
  let tmp = fp"{root}/var/tmp/proof-tzdata"
  tmp.remove(missing_ok: true)
  tmp.mkdir()
  defer tmp.remove(missing_ok: true)
  fp"{tmp}/proof-tzdata.c".write(program)
  let binary = fp"{tmp}/proof-tzdata"
  run $cc "--sysroot=/" "-O2" fp"{tmp}/proof-tzdata.c" "-o" $binary

  for case in expected {
    let tz = fp"{zoneinfo}/{case.zone}".display()
    let out = run.text TZ=$tz $binary
    proof.ensure(out == case.output, "tzdata-localtime", f"{case.zone}: unexpected local time:\n{out}")
  }

  print "tzdata ok: 598 TZif zones, tables, Berlin/New York/Tokyo offsets and DST names"
}

main(@args)
