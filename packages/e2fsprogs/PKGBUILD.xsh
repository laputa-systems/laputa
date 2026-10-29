##! Build e2fsck from e2fsprogs with the package task graph and no shell.
use pm.make

## Package name.
export const name = "e2fsprogs"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Upstream e2fsprogs release.
export const ver = "1.47.2"

## Package release.
export const rel = "1"

## Runtime linkage is musl. libdl and libpthread come from that libc.
export const deps = ["musl"]

## clang and the kernel ioctl headers used by the ext2 libraries.
export const mkdeps_host = ["llvm-toolchain", "linux-headers"]

## The generated types headers are LP64 little-endian, so this recipe is x86_64 only.
export const architectures = ["x86_64"]

## Upstream tarball. Generated tables and config.h are vendored under files/.
export const upstream_sources = [
  {
    source: p"https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/vVERSION/e2fsprogs-VERSION.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "08242e64ca0e8194d9c1caad49762b19209a06318199b63ce74ae4ef2d74e63c",
      },
    ],
  },
]

## The repair tool. fsck.ext4 stays the laputa-fs superblock checker.
export const filetree = [{path: p"usr/bin/e2fsck", kind: "binary"}]

const com_err_stems = "error_message et_name init_et com_err com_right"

const uuid_stems = "clear compare copy gen_uuid isnull pack parse unpack unparse uuid_time"

const e2p_stems = "feature fgetflags fsetflags fgetversion fsetversion getflags getversion hashstr iod ls ljs mntopts parse_num pe pf ps setflags setversion uuid ostype percent crypto_mode fgetproject fsetproject encoding errcode"

const blkid_stems = "cache dev devname devno getsize llseek probe read resolve save tag version"

const support_stems = "cstring mkquota plausible profile parse_qtype print_fs_flags profile_helpers prof_err quotaio quotaio_v2 quotaio_tree dict devname"

const ext2fs_stems = "ext2_err bb_compat inode_io write_bb_file test_io alloc alloc_sb alloc_stats alloc_tables atexit badblocks bb_inode bitmaps bitops blkmap64_ba blkmap64_rb blknum block bmap check_desc closefs crc16 crc32c csum dblist dblist_dir dirblock dirhash dir_iterate expanddir ext_attr extent fallocate fileio finddev flushb freefs gen_bitmap gen_bitmap64 get_num_dirs get_pathname getenv getsize getsectsize hashmap i_block icount ind_block initialize inline inline_data inode io_manager ismounted link llseek lookup mkdir mkjournal mmp namei native newdir nls_utf8 openfs orphan progress punch qcow2 read_bb read_bb_file res_gdt rw_bitmaps sha512 swapfs symlink undo_io unix_io sparse_io unlink valid_blk version rbtree"

const e2fsck_stems = "unix e2fsck super pass1 pass1b pass2 pass3 pass4 pass5 journal badblocks util dirinfo dx_dirinfo ehandler problem message quota recovery region revoke ea_refcount rehash logfile sigcatcher readahead extents encrypted_files"

pure c_sources(stems: Str) -> List[Path] {
  [fp"{stem}.c" for stem in stems.words()]
}

proc stage_generated(recipe: Path) {
  let files = fp"{recipe}/files"
  fp"{files}/config.h".copy(to: p"lib/config.h", overwrite: true)
  fp"{files}/dirpaths.h".copy(to: p"lib/dirpaths.h", overwrite: true)
  fp"{files}/ext2_types.h".copy(to: p"lib/ext2fs/ext2_types.h", overwrite: true)
  fp"{files}/blkid_types.h".copy(to: p"lib/blkid/blkid_types.h", overwrite: true)
  fp"{files}/uuid_types.h".copy(to: p"lib/uuid/uuid_types.h", overwrite: true)
  fp"{files}/ext2_err.h".copy(to: p"lib/ext2fs/ext2_err.h", overwrite: true)
  fp"{files}/ext2_err.c".copy(to: p"lib/ext2fs/ext2_err.c", overwrite: true)
  fp"{files}/prof_err.h".copy(to: p"lib/support/prof_err.h", overwrite: true)
  fp"{files}/prof_err.c".copy(to: p"lib/support/prof_err.c", overwrite: true)
  fp"{files}/crc32c_table.h".copy(to: p"lib/ext2fs/crc32c_table.h", overwrite: true)
  p"lib/blkid/blkid.h.in".copy(to: p"lib/blkid/blkid.h", overwrite: true)
  p"lib/uuid/uuid.h.in".copy(to: p"lib/uuid/uuid.h", overwrite: true)
}

proc static_library(
  cc: Path,
  triple: Str,
  cflags: List[Str],
  defs: List[Str],
  includes: List[Str],
  root: Path,
  stems: Str,
  out_dir: Path,
  out: Path,
) -> make.CTarget {
  make.c_static_library({
    cc,
    triple,
    cflags,
    defs,
    includes: includes.push(f"-I{root}"),
    root,
    sources: c_sources(stems),
    out_dir,
    out,
    deps: [],
  })
}

## Compile and install e2fsck. The recipe never runs configure, make, or a shell.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let os = system.uname()?
  let triple = f"{os.machine}-linux-musl"
  var kr = ""

  if let Ok(v) = e"LAPUTA_ROOT" {
    if v != "/" {
      kr = v
    }
  }

  let recipe_dir = e"XSH_PM_RECIPE_DIR"?
  stage_generated(fp"{recipe_dir}")
  let cflags = ["-O2", "-pthread"]
  let defs = ["-DHAVE_CONFIG_H", "-D_GNU_SOURCE"]
  let includes = ["-I.", "-Ilib", f"-I{kr}/usr/include"]
  let support = static_library(cc, triple, cflags, defs, includes, p"lib/support", support_stems, p"obj/support", p"obj/libsupport.a")
  let ext2fs = static_library(cc, triple, cflags, defs, includes, p"lib/ext2fs", ext2fs_stems, p"obj/ext2fs", p"obj/libext2fs.a")
  let com_err = static_library(cc, triple, cflags, defs, includes, p"lib/et", com_err_stems, p"obj/com_err", p"obj/libcom_err.a")
  let blkid = static_library(cc, triple, cflags, defs, includes, p"lib/blkid", blkid_stems, p"obj/blkid", p"obj/libblkid.a")
  let uuid = static_library(cc, triple, cflags, defs, includes, p"lib/uuid", uuid_stems, p"obj/uuid", p"obj/libuuid.a")
  let e2p = static_library(cc, triple, cflags, defs, includes, p"lib/e2p", e2p_stems, p"obj/e2p", p"obj/libe2p.a")
  let libs = [support.output, ext2fs.output, com_err.output, blkid.output, uuid.output, e2p.output]
  let lib_deps = [output.display() for output in libs]

  let e2fsck = make.c_program({
    cc,
    triple,
    cflags,
    defs,
    includes: includes.push("-Ie2fsck"),
    root: p"e2fsck",
    sources: c_sources(e2fsck_stems),
    out_dir: p"obj/e2fsck",
    out: p"obj/e2fsck-bin",
    libs,
    ldflags: [f"-L{kr}/usr/lib", "-pthread", "-ldl", "-lpthread"],
    deps: lib_deps,
  })

  make.run_tasks(
    [
      @support.tasks,
      @ext2fs.tasks,
      @com_err.tasks,
      @blkid.tasks,
      @uuid.tasks,
      @e2p.tasks,
      @e2fsck.tasks,
    ],
    make.jobs()?,
  )
  fs.install(e2fsck.output, fp"{dest}/usr/bin/e2fsck", 0o755, parents: true, overwrite: true)
}
