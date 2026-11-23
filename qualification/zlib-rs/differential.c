#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include "zlib.h"

#define FUNCS(X) \
  X(zlibVersion) X(zlibCompileFlags) X(zError) \
  X(deflateInit2_) X(deflate) X(deflateEnd) X(deflateReset) X(deflateParams) \
  X(deflateSetDictionary) X(deflateGetDictionary) X(deflateBound) X(deflatePending) \
  X(deflatePrime) X(deflateTune) X(deflateCopy) X(deflateSetHeader) \
  X(inflateInit2_) X(inflate) X(inflateEnd) X(inflateReset) X(inflateReset2) \
  X(inflateSetDictionary) X(inflateGetDictionary) X(inflateSync) X(inflateCopy) \
  X(inflatePrime) X(inflateGetHeader) X(inflateBackInit_) X(inflateBack) X(inflateBackEnd) \
  X(compress) X(compress2) X(compressBound) X(uncompress) X(uncompress2) \
  X(crc32) X(crc32_z) X(crc32_combine) X(adler32) X(adler32_z) X(adler32_combine) \
  X(gzopen) X(gzdopen) X(gzbuffer) X(gzsetparams) X(gzread) X(gzfread) X(gzwrite) \
  X(gzfwrite) X(gzputs) X(gzputc) X(gzgetc) X(gzungetc) X(gzgets) X(gzflush) \
  X(gzseek) X(gzrewind) X(gztell) X(gzoffset) X(gzeof) X(gzdirect) X(gzclose) \
  X(gzclose_r) X(gzclose_w) X(gzerror) X(gzclearerr) \
  X(deflateResetKeep) X(inflateResetKeep)

typedef struct Api {
  const char *name;
  void *handle;
#define X(f) __typeof__(f) *f;
  FUNCS(X)
#undef X
} Api;

#define Z(f) (A->f)

static int load_api(Api *A, const char *name, const char *path) {
  memset(A, 0, sizeof(*A));
  A->name = name;
  A->handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!A->handle) {
    fprintf(stderr, "dlopen %s: %s\n", path, dlerror());
    return -1;
  }
  int missing = 0;
#define X(f) \
  *(void **)(&A->f) = dlsym(A->handle, #f); \
  if (!A->f) { fprintf(stderr, "%s: missing %s\n", name, #f); missing++; }
  FUNCS(X)
#undef X
  return missing;
}

typedef unsigned char u8;

static int g_fail, g_checks, g_gfail, g_gchecks, g_groups, g_failed_groups;
static const char *g_name = "";
static const char *g_tmp = ".";

enum {
  KD_UNCOMPRESS_ZERO, KD_GZ_SHORT_HEADER, KD_GZ_TOLERANT, KD_GZ_DELIVER_ALL,
  KD_GETDICT_SMALL_WINDOW, KD_RESET_AUTO_WINDOW, KD_RESET_KEEP, KD_DEFLATE_PRIME, KD_INFLATE_BACK,
  KD_GZWRITE_LARGE, KD_GZWRITE_ACCOUNT, KD_INFLATE_NULL_DICT, KD_INFLATE_COPY_STATE, KD_COUNT
};
static int kd_count[KD_COUNT];
static const char *kd_text[KD_COUNT] = {
  "uncompress and uncompress2 into a zero-length output buffer: zlib 1.4 returns Z_BUF_ERROR, the candidate returns Z_DATA_ERROR (and uncompress2 reports one more input byte consumed). Unchanged since 1.3.2: candidate defect, error class only",
  "gz file of fewer than four bytes: zlib 1.4 returns them as a transparent read, the candidate reports Z_BUF_ERROR and returns none. Unchanged since 1.3.2: candidate defect",
  "gz file with a damaged header or damaged first block: zlib 1.4 reads it transparently or ends silently and reports no error, the candidate reports an error. Candidate defect; 1.4 narrowed it, so fewer damaged files now differ",
  "gz file with a bad trailer or damaged data: zlib 1.4 returns every byte it inflated before reporting the error, the candidate returns fewer or none; both report the same error. Intended 1.4 change (deliver all gzip data before reporting error) that the candidate lags",
  "inflateGetDictionary with windowBits below 15: zlib 1.4 returns at most the 2^windowBits window, the candidate returns all history up to 32768 bytes with correct contents. Unchanged since 1.3.2: candidate defect, no memory effect",
  "inflateReset on a windowBits=0 stream: zlib 1.4 restores the automatic window so a second stream with a larger window inflates, the candidate keeps the first stream's window and returns Z_DATA_ERROR (invalid window size). Intended 1.4 change that the candidate lags",
  "deflateResetKeep in the middle of a stream, then a new raw stream: zlib 1.4 output decodes standalone, the candidate output fails Z_DATA_ERROR. Intended 1.4 change (read outside window after deflateResetKeep; 1.3.2 also fails here) that the candidate lags",
  "repeated deflatePrime with memLevel 1: zlib 1.4 returns Z_BUF_ERROR once the pending buffer is full, the candidate panics and aborts the process (SIGABRT). Intended 1.4 change (write past pending buffer; 1.3.2 overflows the heap); the candidate aborts instead of returning an error: candidate defect",
  "inflateBack on corrupt streams: zlib 1.4 returns Z_DATA_ERROR for distances before the start of output and never reads the caller's window, the candidate copies stale window bytes and accepts the stream, so its output depends on the window contents. Intended 1.4 change (uninitialized memory copy by inflateBack) that the candidate lags: candidate defect",
  "gzwrite of a large buffer to a full nonblocking descriptor: zlib 1.4 returns the bytes consumed and recovers, the candidate dies with SIGSEGV. This is the CVE-2026-85091 path; the candidate lags the 1.4 fix and is not safe here: candidate defect",
  "gzwrite to a nonblocking descriptor that stalls: zlib 1.4 returns the bytes consumed and the file holds exactly the accepted bytes, the candidate stops accepting after the first stall and its file holds more bytes than it reported accepted. The candidate has no nonblocking write support: candidate defect",
  "inflateSetDictionary with a NULL dictionary and nonzero length: zlib 1.4 returns Z_STREAM_ERROR, the candidate returns Z_OK without reading it. 1.4 hardening (1.3.2 faults here) that the candidate lags",
  "inflateCopy with an invalid source: zlib 1.4 sets dest->state to NULL, the candidate leaves it untouched. 1.4 hardening that the candidate lags",
};

#define CK(c, ...) do { g_gchecks++; if (!(c)) { g_gfail++; if (g_gfail <= 10) { printf("  FAIL %s: ", g_name); printf(__VA_ARGS__); printf("\n"); } } } while (0)

static void group_begin(const char *name) {
  g_name = name;
  g_gfail = 0;
  g_gchecks = 0;
}

static void group_end(void) {
  g_groups++;
  g_checks += g_gchecks;
  g_fail += g_gfail;
  if (g_gfail) g_failed_groups++;
  printf("%s %s: %d checks, %d failures\n", g_gfail ? "FAIL" : "PASS", g_name, g_gchecks, g_gfail);
  fflush(stdout);
}

static uint64_t rng = 0x9e3779b97f4a7c15ull;
static uint64_t rnd(void) {
  rng ^= rng << 13;
  rng ^= rng >> 7;
  rng ^= rng << 17;
  return rng;
}

typedef struct { u8 *p; size_t n; const char *name; } Buf;

static void *xmalloc(size_t n) {
  void *p = malloc(n ? n : 1);
  if (!p) { fprintf(stderr, "out of memory\n"); exit(2); }
  return p;
}

static void buf_append(Buf *b, const u8 *p, size_t n, size_t *cap) {
  if (b->n + n > *cap) {
    *cap = (b->n + n) * 2 + 64;
    b->p = realloc(b->p, *cap);
    if (!b->p) exit(2);
  }
  memcpy(b->p + b->n, p, n);
  b->n += n;
}

#define NCORPUS 9
static Buf corpus[NCORPUS];

static void build_corpus(void) {
  static const char *words[] = {"laputa", "zlib", "stream", "deflate", "inflate", "window", "huffman", "literal",
    "distance", "length", "block", "dynamic", "static", "checksum", "adler", "crc", "the", "of", "and", "to", "gzip"};
  size_t n;
  Buf *c = corpus;

  c[0].name = "empty"; c[0].n = 0; c[0].p = xmalloc(1);
  c[1].name = "byte"; c[1].n = 1; c[1].p = xmalloc(1); c[1].p[0] = 'a';

  n = 200000; c[2].name = "text"; c[2].n = n; c[2].p = xmalloc(n);
  for (size_t i = 0; i < n;) {
    const char *w = words[rnd() % (sizeof(words) / sizeof(*words))];
    for (; *w && i < n; w++) c[2].p[i++] = (u8)*w;
    if (i < n) c[2].p[i++] = (rnd() % 11 == 0) ? '\n' : ' ';
  }

  n = 100000; c[3].name = "zeros"; c[3].n = n; c[3].p = xmalloc(n); memset(c[3].p, 0, n);

  n = 100000; c[4].name = "random"; c[4].n = n; c[4].p = xmalloc(n);
  for (size_t i = 0; i < n; i++) c[4].p[i] = (u8)rnd();

  n = 300000; c[5].name = "mixed"; c[5].n = n; c[5].p = xmalloc(n);
  for (size_t i = 0; i < n;) {
    size_t len = 1 + rnd() % 3000;
    if (len > n - i) len = n - i;
    switch (rnd() % 4) {
      case 0: for (size_t k = 0; k < len; k++) c[5].p[i + k] = (u8)rnd(); break;
      case 1: memset(c[5].p + i, (int)(rnd() & 0xff), len); break;
      case 2: if (i > 10) { size_t from = rnd() % i; for (size_t k = 0; k < len; k++) c[5].p[i + k] = c[5].p[(from + k) % i]; break; }
      __attribute__((fallthrough));
      default: for (size_t k = 0; k < len; k++) c[5].p[i + k] = (u8)('a' + rnd() % 6); break;
    }
    i += len;
  }

  n = 256 * 256 * 4; c[6].name = "rgba"; c[6].n = n; c[6].p = xmalloc(n);
  for (size_t y = 0; y < 256; y++)
    for (size_t x = 0; x < 256; x++) {
      u8 *px = c[6].p + (y * 256 + x) * 4;
      px[0] = (u8)x; px[1] = (u8)y; px[2] = (u8)((x + y) / 2 + (rnd() % 3)); px[3] = 255;
    }

  c[7].name = "short"; c[7].n = 300; c[7].p = xmalloc(300);
  for (size_t i = 0; i < 300; i++) c[7].p[i] = (u8)("laputa zlib-rs qualification "[i % 28]);

  n = 150000; c[8].name = "far-repeat"; c[8].n = n; c[8].p = xmalloc(n);
  for (size_t i = 0; i < 40000; i++) c[8].p[i] = (u8)rnd();
  for (size_t i = 40000; i < n; i++) c[8].p[i] = c[8].p[i - 40000 + (i % 7 == 0 ? 1 : 0)];
}

static int enc(Api *A, const u8 *in, size_t n, int level, int wbits, int mem, int strat, Buf *out) {
  z_stream s;
  memset(&s, 0, sizeof(s));
  int r = Z(deflateInit2_)(&s, level, Z_DEFLATED, wbits, mem, strat, ZLIB_VERSION, (int)sizeof(z_stream));
  if (r != Z_OK) return r;
  size_t cap = Z(deflateBound)(&s, (uLong)n) + 64;
  out->p = xmalloc(cap);
  s.next_in = (Bytef *)in;
  s.avail_in = (uInt)n;
  s.next_out = out->p;
  s.avail_out = (uInt)cap;
  r = Z(deflate)(&s, Z_FINISH);
  out->n = cap - s.avail_out;
  Z(deflateEnd)(&s);
  return r;
}

static int dec(Api *A, const u8 *in, size_t n, int wbits, u8 *out, size_t cap, size_t *outn, uLong *total_in) {
  z_stream s;
  memset(&s, 0, sizeof(s));
  int r = Z(inflateInit2_)(&s, wbits, ZLIB_VERSION, (int)sizeof(z_stream));
  if (r != Z_OK) return r;
  s.next_in = (Bytef *)in;
  s.avail_in = (uInt)n;
  s.next_out = out;
  s.avail_out = (uInt)cap;
  do { r = Z(inflate)(&s, Z_NO_FLUSH); } while (r == Z_OK);
  *outn = cap - s.avail_out;
  if (total_in) *total_in = s.total_in;
  Z(inflateEnd)(&s);
  return r;
}

static const char *rname(int r) {
  switch (r) {
    case Z_OK: return "Z_OK"; case Z_STREAM_END: return "Z_STREAM_END"; case Z_NEED_DICT: return "Z_NEED_DICT";
    case Z_ERRNO: return "Z_ERRNO"; case Z_STREAM_ERROR: return "Z_STREAM_ERROR"; case Z_DATA_ERROR: return "Z_DATA_ERROR";
    case Z_MEM_ERROR: return "Z_MEM_ERROR"; case Z_BUF_ERROR: return "Z_BUF_ERROR"; case Z_VERSION_ERROR: return "Z_VERSION_ERROR";
  }
  return "?";
}

static Api *P[2];

static void roundtrip_matrix(void) {
  group_begin("roundtrip every level and strategy, cross-decoded");
  size_t total[2] = {0, 0};
  for (int ci = 0; ci < NCORPUS; ci++) {
    Buf *c = &corpus[ci];
    u8 *back = xmalloc(c->n + 1);
    for (int level = -1; level <= 9; level++)
      for (int strat = 0; strat <= 4; strat++)
        for (int e = 0; e < 2; e++) {
          Buf z = {0};
          int r = enc(P[e], c->p, c->n, level, 15, 8, strat, &z);
          CK(r == Z_STREAM_END, "%s %s level=%d strat=%d: deflate returned %s", P[e]->name, c->name, level, strat, rname(r));
          if (r != Z_STREAM_END) { free(z.p); continue; }
          if (level == 6 && strat == 0) total[e] += z.n;
          for (int d = 0; d < 2; d++) {
            size_t got = 0;
            uLong tin = 0;
            r = dec(P[d], z.p, z.n, 15, back, c->n + 1, &got, &tin);
            CK(r == Z_STREAM_END && got == c->n && memcmp(back, c->p, c->n) == 0 && tin == z.n,
               "%s->%s %s level=%d strat=%d: inflate %s out=%zu/%zu in=%lu/%zu", P[e]->name, P[d]->name, c->name, level, strat, rname(r), got, c->n, tin, z.n);
          }
          free(z.p);
        }
    free(back);
  }
  printf("  info compressed bytes at level 6 over the corpus: %s=%zu %s=%zu\n", P[0]->name, total[0], P[1]->name, total[1]);
  group_end();
}

static void wrapper_matrix(void) {
  group_begin("window bits, memLevel and wrapper formats");
  static const int wbits[] = {9, 10, 12, 15, -9, -12, -15, 25, 28, 31};
  static const int sel[] = {2, 5, 6, 7};
  for (int si = 0; si < 4; si++) {
    Buf *c = &corpus[sel[si]];
    u8 *back = xmalloc(c->n + 1);
    for (int wi = 0; wi < 10; wi++)
      for (int level = 1; level <= 9; level += 4)
        for (int mem = 1; mem <= 9; mem += 4)
          for (int e = 0; e < 2; e++) {
            Buf z = {0};
            int wb = wbits[wi];
            int r = enc(P[e], c->p, c->n, level, wb, mem, Z_DEFAULT_STRATEGY, &z);
            CK(r == Z_STREAM_END, "%s %s wb=%d level=%d mem=%d: deflate %s", P[e]->name, c->name, wb, level, mem, rname(r));
            if (r != Z_STREAM_END) { free(z.p); continue; }
            int dwb = wb < 0 ? wb : (wb > 15 ? wb : wb);
            for (int d = 0; d < 2; d++) {
              size_t got = 0;
              r = dec(P[d], z.p, z.n, dwb < 0 ? -15 : (dwb > 15 ? 15 + 32 : 15 + 32), back, c->n + 1, &got, NULL);
              CK(r == Z_STREAM_END && got == c->n && memcmp(back, c->p, c->n) == 0,
                 "%s->%s %s wb=%d level=%d mem=%d: inflate %s", P[e]->name, P[d]->name, c->name, wb, level, mem, rname(r));
              if (wb > 0 && wb <= 15 && c->n > 0) {
                r = dec(P[d], z.p, z.n, wb, back, c->n + 1, &got, NULL);
                CK(r == Z_STREAM_END && got == c->n && memcmp(back, c->p, c->n) == 0,
                   "%s->%s %s zlib wb=%d exact window: inflate %s", P[e]->name, P[d]->name, c->name, wb, rname(r));
              }
            }
            free(z.p);
          }
    free(back);
  }
  group_end();
}

static void oneshot(void) {
  group_begin("compress, compress2, uncompress, uncompress2, compressBound");
  for (int ci = 0; ci < NCORPUS; ci++) {
    Buf *c = &corpus[ci];
    u8 *back = xmalloc(c->n + 1);
    for (int level = -1; level <= 9; level++)
      for (int e = 0; e < 2; e++) {
        Api *A = P[e];
        uLong bound = Z(compressBound)((uLong)c->n);
        u8 *z = xmalloc(bound + 1);
        uLongf zn = bound;
        int r = level == Z_DEFAULT_COMPRESSION && ci % 2 == 0 ? Z(compress)(z, &zn, c->p, (uLong)c->n) : Z(compress2)(z, &zn, c->p, (uLong)c->n, level);
        CK(r == Z_OK, "%s %s level=%d: compress %s", P[e]->name, c->name, level, rname(r));
        CK(zn <= bound, "%s %s level=%d: %lu bytes exceed compressBound %lu", P[e]->name, c->name, level, (unsigned long)zn, (unsigned long)bound);
        if (r == Z_OK)
          for (int d = 0; d < 2; d++) {
            uLongf bn = c->n + 1;
            r = Z(uncompress)(back, &bn, z, zn);
            CK(r == Z_OK && bn == c->n && memcmp(back, c->p, c->n) == 0, "%s->%s %s level=%d: uncompress %s", P[e]->name, P[d]->name, c->name, level, rname(r));
            uLongf bn2 = c->n + 1;
            uLong src = zn;
            r = Z(uncompress2)(back, &bn2, z, &src);
            CK(r == Z_OK && bn2 == c->n && src == zn && memcmp(back, c->p, c->n) == 0, "%s->%s %s level=%d: uncompress2 %s consumed %lu/%lu", P[e]->name, P[d]->name, c->name, level, rname(r), (unsigned long)src, (unsigned long)zn);
          }
        free(z);
      }
    free(back);
  }
  int bound_diffs = 0;
  for (uLong n = 0; n < 70000; n += (n < 600 ? 1 : 9973)) {
    uLong a = P[0]->compressBound(n), b = P[1]->compressBound(n);
    CK(b >= n, "compressBound(%lu): candidate %lu is below the input size", n, b);
    if (a != b) {
      bound_diffs++;
      if (bound_diffs <= 3) printf("  info compressBound(%lu) differs: oracle %lu candidate %lu\n", n, a, b);
    }
  }
  printf("  info compressBound differs from the oracle for %d sampled lengths\n", bound_diffs);
  for (int e = 0; e < 2; e++)
    for (int level = 0; level <= 9; level += 3)
      for (uLong n = 0; n < 700; n++) {
        u8 in[700], out[1400];
        for (uLong i = 0; i < n; i++) in[i] = (u8)rnd();
        uLongf zn = P[e]->compressBound(n);
        int r = P[e]->compress2(out, &zn, in, n, level);
        CK(r == Z_OK, "%s: compress2 of %lu random bytes at level %d into compressBound gave %s", P[e]->name, n, level, rname(r));
      }
  group_end();
}

typedef struct { size_t in_chunk, out_chunk; int flush_every, flush_mode; } Pace;

static int enc_stream(Api *A, const u8 *in, size_t n, int level, int wbits, Pace pace, Buf *out) {
  z_stream s;
  memset(&s, 0, sizeof(s));
  int r = Z(deflateInit2_)(&s, level, Z_DEFLATED, wbits, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, (int)sizeof(z_stream));
  if (r != Z_OK) return r;
  u8 *tmp = xmalloc(pace.out_chunk);
  size_t cap = 0, off = 0;
  int count = 0;
  out->p = NULL; out->n = 0;
  do {
    size_t len = n - off < pace.in_chunk ? n - off : pace.in_chunk;
    int last = off + len >= n;
    int flush = last ? Z_FINISH : (pace.flush_every && ++count % pace.flush_every == 0 ? pace.flush_mode : Z_NO_FLUSH);
    s.next_in = (Bytef *)in + off;
    s.avail_in = (uInt)len;
    off += len;
    do {
      s.next_out = tmp;
      s.avail_out = (uInt)pace.out_chunk;
      r = Z(deflate)(&s, flush);
      if (r == Z_STREAM_ERROR) { Z(deflateEnd)(&s); free(tmp); return r; }
      buf_append(out, tmp, pace.out_chunk - s.avail_out, &cap);
    } while (s.avail_out == 0);
    if (last) break;
  } while (1);
  Z(deflateEnd)(&s);
  free(tmp);
  return r;
}

static int dec_stream(Api *A, const u8 *in, size_t n, int wbits, size_t in_chunk, size_t out_chunk, Buf *out) {
  z_stream s;
  memset(&s, 0, sizeof(s));
  int r = Z(inflateInit2_)(&s, wbits, ZLIB_VERSION, (int)sizeof(z_stream));
  if (r != Z_OK) return r;
  u8 *tmp = xmalloc(out_chunk);
  size_t cap = 0, off = 0;
  out->p = NULL; out->n = 0;
  r = Z_OK;
  while (r != Z_STREAM_END && off < n) {
    size_t len = n - off < in_chunk ? n - off : in_chunk;
    s.next_in = (Bytef *)in + off;
    s.avail_in = (uInt)len;
    off += len;
    do {
      s.next_out = tmp;
      s.avail_out = (uInt)out_chunk;
      r = Z(inflate)(&s, Z_NO_FLUSH);
      if (r != Z_OK && r != Z_BUF_ERROR && r != Z_STREAM_END) { goto done; }
      buf_append(out, tmp, out_chunk - s.avail_out, &cap);
      if (r == Z_STREAM_END) break;
    } while (s.avail_out == 0);
  }
done:
  Z(inflateEnd)(&s);
  free(tmp);
  return r;
}

static void streaming(void) {
  group_begin("streaming with small input and output buffers");
  static const size_t sizes[] = {1, 2, 7, 64, 4096};
  static const int sel[] = {2, 4, 7, 5};
  static const int wbits[] = {15, -15, 31};
  for (int si = 0; si < 4; si++) {
    Buf *c = &corpus[sel[si]];
    size_t n = c->n > 20000 ? 20000 : c->n;
    for (int wi = 0; wi < 3; wi++)
      for (int ii = 0; ii < 5; ii++)
        for (int oi = 0; oi < 5; oi++)
          for (int e = 0; e < 2; e++) {
            if (sizes[ii] * sizes[oi] == 1 && n > 4000) continue;
            Pace pace = {sizes[ii], sizes[oi], 0, Z_NO_FLUSH};
            Buf z = {0};
            int level = 1 + (ii + oi) % 9;
            int r = enc_stream(P[e], c->p, n, level, wbits[wi], pace, &z);
            CK(r == Z_STREAM_END, "%s %s in=%zu out=%zu wb=%d: deflate %s", P[e]->name, c->name, sizes[ii], sizes[oi], wbits[wi], rname(r));
            if (r != Z_STREAM_END) { free(z.p); continue; }
            for (int d = 0; d < 2; d++) {
              Buf o = {0};
              r = dec_stream(P[d], z.p, z.n, wbits[wi] < 0 ? -15 : (wbits[wi] > 15 ? 15 + 32 : 15), sizes[(ii + 1) % 5], sizes[(oi + 2) % 5], &o);
              CK(r == Z_STREAM_END && o.n == n && memcmp(o.p, c->p, n) == 0, "%s->%s %s in=%zu out=%zu wb=%d: inflate %s got %zu/%zu", P[e]->name, P[d]->name, c->name, sizes[ii], sizes[oi], wbits[wi], rname(r), o.n, n);
              free(o.p);
            }
            free(z.p);
          }
  }
  group_end();
}

static void flush_modes(void) {
  group_begin("flush modes keep every prefix decodable");
  static const int modes[] = {Z_SYNC_FLUSH, Z_FULL_FLUSH, Z_PARTIAL_FLUSH, Z_BLOCK};
  Buf *c = &corpus[2];
  size_t n = 30000;
  for (int m = 0; m < 4; m++)
    for (int e = 0; e < 2; e++) {
      Pace pace = {1000, 4096, 3, modes[m]};
      Buf z = {0};
      int r = enc_stream(P[e], c->p, n, 6, 15, pace, &z);
      CK(r == Z_STREAM_END, "%s mode=%d: deflate %s", P[e]->name, modes[m], rname(r));
      if (r != Z_STREAM_END) { free(z.p); continue; }
      for (int d = 0; d < 2; d++) {
        Buf o = {0};
        r = dec_stream(P[d], z.p, z.n, 15, 13, 4096, &o);
        CK(r == Z_STREAM_END && o.n == n && memcmp(o.p, c->p, n) == 0, "%s->%s mode=%d: inflate %s", P[e]->name, P[d]->name, modes[m], rname(r));
        free(o.p);
      }
      free(z.p);
    }
  for (int m = 0; m < 2; m++)
    for (int e = 0; e < 2; e++) {
      z_stream s;
      Api *A = P[e];
      memset(&s, 0, sizeof(s));
      Z(deflateInit2_)(&s, 6, Z_DEFLATED, 15, 8, 0, ZLIB_VERSION, (int)sizeof(s));
      u8 *zb = xmalloc(100000);
      s.next_in = c->p; s.avail_in = 5000; s.next_out = zb; s.avail_out = 100000;
      int r = Z(deflate)(&s, m == 0 ? Z_SYNC_FLUSH : Z_FULL_FLUSH);
      CK(r == Z_OK && s.avail_in == 0, "%s flush %d: deflate %s", A->name, m, rname(r));
      size_t zn = 100000 - s.avail_out;
      for (int d = 0; d < 2; d++) {
        u8 *back = xmalloc(6000);
        size_t got = 0;
        r = dec(P[d], zb, zn, 15, back, 6000, &got, NULL);
        CK(got == 5000 && memcmp(back, c->p, 5000) == 0 && (r == Z_BUF_ERROR || r == Z_OK), "%s->%s flush %d: prefix inflate %s out=%zu", A->name, P[d]->name, m, rname(r), got);
        free(back);
      }
      Z(deflateEnd)(&s);
      free(zb);
    }
  group_end();
}

static void params_dictionary(void) {
  group_begin("deflateParams, dictionaries, priming, copy and reset");
  Buf *c = &corpus[5];
  size_t n = 120000;
  u8 *back = xmalloc(n + 1);
  for (int e = 0; e < 2; e++) {
    Api *A = P[e];
    z_stream s;
    memset(&s, 0, sizeof(s));
    Z(deflateInit2_)(&s, 1, Z_DEFLATED, 15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, (int)sizeof(s));
    size_t cap = Z(deflateBound)(&s, (uLong)n) + 1000;
    u8 *z = xmalloc(cap);
    s.next_out = z; s.avail_out = (uInt)cap;
    s.next_in = c->p; s.avail_in = 40000;
    int r = Z(deflate)(&s, Z_NO_FLUSH);
    CK(r == Z_OK, "%s: deflate before params %s", A->name, rname(r));
    r = Z(deflateParams)(&s, 9, Z_FILTERED);
    CK(r == Z_OK || r == Z_BUF_ERROR, "%s: deflateParams %s", A->name, rname(r));
    s.next_in = c->p + 40000; s.avail_in = 40000;
    r = Z(deflate)(&s, Z_NO_FLUSH);
    r = Z(deflateParams)(&s, 0, Z_DEFAULT_STRATEGY);
    s.next_in = c->p + 80000; s.avail_in = (uInt)(n - 80000);
    r = Z(deflate)(&s, Z_FINISH);
    CK(r == Z_STREAM_END, "%s: deflate finish after params %s", A->name, rname(r));
    size_t zn = cap - s.avail_out;
    Z(deflateEnd)(&s);
    for (int d = 0; d < 2; d++) {
      size_t got = 0;
      r = dec(P[d], z, zn, 15, back, n + 1, &got, NULL);
      CK(r == Z_STREAM_END && got == n && memcmp(back, c->p, n) == 0, "%s->%s: params stream inflate %s", A->name, P[d]->name, rname(r));
    }
    free(z);
  }

  u8 dict[4096];
  for (size_t i = 0; i < sizeof(dict); i++) dict[i] = corpus[2].p[1000 + i];
  for (int e = 0; e < 2; e++)
    for (int raw = 0; raw < 2; raw++) {
      Api *A = P[e];
      z_stream s;
      memset(&s, 0, sizeof(s));
      int wb = raw ? -15 : 15;
      Z(deflateInit2_)(&s, 6, Z_DEFLATED, wb, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, (int)sizeof(s));
      int r = Z(deflateSetDictionary)(&s, dict, sizeof(dict));
      CK(r == Z_OK, "%s raw=%d: deflateSetDictionary %s", A->name, raw, rname(r));
      size_t cap = 60000;
      u8 *z = xmalloc(cap);
      s.next_in = corpus[2].p + 1500; s.avail_in = 30000; s.next_out = z; s.avail_out = (uInt)cap;
      r = Z(deflate)(&s, Z_FINISH);
      CK(r == Z_STREAM_END, "%s raw=%d: deflate with dictionary %s", A->name, raw, rname(r));
      size_t zn = cap - s.avail_out;
      u8 gd[32768];
      uInt gdl = 0;
      r = Z(deflateGetDictionary)(&s, gd, &gdl);
      CK(r == Z_OK && gdl > 0, "%s raw=%d: deflateGetDictionary %s len=%u", A->name, raw, rname(r), gdl);
      Z(deflateEnd)(&s);
      for (int d = 0; d < 2; d++) {
        Api *B = P[d];
        for (int wrong = 0; wrong < 2; wrong++) {
          z_stream t;
          memset(&t, 0, sizeof(t));
          r = B->inflateInit2_(&t, wb, ZLIB_VERSION, (int)sizeof(t));
          u8 *out = xmalloc(40000);
          t.next_in = z; t.avail_in = (uInt)zn; t.next_out = out; t.avail_out = 40000;
          u8 other[4096];
          memcpy(other, dict, sizeof(dict));
          other[10] ^= 0x55;
          const u8 *use = wrong ? other : dict;
          if (raw) {
            r = B->inflateSetDictionary(&t, use, sizeof(dict));
            CK(r == Z_OK, "%s->%s raw: inflateSetDictionary %s", A->name, B->name, rname(r));
            do { r = B->inflate(&t, Z_NO_FLUSH); } while (r == Z_OK);
            if (wrong) CK(r == Z_STREAM_END || r == Z_DATA_ERROR, "%s->%s raw wrong dict: %s", A->name, B->name, rname(r));
            else CK(r == Z_STREAM_END && 40000 - t.avail_out == 30000 && memcmp(out, corpus[2].p + 1500, 30000) == 0, "%s->%s raw dict inflate %s", A->name, B->name, rname(r));
          } else {
            r = B->inflate(&t, Z_NO_FLUSH);
            CK(r == Z_NEED_DICT && t.adler == B->adler32(B->adler32(0, NULL, 0), dict, sizeof(dict)), "%s->%s: expected Z_NEED_DICT with dictionary adler, got %s adler=%lx", A->name, B->name, rname(r), t.adler);
            r = B->inflateSetDictionary(&t, use, sizeof(dict));
            if (wrong) CK(r == Z_DATA_ERROR, "%s->%s wrong dictionary: %s", A->name, B->name, rname(r));
            else {
              CK(r == Z_OK, "%s->%s: inflateSetDictionary %s", A->name, B->name, rname(r));
              do { r = B->inflate(&t, Z_NO_FLUSH); } while (r == Z_OK);
              CK(r == Z_STREAM_END && 40000 - t.avail_out == 30000 && memcmp(out, corpus[2].p + 1500, 30000) == 0, "%s->%s dict inflate %s", A->name, B->name, rname(r));
              uInt dl = 0;
              u8 hist[32768];
              r = B->inflateGetDictionary(&t, hist, &dl);
              CK(r == Z_OK, "%s->%s: inflateGetDictionary %s len=%u", A->name, B->name, rname(r), dl);
            }
          }
          B->inflateEnd(&t);
          free(out);
        }
      }
      free(z);
    }

  for (int e = 0; e < 2; e++) {
    Api *A = P[e];
    z_stream s;
    memset(&s, 0, sizeof(s));
    Z(deflateInit2_)(&s, 6, Z_DEFLATED, -15, 8, 0, ZLIB_VERSION, (int)sizeof(s));
    int r = Z(deflatePrime)(&s, 5, 0x15);
    CK(r == Z_OK, "%s: deflatePrime %s", A->name, rname(r));
    u8 z[512];
    const char *msg = "prime and copy and reset";
    size_t mn = strlen(msg);
    s.next_in = (Bytef *)msg; s.avail_in = (uInt)mn; s.next_out = z; s.avail_out = sizeof(z);
    z_stream cp;
    memset(&cp, 0, sizeof(cp));
    r = Z(deflateCopy)(&cp, &s);
    CK(r == Z_OK, "%s: deflateCopy %s", A->name, rname(r));
    r = Z(deflate)(&s, Z_FINISH);
    CK(r == Z_STREAM_END, "%s: deflate %s", A->name, rname(r));
    size_t zn = sizeof(z) - s.avail_out;
    CK((z[0] & 0x1f) == 0x15, "%s: primed bits not at the start of the stream: %02x", A->name, z[0]);
    u8 z2[512];
    cp.next_in = (Bytef *)msg; cp.avail_in = (uInt)mn; cp.next_out = z2; cp.avail_out = sizeof(z2);
    r = Z(deflate)(&cp, Z_FINISH);
    CK(r == Z_STREAM_END && sizeof(z2) - cp.avail_out == zn && memcmp(z, z2, zn) == 0, "%s: deflateCopy output differs from original (%s)", A->name, rname(r));
    uInt pend = 0;
    int bits = 0;
    r = Z(deflatePending)(&cp, &pend, &bits);
    CK(r == Z_OK, "%s: deflatePending %s", A->name, rname(r));
    Z(deflateEnd)(&cp);
    Z(deflateEnd)(&s);
    u8 shifted[512];
    for (size_t i = 0; i < zn; i++) shifted[i] = (u8)((z[i] >> 5) | (i + 1 < zn ? z[i + 1] << 3 : 0));
    for (int d = 0; d < 2; d++) {
      Api *B = P[d];
      u8 out[128];
      size_t got = 0;
      r = dec(B, shifted, zn, -15, out, sizeof(out), &got, NULL);
      CK((r == Z_STREAM_END || r == Z_DATA_ERROR || r == Z_BUF_ERROR) && (r != Z_STREAM_END || (got == mn && memcmp(out, msg, mn) == 0)), "%s->%s: stream with primed bits shifted out: %s", A->name, B->name, rname(r));
      Buf plain = {0};
      enc(A, (const u8 *)msg, mn, 6, -15, 8, 0, &plain);
      z_stream t;
      memset(&t, 0, sizeof(t));
      B->inflateInit2_(&t, -15, ZLIB_VERSION, (int)sizeof(t));
      r = B->inflatePrime(&t, 8, plain.p[0]);
      CK(r == Z_OK, "%s: inflatePrime %s", B->name, rname(r));
      t.next_in = plain.p + 1; t.avail_in = (uInt)(plain.n - 1); t.next_out = out; t.avail_out = sizeof(out);
      do { r = B->inflate(&t, Z_NO_FLUSH); } while (r == Z_OK);
      CK(r == Z_STREAM_END && sizeof(out) - t.avail_out == mn && memcmp(out, msg, mn) == 0, "%s->%s: stream started with inflatePrime: %s", A->name, B->name, rname(r));
      B->inflateEnd(&t);
      free(plain.p);
    }
  }

  for (int e = 0; e < 2; e++) {
    Api *A = P[e];
    Buf z = {0};
    int r = enc(A, corpus[7].p, corpus[7].n, 6, 15, 8, 0, &z);
    for (int d = 0; d < 2; d++) {
      Api *B = P[d];
      z_stream t;
      memset(&t, 0, sizeof(t));
      B->inflateInit2_(&t, 15, ZLIB_VERSION, (int)sizeof(t));
      u8 out[400], out2[400];
      t.next_in = z.p; t.avail_in = (uInt)(z.n / 2); t.next_out = out; t.avail_out = sizeof(out);
      r = B->inflate(&t, Z_NO_FLUSH);
      size_t produced = sizeof(out) - t.avail_out;
      z_stream cp;
      memset(&cp, 0, sizeof(cp));
      int cr = B->inflateCopy(&cp, &t);
      CK(cr == Z_OK, "%s: inflateCopy %s", B->name, rname(cr));
      t.next_in = z.p + z.n / 2; t.avail_in = (uInt)(z.n - z.n / 2);
      do { r = B->inflate(&t, Z_NO_FLUSH); } while (r == Z_OK);
      CK(r == Z_STREAM_END && sizeof(out) - t.avail_out == corpus[7].n && memcmp(out, corpus[7].p, corpus[7].n) == 0, "%s->%s: inflate after copy %s", A->name, B->name, rname(r));
      memcpy(out2, out, produced);
      cp.next_in = z.p + z.n / 2; cp.avail_in = (uInt)(z.n - z.n / 2); cp.next_out = out2 + produced; cp.avail_out = (uInt)(sizeof(out2) - produced);
      do { r = B->inflate(&cp, Z_NO_FLUSH); } while (r == Z_OK);
      CK(r == Z_STREAM_END && sizeof(out2) - cp.avail_out == corpus[7].n && memcmp(out2, corpus[7].p, corpus[7].n) == 0, "%s->%s: copied stream inflate %s", A->name, B->name, rname(r));
      B->inflateEnd(&cp);
      r = B->inflateReset2(&t, -15);
      CK(r == Z_OK, "%s: inflateReset2 %s", B->name, rname(r));
      Buf raw = {0};
      enc(A, corpus[7].p, corpus[7].n, 6, -15, 8, 0, &raw);
      t.next_in = raw.p; t.avail_in = (uInt)raw.n; t.next_out = out; t.avail_out = sizeof(out);
      do { r = B->inflate(&t, Z_NO_FLUSH); } while (r == Z_OK);
      CK(r == Z_STREAM_END && sizeof(out) - t.avail_out == corpus[7].n, "%s: raw inflate after inflateReset2 %s", B->name, rname(r));
      r = B->inflateReset(&t);
      CK(r == Z_OK, "%s: inflateReset %s", B->name, rname(r));
      B->inflateEnd(&t);
      free(raw.p);
    }
    free(z.p);
  }

  for (int e = 0; e < 2; e++) {
    Api *A = P[e];
    z_stream s;
    memset(&s, 0, sizeof(s));
    Z(deflateInit2_)(&s, 6, Z_DEFLATED, 15, 8, 0, ZLIB_VERSION, (int)sizeof(s));
    for (int round = 0; round < 3; round++) {
      Buf *c2 = &corpus[2 + round];
      size_t m = c2->n > 50000 ? 50000 : c2->n;
      size_t cap = Z(deflateBound)(&s, (uLong)m) + 100;
      u8 *z = xmalloc(cap);
      s.next_in = c2->p; s.avail_in = (uInt)m; s.next_out = z; s.avail_out = (uInt)cap;
      int r = Z(deflate)(&s, Z_FINISH);
      CK(r == Z_STREAM_END, "%s round %d: reused deflate %s", A->name, round, rname(r));
      size_t got = 0;
      for (int d = 0; d < 2; d++) {
        r = dec(P[d], z, cap - s.avail_out, 15, back, n + 1, &got, NULL);
        CK(r == Z_STREAM_END && got == m && memcmp(back, c2->p, m) == 0, "%s->%s round %d: inflate %s", A->name, P[d]->name, round, rname(r));
      }
      free(z);
      r = Z(deflateReset)(&s);
      CK(r == Z_OK, "%s: deflateReset %s", A->name, rname(r));
    }
    Z(deflateEnd)(&s);
  }

  for (int e = 0; e < 2; e++) {
    Api *A = P[e];
    z_stream s;
    memset(&s, 0, sizeof(s));
    int r = Z(deflateInit2_)(&s, 6, Z_DEFLATED, 15, 8, 0, ZLIB_VERSION, (int)sizeof(s));
    r = Z(deflateTune)(&s, 32, 128, 258, 4096);
    CK(r == Z_OK, "%s: deflateTune %s", A->name, rname(r));
    u8 *z = xmalloc(300000);
    s.next_in = corpus[2].p; s.avail_in = 100000; s.next_out = z; s.avail_out = 300000;
    r = Z(deflate)(&s, Z_FINISH);
    CK(r == Z_STREAM_END, "%s: tuned deflate %s", A->name, rname(r));
    size_t got = 0;
    for (int d = 0; d < 2; d++) {
      r = dec(P[d], z, 300000 - s.avail_out, 15, back, n + 1, &got, NULL);
      CK(r == Z_STREAM_END && got == 100000 && memcmp(back, corpus[2].p, 100000) == 0, "%s->%s: tuned inflate %s", A->name, P[d]->name, rname(r));
    }
    Z(deflateEnd)(&s);
    free(z);
  }
  free(back);
  group_end();
}

static void gzip_headers(void) {
  group_begin("gzip header fields through deflateSetHeader and inflateGetHeader");
  for (int e = 0; e < 2; e++) {
    Api *A = P[e];
    z_stream s;
    memset(&s, 0, sizeof(s));
    gz_header h;
    memset(&h, 0, sizeof(h));
    u8 extra[] = {'a', 'b', 4, 0, 1, 2, 3, 4};
    char name[] = "payload.txt", comment[] = "laputa header comment";
    h.text = 1; h.time = 1700000000; h.os = 3; h.extra = extra; h.extra_len = sizeof(extra);
    h.name = (Bytef *)name; h.comment = (Bytef *)comment;
    for (int hcrc = 0; hcrc < 2; hcrc++) {
      h.hcrc = hcrc;
      memset(&s, 0, sizeof(s));
      int r = Z(deflateInit2_)(&s, 6, Z_DEFLATED, 31, 8, 0, ZLIB_VERSION, (int)sizeof(s));
      r = Z(deflateSetHeader)(&s, &h);
      CK(r == Z_OK, "%s: deflateSetHeader %s", A->name, rname(r));
      u8 z[2000];
      s.next_in = corpus[7].p; s.avail_in = (uInt)corpus[7].n; s.next_out = z; s.avail_out = sizeof(z);
      r = Z(deflate)(&s, Z_FINISH);
      CK(r == Z_STREAM_END, "%s: deflate with header %s", A->name, rname(r));
      size_t zn = sizeof(z) - s.avail_out;
      Z(deflateEnd)(&s);
      for (int d = 0; d < 2; d++) {
        Api *B = P[d];
        z_stream t;
        memset(&t, 0, sizeof(t));
        B->inflateInit2_(&t, 31, ZLIB_VERSION, (int)sizeof(t));
        gz_header got;
        memset(&got, 0, sizeof(got));
        u8 gx[64], gn[64], gc[64];
        got.extra = gx; got.extra_max = sizeof(gx);
        got.name = gn; got.name_max = sizeof(gn);
        got.comment = gc; got.comm_max = sizeof(gc);
        r = B->inflateGetHeader(&t, &got);
        CK(r == Z_OK, "%s: inflateGetHeader %s", B->name, rname(r));
        u8 out[400];
        t.next_in = z; t.avail_in = (uInt)zn; t.next_out = out; t.avail_out = sizeof(out);
        do { r = B->inflate(&t, Z_NO_FLUSH); } while (r == Z_OK);
        CK(r == Z_STREAM_END && sizeof(out) - t.avail_out == corpus[7].n && memcmp(out, corpus[7].p, corpus[7].n) == 0, "%s->%s hcrc=%d: inflate %s", A->name, B->name, hcrc, rname(r));
        CK(got.done == 1 && got.text == 1 && got.time == 1700000000 && got.os == 3 && got.extra_len == sizeof(extra) && memcmp(gx, extra, sizeof(extra)) == 0 && strcmp((char *)gn, name) == 0 && strcmp((char *)gc, comment) == 0,
           "%s->%s hcrc=%d: header mismatch done=%d text=%d time=%lu os=%d extra_len=%u name=%s comment=%s", A->name, B->name, hcrc, got.done, got.text, got.time, got.os, got.extra_len, gn, gc);
        B->inflateEnd(&t);
      }
    }
  }
  group_end();
}

typedef struct { const u8 *p; size_t n, off, chunk; Buf out; size_t cap; } BackCtx;
static unsigned back_in(void *ctx, unsigned char **buf) {
  BackCtx *c = ctx;
  size_t len = c->n - c->off < c->chunk ? c->n - c->off : c->chunk;
  *buf = (unsigned char *)c->p + c->off;
  c->off += len;
  return (unsigned)len;
}
static int back_out(void *ctx, unsigned char *buf, unsigned len) {
  BackCtx *c = ctx;
  buf_append(&c->out, buf, len, &c->cap);
  return 0;
}

static void inflate_back(void) {
  group_begin("inflateBack callback decoding");
  for (int e = 0; e < 2; e++)
    for (int d = 0; d < 2; d++)
      for (int ci = 2; ci < 8; ci++) {
        Buf z = {0};
        Buf *c = &corpus[ci];
        enc(P[e], c->p, c->n, 6, -15, 8, 0, &z);
        Api *A = P[d];
        z_stream s;
        memset(&s, 0, sizeof(s));
        u8 *window = xmalloc(32768);
        int r = Z(inflateBackInit_)(&s, 15, window, ZLIB_VERSION, (int)sizeof(s));
        CK(r == Z_OK, "%s: inflateBackInit %s", A->name, rname(r));
        BackCtx ctx = {z.p, z.n, 0, ci % 2 ? 1000 : 17, {0}, 0};
        r = Z(inflateBack)(&s, back_in, &ctx, back_out, &ctx);
        CK(r == Z_STREAM_END && ctx.out.n == c->n && memcmp(ctx.out.p, c->p, c->n) == 0, "%s->%s %s: inflateBack %s out=%zu/%zu", P[e]->name, A->name, c->name, rname(r), ctx.out.n, c->n);
        Z(inflateBackEnd)(&s);
        free(window);
        free(ctx.out.p);
        free(z.p);
      }
  group_end();
}

static int write_file(const char *path, const u8 *p, size_t n) {
  FILE *f = fopen(path, "wb");
  if (!f) return -1;
  if (n) fwrite(p, 1, n, f);
  return fclose(f);
}

static u8 *read_file(const char *path, size_t *n) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long len = ftell(f);
  fseek(f, 0, SEEK_SET);
  u8 *p = xmalloc((size_t)len + 1);
  *n = fread(p, 1, (size_t)len, f);
  fclose(f);
  return p;
}

static void gz_write(Api *A, const char *path, const char *mode, const u8 *p, size_t n, int style, int *wr, int *cr) {
  gzFile f = Z(gzopen)(path, mode);
  if (!f) { *wr = -100; *cr = -100; return; }
  *wr = 0;
  if (style == 0) {
    for (size_t off = 0; off < n; off += 1000) { size_t l = n - off < 1000 ? n - off : 1000; if (Z(gzwrite)(f, p + off, (unsigned)l) != (int)l) *wr = -1; }
  } else if (style == 1) {
    size_t items = Z(gzfwrite)(p, 1, n, f);
    if (items != n) *wr = -1;
  } else {
    size_t off = 0;
    for (; off < n && off < 50; off++) if ((Z(gzputc)(f, p[off])) != p[off]) *wr = -1;
    if (off < n && Z(gzwrite)(f, p + off, (unsigned)(n - off)) != (int)(n - off)) *wr = -1;
    if (Z(gzflush)(f, Z_SYNC_FLUSH) != Z_OK) *wr = -2;
  }
  *cr = Z(gzclose_w)(f);
}

static int gz_read(Api *A, const char *path, int style, Buf *out, int *errnum, int *cr) {
  gzFile f = Z(gzopen)(path, "rb");
  out->p = NULL; out->n = 0;
  if (!f) return -1;
  size_t cap = 0;
  if (style == 4) Z(gzbuffer)(f, 8);
  u8 tmp[512];
  int total = 0;
  z_off_t pos = 0;
  if (style == 0 || style == 4) {
    int r;
    while ((r = Z(gzread)(f, tmp, sizeof(tmp))) > 0) buf_append(out, tmp, (size_t)r, &cap);
    total = r < 0 ? -1 : 0;
  } else if (style == 1) {
    int c, i = 0;
    while ((c = (Z(gzgetc))(f)) != -1) {
      if (i++ == 7) { Z(gzungetc)(c, f); c = (Z(gzgetc))(f); }
      u8 b = (u8)c;
      buf_append(out, &b, 1, &cap);
    }
  } else if (style == 2) {
    char line[200];
    while (Z(gzgets)(f, line, sizeof(line))) {
      z_off_t now = Z(gztell)(f);
      size_t len = (size_t)(now - pos);
      pos = now;
      buf_append(out, (u8 *)line, len, &cap);
    }
  } else {
    size_t r;
    while ((r = Z(gzfread)(tmp, 1, 300, f)) > 0) buf_append(out, tmp, r, &cap);
  }
  const char *msg;
  *errnum = 0;
  Z(gzerror)(f, errnum);
  (void)msg;
  *cr = Z(gzclose_r)(f);
  return total;
}

static void gzip_files(void) {
  group_begin("gzip files: write, read, seek, direct, append, truncated and corrupt");
  char path[512], path2[512];
  snprintf(path, sizeof(path), "%s/gz-%d.gz", g_tmp, (int)getpid());
  snprintf(path2, sizeof(path2), "%s/gz-%d.plain", g_tmp, (int)getpid());
  static const char *modes[] = {"wb", "wb1", "wb6", "wb9", "wb9f", "wb6h", "wb6R", "wb6F", "wb0"};
  static const int sel[] = {0, 1, 2, 3, 4, 7};
  for (int mi = 0; mi < 9; mi++)
    for (int si = 0; si < 6; si++) {
      Buf *c = &corpus[sel[si]];
      for (int e = 0; e < 2; e++)
        for (int style = 0; style < 3; style++) {
          int wr, cr;
          gz_write(P[e], path, modes[mi], c->p, c->n, style, &wr, &cr);
          CK(wr == 0 && cr == Z_OK, "%s %s mode=%s style=%d: write %d close %d", P[e]->name, c->name, modes[mi], style, wr, cr);
          for (int rs = 0; rs < 5; rs++)
            for (int d = 0; d < 2; d++) {
              int last_en = 0, last_rc = 0;
              Buf o;
              int en, rc;
              if (d == 1) { Buf o0; gz_read(P[0], path, rs, &o0, &last_en, &last_rc); free(o0.p); }
              gz_read(P[d], path, rs, &o, &en, &rc);
              CK(o.n == c->n && (c->n == 0 || memcmp(o.p, c->p, c->n) == 0), "%s->%s %s mode=%s write-style=%d read-style=%d: n=%zu/%zu", P[e]->name, P[d]->name, c->name, modes[mi], style, rs, o.n, c->n);
              if (d == 1) CK(en == last_en && rc == last_rc, "%s %s mode=%s read-style=%d: gzerror %d close %d, oracle reader gave %d and %d", P[e]->name, c->name, modes[mi], rs, en, rc, last_en, last_rc);
              last_en = en; last_rc = rc;
              free(o.p);
            }
        }
    }

  for (int e = 0; e < 2; e++) {
    int wr, cr;
    gz_write(P[e], path, "wb6", corpus[2].p, 50000, 0, &wr, &cr);
    gz_write(P[e], path, "ab6", corpus[2].p + 50000, 20000, 0, &wr, &cr);
    for (int d = 0; d < 2; d++) {
      Buf o;
      int en, rc;
      gz_read(P[d], path, 0, &o, &en, &rc);
      CK(o.n == 70000 && memcmp(o.p, corpus[2].p, 70000) == 0 && en == 0, "%s->%s: concatenated members read %zu bytes err=%d", P[e]->name, P[d]->name, o.n, en);
      free(o.p);
    }
  }

  for (int e = 0; e < 2; e++) {
    int wr, cr;
    gz_write(P[e], path, "wb6", corpus[2].p, 100000, 0, &wr, &cr);
    for (int d = 0; d < 2; d++) {
      Api *A = P[d];
      gzFile f = Z(gzopen)(path, "rb");
      u8 tmp[300];
      CK(Z(gzdirect)(f) == 0, "%s: gzdirect on gzip data", A->name);
      long long pos = Z(gzseek)(f, 40000, SEEK_SET);
      CK(pos == 40000, "%s: gzseek forward returned %lld", A->name, pos);
      int r = Z(gzread)(f, tmp, sizeof(tmp));
      CK(r == (int)sizeof(tmp) && memcmp(tmp, corpus[2].p + 40000, sizeof(tmp)) == 0, "%s: read after gzseek %d", A->name, r);
      CK(Z(gztell)(f) == 40000 + (long)sizeof(tmp), "%s: gztell %ld", A->name, (long)Z(gztell)(f));
      pos = Z(gzseek)(f, 1000, SEEK_CUR);
      CK(pos == 41300, "%s: gzseek SEEK_CUR returned %lld", A->name, pos);
      pos = Z(gzseek)(f, 100, SEEK_SET);
      CK(pos == 100, "%s: gzseek backward returned %lld", A->name, pos);
      r = Z(gzread)(f, tmp, 100);
      CK(r == 100 && memcmp(tmp, corpus[2].p + 100, 100) == 0, "%s: read after backward gzseek %d", A->name, r);
      CK(Z(gzrewind)(f) == 0, "%s: gzrewind", A->name);
      r = Z(gzread)(f, tmp, 10);
      CK(r == 10 && memcmp(tmp, corpus[2].p, 10) == 0, "%s: read after gzrewind %d", A->name, r);
      CK(Z(gzoffset)(f) > 0, "%s: gzoffset", A->name);
      Z(gzseek)(f, 0, SEEK_END);
      CK(1, "seek end");
      Z(gzclose)(f);
      f = Z(gzopen)(path, "rb");
      Z(gzbuffer)(f, 100);
      Buf o = {0};
      size_t cap = 0;
      while ((r = Z(gzread)(f, tmp, sizeof(tmp))) > 0) buf_append(&o, tmp, (size_t)r, &cap);
      CK(Z(gzeof)(f) == 1 && o.n == 100000, "%s: gzeof %d total %zu", A->name, Z(gzeof)(f), o.n);
      Z(gzclose)(f);
      free(o.p);
    }
  }

  write_file(path2, corpus[7].p, corpus[7].n);
  for (int d = 0; d < 2; d++) {
    Api *A = P[d];
    gzFile f = Z(gzopen)(path2, "rb");
    CK(Z(gzdirect)(f) == 1, "%s: gzdirect on plain file", A->name);
    u8 tmp[400];
    int r = Z(gzread)(f, tmp, sizeof(tmp));
    CK(r == (int)corpus[7].n && memcmp(tmp, corpus[7].p, corpus[7].n) == 0, "%s: transparent read %d", A->name, r);
    Z(gzclose)(f);
    int fd = open(path2, O_RDONLY);
    f = Z(gzdopen)(fd, "rb");
    r = Z(gzread)(f, tmp, sizeof(tmp));
    CK(r == (int)corpus[7].n, "%s: gzdopen read %d", A->name, r);
    Z(gzclose)(f);
    f = Z(gzopen)(path, "wb");
    CK(Z(gzsetparams)(f, 9, Z_HUFFMAN_ONLY) == Z_OK, "%s: gzsetparams", A->name);
    Z(gzwrite)(f, corpus[7].p, 100);
    CK(Z(gzsetparams)(f, 1, Z_DEFAULT_STRATEGY) == Z_OK, "%s: gzsetparams again", A->name);
    Z(gzwrite)(f, corpus[7].p + 100, 200);
    CK(Z(gzclose_w)(f) == Z_OK, "%s: gzclose_w", A->name);
    for (int d2 = 0; d2 < 2; d2++) {
      Buf o; int en, rc;
      gz_read(P[d2], path, 0, &o, &en, &rc);
      CK(o.n == 300 && memcmp(o.p, corpus[7].p, 300) == 0, "%s->%s: gzsetparams stream read %zu", A->name, P[d2]->name, o.n);
      free(o.p);
    }
    f = Z(gzopen)("/nonexistent-dir/none.gz", "rb");
    CK(f == NULL, "%s: gzopen of a missing file returned a handle", A->name);
  }

  for (int e = 0; e < 2; e++) {
    int wr, cr;
    gz_write(P[e], path, "wb6", corpus[2].p, 2000, 0, &wr, &cr);
    size_t zn;
    u8 *z = read_file(path, &zn);
    for (size_t cut = 0; cut < zn; cut += (cut < 40 ? 1 : 7)) {
      write_file(path2, z, cut);
      Buf o[2]; int en[2], rc[2], tot[2];
      for (int d = 0; d < 2; d++) tot[d] = gz_read(P[d], path2, 0, &o[d], &en[d], &rc[d]);
      int same = o[0].n == o[1].n && en[0] == en[1] && rc[0] == rc[1] && tot[0] == tot[1] && (o[0].n == 0 || memcmp(o[0].p, o[1].p, o[0].n) == 0);
      if (!same && cut < 4 && o[0].n == cut && memcmp(o[0].p, z, cut) == 0 && o[1].n == 0 && en[0] == 0 && rc[0] == 0 && en[1] == Z_BUF_ERROR && rc[1] == Z_BUF_ERROR) {
        kd_count[KD_GZ_SHORT_HEADER]++;
        same = 1;
      }
      CK(same, "%s file truncated at %zu/%zu: oracle read=%zu err=%d close=%d candidate read=%zu err=%d close=%d", P[e]->name, cut, zn, o[0].n, en[0], rc[0], o[1].n, en[1], rc[1]);
      free(o[0].p); free(o[1].p);
    }
    for (size_t pos = 0; pos < zn; pos += (pos < 40 ? 1 : 211))
      for (int mask = 1; mask <= 0x80; mask <<= 3) {
        z[pos] ^= (u8)mask;
        write_file(path2, z, zn);
        z[pos] ^= (u8)mask;
        Buf o[2]; int en[2], rc[2], tot[2];
        for (int d = 0; d < 2; d++) tot[d] = gz_read(P[d], path2, 0, &o[d], &en[d], &rc[d]);
        int oracle_exact = o[0].n == 2000 && memcmp(o[0].p, corpus[2].p, 2000) == 0 && en[0] == 0 && rc[0] == 0;
        int cand_prefix = o[1].n <= 2000 && memcmp(o[1].p, corpus[2].p, o[1].n) == 0;
        if (en[0] != 0 || rc[0] != 0) {
          int same_bytes = o[1].n == o[0].n && (o[0].n == 0 || memcmp(o[0].p, o[1].p, o[0].n) == 0);
          CK(en[1] == en[0] && rc[1] == rc[0] && (cand_prefix || same_bytes), "%s file corrupt at %zu^%02x: oracle read=%zu err=%d close=%d candidate read=%zu err=%d close=%d prefix=%d", P[e]->name, pos, mask, o[0].n, en[0], rc[0], o[1].n, en[1], rc[1], cand_prefix);
          if (!same_bytes) kd_count[KD_GZ_DELIVER_ALL]++;
        } else if (oracle_exact) {
          CK(o[1].n == 2000 && cand_prefix && en[1] == 0 && rc[1] == 0, "%s file corrupt at %zu^%02x: benign for the oracle, candidate read=%zu err=%d close=%d", P[e]->name, pos, mask, o[1].n, en[1], rc[1]);
        } else {
          int identical = o[1].n == o[0].n && (o[0].n == 0 || memcmp(o[0].p, o[1].p, o[0].n) == 0) && en[1] == 0 && rc[1] == 0;
          CK(identical || en[1] != 0 || rc[1] != 0, "%s file corrupt at %zu^%02x: oracle read=%zu err=0, candidate read=%zu err=0 with different bytes", P[e]->name, pos, mask, o[0].n, o[1].n);
          if (!identical) kd_count[KD_GZ_TOLERANT]++;
        }
        free(o[0].p); free(o[1].p);
      }
    free(z);
  }
  unlink(path);
  unlink(path2);
  group_end();
}

static void checksums(void) {
  group_begin("crc32 and adler32, chunked, combined and unaligned");
  for (int ci = 0; ci < NCORPUS; ci++) {
    Buf *c = &corpus[ci];
    for (int init = 0; init < 3; init++) {
      uLong ci0 = init == 0 ? P[0]->crc32(0, NULL, 0) : (init == 1 ? 0xdeadbeef : 0xffffffff);
      uLong ai0 = init == 0 ? P[0]->adler32(0, NULL, 0) : (init == 1 ? 0x12345678 : 0x0);
      uLong c0 = P[0]->crc32(ci0, c->p, (uInt)c->n), c1 = P[1]->crc32(ci0, c->p, (uInt)c->n);
      uLong a0 = P[0]->adler32(ai0, c->p, (uInt)c->n), a1 = P[1]->adler32(ai0, c->p, (uInt)c->n);
      CK(c0 == c1, "%s init=%d: crc32 oracle %lx candidate %lx", c->name, init, c0, c1);
      CK(a0 == a1, "%s init=%d: adler32 oracle %lx candidate %lx", c->name, init, a0, a1);
      CK(P[0]->crc32_z(ci0, c->p, c->n) == P[1]->crc32_z(ci0, c->p, c->n), "%s: crc32_z", c->name);
      CK(P[0]->adler32_z(ai0, c->p, c->n) == P[1]->adler32_z(ai0, c->p, c->n), "%s: adler32_z", c->name);
      for (int split = 0; split < 12 && c->n > 0; split++) {
        size_t at = rnd() % (c->n + 1);
        for (int e = 0; e < 2; e++) {
          Api *A = P[e];
          uLong x = Z(crc32)(ci0, c->p, (uInt)at);
          x = Z(crc32)(x, c->p + at, (uInt)(c->n - at));
          CK(x == c0, "%s %s split %zu: chunked crc32 %lx != %lx", A->name, c->name, at, x, c0);
          uLong y = Z(adler32)(ai0, c->p, (uInt)at);
          y = Z(adler32)(y, c->p + at, (uInt)(c->n - at));
          CK(y == a0, "%s %s split %zu: chunked adler32 %lx != %lx", A->name, c->name, at, y, a0);
          uLong crc_a = Z(crc32)(0, c->p, (uInt)at), crc_b = Z(crc32)(0, c->p + at, (uInt)(c->n - at));
          CK(Z(crc32_combine)(crc_a, crc_b, (z_off_t)(c->n - at)) == Z(crc32)(0, c->p, (uInt)c->n), "%s %s split %zu: crc32_combine", A->name, c->name, at);
          uLong ad_a = Z(adler32)(1, c->p, (uInt)at), ad_b = Z(adler32)(1, c->p + at, (uInt)(c->n - at));
          CK(Z(adler32_combine)(ad_a, ad_b, (z_off_t)(c->n - at)) == Z(adler32)(1, c->p, (uInt)c->n), "%s %s split %zu: adler32_combine", A->name, c->name, at);
        }
        CK(P[0]->crc32_combine(c0, c1, (z_off_t)at) == P[1]->crc32_combine(c0, c1, (z_off_t)at), "crc32_combine arbitrary operands");
        CK(P[0]->adler32_combine(a0, a1, (z_off_t)at) == P[1]->adler32_combine(a0, a1, (z_off_t)at), "adler32_combine arbitrary operands");
      }
    }
  }
  u8 *big = xmalloc(70000 + 32);
  for (size_t i = 0; i < 70000 + 32; i++) big[i] = (u8)rnd();
  for (size_t off = 0; off < 32; off++)
    for (size_t len = 0; len < 70000; len += (len < 300 ? 1 : 3331)) {
      CK(P[0]->crc32(0, big + off, (uInt)len) == P[1]->crc32(0, big + off, (uInt)len), "crc32 off=%zu len=%zu", off, len);
      CK(P[0]->adler32(1, big + off, (uInt)len) == P[1]->adler32(1, big + off, (uInt)len), "adler32 off=%zu len=%zu", off, len);
    }
  memset(big, 0xff, 70000);
  CK(P[0]->adler32(1, big, 70000) == P[1]->adler32(1, big, 70000), "adler32 of 0xff block (NMAX overflow)");
  CK(P[0]->adler32(0xffffffff, big, 70000) == P[1]->adler32(0xffffffff, big, 70000), "adler32 of 0xff block from an overflowing state");
  free(big);
  for (int e = 0; e < 2; e++) {
    Api *A = P[e];
    CK(Z(crc32)(0, NULL, 0) == 0, "%s: crc32 initial value", A->name);
    CK(Z(adler32)(1, NULL, 0) == 1, "%s: adler32(NULL) value %lu", A->name, Z(adler32)(1, NULL, 0));
    CK(Z(adler32)(0, NULL, 0) == 1, "%s: adler32 initial value", A->name);
    CK(Z(crc32)(0, (const Bytef *)"123456789", 9) == 0xcbf43926ul, "%s: crc32 check value %lx", A->name, Z(crc32)(0, (const Bytef *)"123456789", 9));
    CK(Z(adler32)(1, (const Bytef *)"Wikipedia", 9) == 0x11E60398ul, "%s: adler32 check value", A->name);
  }
  group_end();
}

typedef struct { int ret; size_t outn; int out_ok; } Outcome;

static Outcome run_dec(Api *A, const u8 *z, size_t zn, int wbits, const u8 *expect, size_t en) {
  Outcome o;
  u8 *out = xmalloc(en + 4096);
  size_t got = 0;
  o.ret = dec(A, z, zn, wbits, out, en + 4096, &got, NULL);
  o.outn = got;
  o.out_ok = got == en && (en == 0 || memcmp(out, expect, en) == 0);
  free(out);
  return o;
}

static void hostile_inputs(void) {
  group_begin("truncated, corrupt and trailing input: identical error classes");
  static const int fmts[] = {15, -15, 31};
  static const char *fname[] = {"zlib", "raw", "gzip"};
  int sel[] = {7, 2};
  for (int si = 0; si < 2; si++)
    for (int fi = 0; fi < 3; fi++)
      for (int e = 0; e < 2; e++) {
        Buf *c = &corpus[sel[si]];
        size_t n = si ? 3000 : c->n;
        Buf z = {0};
        enc(P[e], c->p, n, si ? 9 : 6, fmts[fi], 8, 0, &z);
        int dw = fmts[fi] < 0 ? -15 : 15 + 32;
        for (size_t cut = 0; cut < z.n; cut += (z.n > 400 && cut > 20 && cut + 20 < z.n) ? 13 : 1) {
          Outcome a = run_dec(P[0], z.p, cut, dw, c->p, n), b = run_dec(P[1], z.p, cut, dw, c->p, n);
          CK(a.ret == b.ret, "%s %s %s truncated to %zu/%zu: oracle %s candidate %s", P[e]->name, c->name, fname[fi], cut, z.n, rname(a.ret), rname(b.ret));
        }
        for (size_t pos = 0; pos < z.n; pos += (z.n > 400 && pos > 20 && pos + 20 < z.n) ? 5 : 1)
          for (int mi = 0; mi < 4; mi++) {
            static const u8 masks[] = {0x01, 0x10, 0x80, 0xff};
            z.p[pos] ^= masks[mi];
            Outcome a = run_dec(P[0], z.p, z.n, dw, c->p, n), b = run_dec(P[1], z.p, z.n, dw, c->p, n);
            z.p[pos] ^= masks[mi];
            CK(a.ret == b.ret && (a.ret != Z_STREAM_END || (a.outn == b.outn && a.out_ok == b.out_ok)), "%s %s %s byte %zu ^%02x: oracle %s (out %zu ok=%d) candidate %s (out %zu ok=%d)", P[e]->name, c->name, fname[fi], pos, masks[mi], rname(a.ret), a.outn, a.out_ok, rname(b.ret), b.outn, b.out_ok);
          }
        u8 *trail = xmalloc(z.n + 8);
        memcpy(trail, z.p, z.n);
        memcpy(trail + z.n, "TRAILING", 8);
        for (int d = 0; d < 2; d++) {
          uLong tin = 0;
          size_t got = 0;
          u8 *out = xmalloc(n + 1);
          int r = dec(P[d], trail, z.n + 8, dw, out, n + 1, &got, &tin);
          CK(r == Z_STREAM_END && tin == z.n && got == n, "%s->%s %s %s trailing bytes: %s consumed %lu/%zu", P[e]->name, P[d]->name, c->name, fname[fi], rname(r), tin, z.n);
          free(out);
        }
        free(trail);
        free(z.p);
      }

  Buf z = {0};
  enc(P[0], corpus[7].p, corpus[7].n, 6, 15, 8, 0, &z);
  u8 junk[64];
  for (int k = 0; k < 400; k++) {
    size_t jn = 1 + rnd() % sizeof(junk);
    for (size_t i = 0; i < jn; i++) junk[i] = (u8)rnd();
    if (k % 3 == 0) { junk[0] = 0x78; junk[1] = 0x9c; }
    if (k % 3 == 1) { junk[0] = 0x1f; junk[1] = 0x8b; junk[2] = 8; }
    int wbs[] = {15, -15, 47};
    for (int w = 0; w < 3; w++) {
      Outcome a = run_dec(P[0], junk, jn, wbs[w], corpus[7].p, 0), b = run_dec(P[1], junk, jn, wbs[w], corpus[7].p, 0);
      CK(a.ret == b.ret, "random input %d wb=%d: oracle %s candidate %s", k, wbs[w], rname(a.ret), rname(b.ret));
    }
  }
  free(z.p);
  group_end();
}

static void invalid_arguments(void) {
  group_begin("invalid arguments, version checks and bounded outputs");
  static const int levels[] = {-2, 10, 11};
  static const int wbitsv[] = {0, 7, 8, 16, -8, -7, 32, 40, 16 + 8, 16 + 7};
  static const int mems[] = {0, 10};
  for (int w = 0; w < 10; w++)
    for (int l = -2; l <= 10; l++)
      for (int m = 0; m <= 10; m += (m == 0 ? 1 : (m == 1 ? 7 : 2)))
        for (int st = -1; st <= 5; st++) {
          int r[2];
          for (int e = 0; e < 2; e++) {
            z_stream s;
            memset(&s, 0, sizeof(s));
            r[e] = P[e]->deflateInit2_(&s, l, Z_DEFLATED, wbitsv[w], m, st, ZLIB_VERSION, (int)sizeof(s));
            if (r[e] == Z_OK) P[e]->deflateEnd(&s);
          }
          CK(r[0] == r[1], "deflateInit2 level=%d wbits=%d mem=%d strategy=%d: oracle %s candidate %s", l, wbitsv[w], m, st, rname(r[0]), rname(r[1]));
        }
  (void)levels; (void)mems;
  for (int w = -20; w <= 50; w++) {
    int r[2];
    for (int e = 0; e < 2; e++) {
      z_stream s;
      memset(&s, 0, sizeof(s));
      r[e] = P[e]->inflateInit2_(&s, w, ZLIB_VERSION, (int)sizeof(s));
      if (r[e] == Z_OK) P[e]->inflateEnd(&s);
    }
    CK(r[0] == r[1], "inflateInit2 wbits=%d: oracle %s candidate %s", w, rname(r[0]), rname(r[1]));
  }
  int bad_flush[2] = {0, 0};
  for (int e = 0; e < 2; e++) {
    Api *A = P[e];
    z_stream s;
    memset(&s, 0, sizeof(s));
    int r = Z(deflateInit2_)(&s, 6, Z_DEFLATED, 15, 8, 0, "0.0.1", (int)sizeof(s));
    CK(r == Z_VERSION_ERROR, "%s: deflateInit with version 0.0.1 gave %s", A->name, rname(r));
    r = Z(deflateInit2_)(&s, 6, Z_DEFLATED, 15, 8, 0, ZLIB_VERSION, (int)sizeof(s) - 4);
    CK(r == Z_VERSION_ERROR, "%s: deflateInit with wrong stream size gave %s", A->name, rname(r));
    r = Z(inflateInit2_)(&s, 15, "9.9", (int)sizeof(s));
    CK(r == Z_VERSION_ERROR, "%s: inflateInit with version 9.9 gave %s", A->name, rname(r));
    r = Z(inflateInit2_)(&s, 15, NULL, (int)sizeof(s));
    CK(r == Z_VERSION_ERROR, "%s: inflateInit with NULL version gave %s", A->name, rname(r));
    r = Z(inflateInit2_)(NULL, 15, ZLIB_VERSION, (int)sizeof(s));
    CK(r == Z_STREAM_ERROR, "%s: inflateInit with NULL stream gave %s", A->name, rname(r));
    CK(Z(deflate)(NULL, Z_NO_FLUSH) == Z_STREAM_ERROR, "%s: deflate(NULL)", A->name);
    CK(Z(inflate)(NULL, Z_NO_FLUSH) == Z_STREAM_ERROR, "%s: inflate(NULL)", A->name);
    CK(Z(deflateEnd)(NULL) == Z_STREAM_ERROR, "%s: deflateEnd(NULL)", A->name);
    CK(Z(inflateEnd)(NULL) == Z_STREAM_ERROR, "%s: inflateEnd(NULL)", A->name);
    CK(Z(deflateReset)(NULL) == Z_STREAM_ERROR, "%s: deflateReset(NULL)", A->name);
    memset(&s, 0, sizeof(s));
    CK(Z(deflate)(&s, Z_NO_FLUSH) == Z_STREAM_ERROR, "%s: deflate on an uninitialized stream", A->name);
    Z(inflateInit2_)(&s, 15, ZLIB_VERSION, (int)sizeof(s));
    u8 out[16];
    s.next_out = out; s.avail_out = sizeof(out); s.next_in = NULL; s.avail_in = 0;
    r = Z(inflate)(&s, Z_NO_FLUSH);
    CK(r == Z_BUF_ERROR, "%s: inflate with no input gave %s", A->name, rname(r));
    r = Z(inflate)(&s, 99);
    bad_flush[e] = r;
    Z(inflateEnd)(&s);
    for (int code = -7; code <= 3; code++) {
      const char *a = P[0]->zError(code), *b = P[1]->zError(code);
      CK(a && b && strcmp(a, b) == 0, "zError(%d): oracle \"%s\" candidate \"%s\"", code, a ? a : "(null)", b ? b : "(null)");
    }
  }
  CK(bad_flush[0] == bad_flush[1], "inflate with an invalid flush value: oracle %s candidate %s", rname(bad_flush[0]), rname(bad_flush[1]));
  printf("  info zlibVersion: oracle %s candidate %s\n", P[0]->zlibVersion(), P[1]->zlibVersion());
  CK(P[0]->zlibVersion()[0] == P[1]->zlibVersion()[0], "zlibVersion major differs");
  uLong f0 = P[0]->zlibCompileFlags(), f1 = P[1]->zlibCompileFlags();
  CK((f0 & 0xff) == (f1 & 0xff), "zlibCompileFlags type-size bits: oracle %lx candidate %lx", f0, f1);
  printf("  info zlibCompileFlags: oracle %#lx candidate %#lx\n", f0, f1);

  for (int e = 0; e < 2; e++) {
    Buf z = {0};
    enc(P[e], corpus[2].p, 50000, 6, 15, 8, 0, &z);
    u8 *buf[2] = {xmalloc(50001), xmalloc(50001)};
    for (uLong cap = 0; cap <= 50000; cap += (cap < 100 ? 1 : 4999))
      for (int variant = 0; variant < 2; variant++) {
        int r[2];
        uLongf dl[2];
        uLong sl[2];
        for (int d = 0; d < 2; d++) {
          dl[d] = cap;
          sl[d] = z.n;
          r[d] = variant ? P[d]->uncompress2(buf[d], &dl[d], z.p, &sl[d]) : P[d]->uncompress(buf[d], &dl[d], z.p, (uLong)z.n);
        }
        if (cap == 0 && r[0] == Z_BUF_ERROR && r[1] == Z_DATA_ERROR && dl[0] == 0 && dl[1] == 0) {
          kd_count[KD_UNCOMPRESS_ZERO]++;
          continue;
        }
        CK(r[0] == r[1] && dl[0] == dl[1] && (!variant || sl[0] == sl[1]), "%s output, %s into %lu of 50000 bytes: oracle %s (out %lu in %lu) candidate %s (out %lu in %lu)", P[e]->name, variant ? "uncompress2" : "uncompress", cap, rname(r[0]), (unsigned long)dl[0], (unsigned long)sl[0], rname(r[1]), (unsigned long)dl[1], (unsigned long)sl[1]);
      }
    for (size_t cut = 0; cut <= z.n; cut += 311) {
      int r[2];
      uLongf dl[2];
      for (int d = 0; d < 2; d++) {
        dl[d] = 50000;
        r[d] = P[d]->uncompress(buf[d], &dl[d], z.p, (uLong)cut);
      }
      CK(r[0] == r[1] && dl[0] == dl[1], "%s output truncated to %zu/%zu: oracle %s (out %lu) candidate %s (out %lu)", P[e]->name, cut, z.n, rname(r[0]), (unsigned long)dl[0], rname(r[1]), (unsigned long)dl[1]);
    }
    for (int d = 0; d < 2; d++) free(buf[d]);
    free(z.p);
  }
  {
    static const u8 empty_stream[8] = {0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01};
    for (uLong cap = 0; cap < 3; cap++) {
      int r[2];
      uLongf dl[2];
      uLong sl[2];
      u8 out[4];
      for (int d = 0; d < 2; d++) {
        dl[d] = cap;
        sl[d] = sizeof(empty_stream);
        r[d] = P[d]->uncompress2(out, &dl[d], empty_stream, &sl[d]);
      }
      CK(r[0] == r[1] && r[0] == Z_OK && dl[0] == 0 && dl[1] == 0 && sl[0] == 8 && sl[1] == 8, "uncompress2 of an empty stream into %lu bytes: oracle %s consumed %lu, candidate %s consumed %lu", cap, rname(r[0]), (unsigned long)sl[0], rname(r[1]), (unsigned long)sl[1]);
    }
  }
  group_end();
}

static void bombs(void) {
  group_begin("decompression bomb: bounded output and total expansion");
  size_t total = (size_t)256 << 20;
  u8 *zeros = xmalloc(1 << 20);
  memset(zeros, 0, 1 << 20);
  for (int e = 0; e < 2; e++) {
    Api *A = P[e];
    z_stream s;
    memset(&s, 0, sizeof(s));
    Z(deflateInit2_)(&s, 9, Z_DEFLATED, 15, 9, Z_DEFAULT_STRATEGY, ZLIB_VERSION, (int)sizeof(s));
    Buf z = {0};
    size_t cap = 0;
    u8 tmp[65536];
    for (size_t done = 0; done < total; done += 1 << 20) {
      s.next_in = zeros; s.avail_in = 1 << 20;
      do {
        s.next_out = tmp; s.avail_out = sizeof(tmp);
        Z(deflate)(&s, done + (1 << 20) >= total ? Z_FINISH : Z_NO_FLUSH);
        buf_append(&z, tmp, sizeof(tmp) - s.avail_out, &cap);
      } while (s.avail_out == 0);
    }
    Z(deflateEnd)(&s);
    printf("  info %s compressed %zu MiB of zeros into %zu bytes\n", A->name, total >> 20, z.n);
    for (int d = 0; d < 2; d++) {
      Api *B = P[d];
      z_stream t;
      memset(&t, 0, sizeof(t));
      B->inflateInit2_(&t, 15, ZLIB_VERSION, (int)sizeof(t));
      t.next_in = z.p; t.avail_in = (uInt)z.n;
      uLong crc = B->crc32(0, NULL, 0);
      size_t sunk = 0;
      int r;
      do {
        t.next_out = tmp; t.avail_out = sizeof(tmp);
        r = B->inflate(&t, Z_NO_FLUSH);
        crc = B->crc32(crc, tmp, (uInt)(sizeof(tmp) - t.avail_out));
        sunk += sizeof(tmp) - t.avail_out;
      } while (r == Z_OK);
      uLong expect = B->crc32(0, NULL, 0);
      for (size_t done = 0; done < total; done += 1 << 20) expect = B->crc32(expect, zeros, 1 << 20);
      CK(r == Z_STREAM_END && sunk == total && crc == expect, "%s->%s: full bomb inflate %s out=%zu crc %lx/%lx", A->name, B->name, rname(r), sunk, crc, expect);
      B->inflateEnd(&t);

      memset(&t, 0, sizeof(t));
      B->inflateInit2_(&t, 15, ZLIB_VERSION, (int)sizeof(t));
      t.next_in = z.p; t.avail_in = (uInt)z.n;
      size_t cap_total = 16 << 20, produced = 0;
      do {
        t.next_out = tmp; t.avail_out = (uInt)(cap_total - produced < sizeof(tmp) ? cap_total - produced : sizeof(tmp));
        size_t want = t.avail_out;
        r = B->inflate(&t, Z_NO_FLUSH);
        produced += want - t.avail_out;
      } while (r == Z_OK && produced < cap_total);
      CK(produced == cap_total && t.total_out == cap_total && t.avail_in > 0, "%s->%s: capped bomb inflate stopped at %zu (total_out %lu) with %s", A->name, B->name, produced, t.total_out, rname(r));
      B->inflateEnd(&t);

      uLongf dl = 1 << 20;
      u8 *dst = xmalloc(1 << 20);
      r = B->uncompress(dst, &dl, z.p, (uLong)z.n);
      CK(r == Z_BUF_ERROR, "%s->%s: uncompress of a 256 MiB bomb into 1 MiB gave %s", A->name, B->name, rname(r));
      free(dst);
    }
    free(z.p);
  }
  free(zeros);
  group_end();
}

typedef struct { long allocs, frees, live, fail_after, calls, seen_opaque_bad; } AllocState;

static voidpf counting_alloc(voidpf opaque, uInt items, uInt size) {
  AllocState *st = opaque;
  st->calls++;
  if (st->fail_after >= 0 && st->calls > st->fail_after) return Z_NULL;
  void *p = calloc(items, size);
  if (p) { st->allocs++; st->live++; }
  return p;
}

static void counting_free(voidpf opaque, voidpf p) {
  AllocState *st = opaque;
  if (!p) return;
  st->frees++;
  st->live--;
  free(p);
}

static void allocators(void) {
  group_begin("allocator hooks: opaque pointer, balance, failure at every allocation");
  for (int e = 0; e < 2; e++) {
    Api *A = P[e];
    int first_ok[2] = {-1, -1};
    for (int phase = 0; phase < 2; phase++)
      for (long fail = -1; fail < 40; fail++) {
        AllocState st = {0, 0, 0, fail, 0, 0};
        z_stream s;
        memset(&s, 0, sizeof(s));
        s.zalloc = counting_alloc; s.zfree = counting_free; s.opaque = &st;
        int r = phase == 0 ? Z(deflateInit2_)(&s, 6, Z_DEFLATED, 15, 8, 0, ZLIB_VERSION, (int)sizeof(s))
                           : Z(inflateInit2_)(&s, 15, ZLIB_VERSION, (int)sizeof(s));
        if (fail == 0) CK(r == Z_MEM_ERROR, "%s phase %d: init with an allocator that always fails gave %s", A->name, phase, rname(r));
        CK(r == Z_OK || r == Z_MEM_ERROR, "%s phase %d fail_after=%ld: init gave %s", A->name, phase, fail, rname(r));
        if (r == Z_OK) {
          if (first_ok[phase] < 0) first_ok[phase] = (int)fail;
          u8 out[4096];
          if (phase == 0) {
            s.next_in = corpus[7].p; s.avail_in = (uInt)corpus[7].n; s.next_out = out; s.avail_out = sizeof(out);
            r = Z(deflate)(&s, Z_FINISH);
            CK(r == Z_STREAM_END || r == Z_MEM_ERROR, "%s fail_after=%ld: deflate gave %s", A->name, fail, rname(r));
            Z(deflateEnd)(&s);
          } else {
            Buf z = {0};
            enc(P[0], corpus[7].p, corpus[7].n, 6, 15, 8, 0, &z);
            s.next_in = z.p; s.avail_in = (uInt)z.n; s.next_out = out; s.avail_out = sizeof(out);
            r = Z(inflate)(&s, Z_NO_FLUSH);
            CK(r == Z_STREAM_END || r == Z_MEM_ERROR, "%s fail_after=%ld: inflate gave %s", A->name, fail, rname(r));
            Z(inflateEnd)(&s);
            free(z.p);
          }
        }
        CK(st.live == 0 && st.allocs == st.frees, "%s phase %d fail_after=%ld: %ld allocations, %ld frees, %ld live", A->name, phase, fail, st.allocs, st.frees, st.live);
      }
    printf("  info %s: first successful init with fail_after deflate=%d inflate=%d\n", A->name, first_ok[0], first_ok[1]);
  }
  group_end();
}

static void inflate_sync(void) {
  group_begin("inflateSync recovery after a damaged region");
  for (int e = 0; e < 2; e++) {
    Buf z = {0};
    Pace pace = {2000, 4096, 1, Z_FULL_FLUSH};
    enc_stream(P[e], corpus[2].p, 20000, 6, 15, pace, &z);
    u8 *damaged = xmalloc(z.n);
    memcpy(damaged, z.p, z.n);
    for (int i = 300; i < 340; i++) damaged[i] ^= 0xa5;
    for (int d = 0; d < 2; d++) {
      Api *A = P[d];
      z_stream s;
      memset(&s, 0, sizeof(s));
      Z(inflateInit2_)(&s, 15, ZLIB_VERSION, (int)sizeof(s));
      u8 *out = xmalloc(20001);
      s.next_in = damaged; s.avail_in = (uInt)z.n; s.next_out = out; s.avail_out = 20001;
      int r = Z(inflate)(&s, Z_NO_FLUSH);
      CK(r == Z_DATA_ERROR, "%s->%s: damaged stream inflate gave %s", P[e]->name, A->name, rname(r));
      r = Z(inflateSync)(&s);
      CK(r == Z_OK, "%s->%s: inflateSync gave %s", P[e]->name, A->name, rname(r));
      u8 *rest = xmalloc(20001);
      s.next_out = rest; s.avail_out = 20001;
      do { r = Z(inflate)(&s, Z_NO_FLUSH); } while (r == Z_OK);
      CK(r == Z_DATA_ERROR || r == Z_STREAM_END || r == Z_BUF_ERROR, "%s->%s: inflate after inflateSync gave %s", P[e]->name, A->name, rname(r));
      CK(20001 - s.avail_out > 5000, "%s->%s: only %u bytes recovered after inflateSync", P[e]->name, A->name, 20001 - s.avail_out);
      Z(inflateEnd)(&s);
      free(out); free(rest);
    }
    free(damaged); free(z.p);
  }
  group_end();
}

#define ADD(...) do { size_t l_ = strlen(out); if (l_ < cap) snprintf(out + l_, cap - l_, __VA_ARGS__); } while (0)

typedef void (*CaseFn)(Api *A, char *out, size_t cap);

static uint64_t fnv(const u8 *p, size_t n, uint64_t h) {
  for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 0x100000001b3ull; }
  return h;
}

static const uint64_t FNV0 = 0xcbf29ce484222325ull;

static uint64_t local_rnd(uint64_t *s) {
  *s ^= *s << 13;
  *s ^= *s >> 7;
  *s ^= *s << 17;
  return *s;
}

static void run_one(CaseFn fn, Api *A, char *out, size_t cap) {
  int fds[2];
  if (pipe(fds) != 0) exit(2);
  fflush(stdout);
  pid_t pid = fork();
  if (pid < 0) exit(2);
  if (pid == 0) {
    close(fds[0]);
    alarm(120);
    char text[2048];
    text[0] = 0;
    fn(A, text, sizeof(text));
    size_t len = strlen(text);
    size_t off = 0;
    while (off < len) {
      ssize_t w = write(fds[1], text + off, len - off);
      if (w <= 0) break;
      off += (size_t)w;
    }
    _exit(0);
  }
  close(fds[1]);
  size_t got = 0;
  ssize_t n;
  while (got + 1 < cap && (n = read(fds[0], out + got, cap - 1 - got)) > 0) got += (size_t)n;
  out[got] = 0;
  close(fds[0]);
  int status = 0;
  waitpid(pid, &status, 0);
  if (WIFSIGNALED(status)) ADD(" CRASH signal %d", WTERMSIG(status));
  else if (WEXITSTATUS(status) != 0) ADD(" EXIT %d", WEXITSTATUS(status));
}

#define NO_KD (-1)

static void run_case(const char *id, CaseFn fn, int kd, const char *oracle, const char *candidate) {
  char o[2][2048];
  for (int d = 0; d < 2; d++) { o[d][0] = 0; run_one(fn, P[d], o[d], sizeof(o[d])); }
  if (strcmp(o[0], o[1]) == 0) {
    if (kd >= 0) {
      printf("  info %s: the recorded divergence no longer occurs\n", id);
      CK(1, "%s", id);
      return;
    }
    CK(oracle == NULL || strstr(o[0], oracle) != NULL, "%s: the oracle no longer shows [%s]; it gave [%s]", id, oracle, o[0]);
    printf("  same %s: %.200s\n", id, o[0]);
    return;
  }
  if (kd >= 0 && oracle && candidate && strcmp(o[0], oracle) == 0 && strcmp(o[1], candidate) == 0) {
    kd_count[kd]++;
    CK(1, "%s", id);
    return;
  }
  printf("  difference %s: oracle [%s] candidate [%s]\n", id, o[0], o[1]);
  CK(0, "%s: unexplained difference", id);
}

static int tail_matches(const u8 *dict, uInt len, const u8 *data, size_t n) {
  return len <= n && memcmp(dict, data + n - len, len) == 0;
}

static void case_getdict_after_bad_window(Api *A, char *out, size_t cap) {
  static const u8 bad[2] = {0x88, 0x1c};
  Buf z = {0};
  enc(P[0], corpus[4].p, 100000, 6, 15, 8, 0, &z);
  z_stream s;
  memset(&s, 0, sizeof(s));
  int r = Z(inflateInit2_)(&s, 0, ZLIB_VERSION, (int)sizeof(s));
  ADD("init=%s ", rname(r));
  u8 junk[16];
  s.next_in = (Bytef *)bad; s.avail_in = 2; s.next_out = junk; s.avail_out = sizeof(junk);
  r = Z(inflate)(&s, Z_NO_FLUSH);
  ADD("bad-header=%s ", rname(r));
  r = Z(inflateReset)(&s);
  ADD("reset=%s ", rname(r));
  u8 *dst = xmalloc(100000);
  s.next_in = z.p; s.avail_in = (uInt)(z.n - 8); s.next_out = dst; s.avail_out = 100000;
  do { r = Z(inflate)(&s, Z_NO_FLUSH); } while (r == Z_OK);
  ADD("inflate=%s out=%lu ", rname(r), s.total_out);
  enum { GUARD = 8192 };
  u8 *dict = xmalloc(32768 + GUARD);
  memset(dict, 0xcd, 32768 + GUARD);
  uInt len = 0xffffffffu;
  r = Z(inflateGetDictionary)(&s, dict, &len);
  int guard = 1;
  for (size_t i = 32768; i < 32768 + GUARD; i++) if (dict[i] != 0xcd) { guard = 0; break; }
  ADD("getdict=%s len=%u guard-intact=%d tail-match=%d", rname(r), len, guard, len <= 32768 && tail_matches(dict, len, dst, s.total_out));
  Z(inflateEnd)(&s);
  free(dst); free(dict); free(z.p);
}

static void getdict_modes(Api *A, char *out, size_t cap, const int (*modes)[2], int count) {
  enum { GUARD = 4096, N = 50000 };
  for (int m = 0; m < count; m++) {
    Buf z = {0};
    enc(P[0], corpus[2].p, N, 6, modes[m][1], 8, 0, &z);
    z_stream s;
    memset(&s, 0, sizeof(s));
    Z(inflateInit2_)(&s, modes[m][0], ZLIB_VERSION, (int)sizeof(s));
    u8 *dst = xmalloc(N);
    u8 *dict = xmalloc(32768 + GUARD);
    uInt len = 77;
    memset(dict, 0xcd, 32768 + GUARD);
    int r0 = Z(inflateGetDictionary)(&s, dict, &len);
    uInt fresh = len;
    s.next_in = z.p; s.avail_in = (uInt)(z.n / 2); s.next_out = dst; s.avail_out = N;
    int rh = Z(inflate)(&s, Z_NO_FLUSH);
    len = 0;
    int r1 = Z(inflateGetDictionary)(&s, dict, &len);
    uInt half = len;
    int half_ok = len <= 32768 && tail_matches(dict, len, dst, s.total_out);
    s.next_in = z.p + z.n / 2; s.avail_in = (uInt)(z.n - z.n / 2);
    do { r1 = Z(inflate)(&s, Z_NO_FLUSH); } while (r1 == Z_OK);
    memset(dict, 0xcd, 32768 + GUARD);
    len = 0;
    int r2 = Z(inflateGetDictionary)(&s, dict, &len);
    int guard = 1;
    for (size_t i = 32768; i < 32768 + GUARD; i++) if (dict[i] != 0xcd) { guard = 0; break; }
    int tail = len <= 32768 && tail_matches(dict, len, dst, s.total_out);
    uInt only_len = 0;
    int r3 = Z(inflateGetDictionary)(&s, NULL, &only_len);
    int r4 = Z(inflateGetDictionary)(&s, dict, NULL);
    int r5 = Z(inflateGetDictionary)(&s, NULL, NULL);
    ADD("[wbits=%d fresh=%s/%u half=%s/%u/%d end=%s full=%s/%u/guard%d/tail%d len-only=%s/%u dict-only=%s none=%s] ", modes[m][0], rname(r0), fresh, rname(rh), half, half_ok, rname(r1), rname(r2), len, guard, tail, rname(r3), only_len, rname(r4), rname(r5));
    Z(inflateEnd)(&s);
    free(dst); free(dict); free(z.p);
  }
}

static void case_getdict_full_window(Api *A, char *out, size_t cap) {
  static const int modes[][2] = {{15, 15}, {0, 15}, {-15, -15}, {31, 31}, {47, 31}};
  getdict_modes(A, out, cap, modes, 5);
}

static void case_getdict_small_window(Api *A, char *out, size_t cap) {
  static const int modes[][2] = {{9, 9}, {-9, -9}};
  getdict_modes(A, out, cap, modes, 2);
}

static void case_window_reuse(Api *A, char *out, size_t cap) {
  Buf small = {0}, big = {0};
  enc(P[0], corpus[2].p, 3000, 6, 9, 8, 0, &small);
  enc(P[0], corpus[4].p, 80000, 6, 15, 8, 0, &big);
  z_stream s;
  memset(&s, 0, sizeof(s));
  Z(inflateInit2_)(&s, 0, ZLIB_VERSION, (int)sizeof(s));
  u8 *dst = xmalloc(100000);
  int r;
  s.next_in = small.p; s.avail_in = (uInt)small.n; s.next_out = dst; s.avail_out = 100000;
  do { r = Z(inflate)(&s, Z_NO_FLUSH); } while (r == Z_OK);
  ADD("small=%s/%lu ", rname(r), s.total_out);
  ADD("reset=%s ", rname(Z(inflateReset)(&s)));
  s.next_in = big.p; s.avail_in = (uInt)big.n; s.next_out = dst; s.avail_out = 100000;
  do { r = Z(inflate)(&s, Z_NO_FLUSH); } while (r == Z_OK);
  ADD("big=%s/%lu match=%d ", rname(r), s.total_out, s.total_out == 80000 && memcmp(dst, corpus[4].p, 80000) == 0);
  ADD("msg=%s ", s.msg ? s.msg : "none");
  Z(inflateEnd)(&s);
  memset(&s, 0, sizeof(s));
  Z(inflateInit2_)(&s, 0, ZLIB_VERSION, (int)sizeof(s));
  s.next_in = big.p; s.avail_in = (uInt)big.n; s.next_out = dst; s.avail_out = 100000;
  do { r = Z(inflate)(&s, Z_NO_FLUSH); } while (r == Z_OK);
  ADD("big-first=%s/%lu ", rname(r), s.total_out);
  ADD("reset-keep=%s ", rname(Z(inflateResetKeep)(&s)));
  s.next_in = small.p; s.avail_in = (uInt)small.n; s.next_out = dst; s.avail_out = 100000;
  do { r = Z(inflate)(&s, Z_NO_FLUSH); } while (r == Z_OK);
  ADD("small-after=%s/%lu", rname(r), s.total_out);
  Z(inflateEnd)(&s);
  free(dst); free(small.p); free(big.p);
}

static void sync_after_error(Api *A, char *out, size_t cap, int wbits, int enc_wbits, int flush_mode, int skip_header, int damage) {
  Buf z = {0};
  Pace pace = {2000, 4096, 1, flush_mode};
  enc_stream(P[0], corpus[2].p, 20000, 6, enc_wbits, pace, &z);
  if (damage) for (int i = 300; i < 340; i++) z.p[i] ^= 0xa5;
  z_stream s;
  memset(&s, 0, sizeof(s));
  int r = Z(inflateInit2_)(&s, wbits, ZLIB_VERSION, (int)sizeof(s));
  ADD("init=%s ", rname(r));
  enum { CAP = 20001, GUARD = 64 };
  u8 *dst = xmalloc(CAP + GUARD);
  memset(dst, 0xcd, CAP + GUARD);
  s.next_in = z.p + (skip_header ? 2 : 0); s.avail_in = (uInt)(z.n - (skip_header ? 2 : 0));
  s.next_out = dst; s.avail_out = CAP;
  r = Z(inflate)(&s, Z_NO_FLUSH);
  ADD("first=%s ", rname(r));
  r = Z(inflateSync)(&s);
  ADD("sync=%s ", rname(r));
  size_t before = CAP - s.avail_out;
  size_t got = before;
  do {
    s.next_out = dst + got;
    s.avail_out = (uInt)(CAP - got < 64 ? CAP - got : 64);
    uInt offered = s.avail_out;
    r = Z(inflate)(&s, Z_NO_FLUSH);
    got += offered - s.avail_out;
  } while (r == Z_OK && got < CAP);
  int guard = 1;
  for (size_t i = CAP; i < CAP + GUARD; i++) if (dst[i] != 0xcd) { guard = 0; break; }
  ADD("after=%s recovered=%zu hash=%016llx guard-intact=%d", rname(r), got - before, (unsigned long long)fnv(dst + before, got - before, FNV0), guard);
  Z(inflateEnd)(&s);
  free(dst); free(z.p);
}

static void case_sync_auto_window_full(Api *A, char *out, size_t cap) { sync_after_error(A, out, cap, 0, 15, Z_FULL_FLUSH, 1, 0); }
static void case_sync_auto_window_sync(Api *A, char *out, size_t cap) { sync_after_error(A, out, cap, 0, 15, Z_SYNC_FLUSH, 1, 0); }
static void case_sync_zlib_window(Api *A, char *out, size_t cap) { sync_after_error(A, out, cap, 15, 15, Z_FULL_FLUSH, 1, 0); }
static void case_sync_raw_window(Api *A, char *out, size_t cap) { sync_after_error(A, out, cap, -15, -15, Z_FULL_FLUSH, 0, 1); }
static void case_sync_gzip_auto(Api *A, char *out, size_t cap) { sync_after_error(A, out, cap, 47, 31, Z_FULL_FLUSH, 1, 0); }

static void case_inflate_prime(Api *A, char *out, size_t cap) {
  Buf z = {0};
  enc(P[0], corpus[2].p, 5000, 6, -15, 8, 0, &z);
  z_stream s;
  memset(&s, 0, sizeof(s));
  Z(inflateInit2_)(&s, -15, ZLIB_VERSION, (int)sizeof(s));
  int a = Z(inflatePrime)(&s, 4, z.p[0] & 15);
  int b = Z(inflatePrime)(&s, 4, z.p[0] >> 4);
  u8 *dst = xmalloc(5001);
  s.next_in = z.p + 1; s.avail_in = (uInt)(z.n - 1); s.next_out = dst; s.avail_out = 5001;
  int r;
  do { r = Z(inflate)(&s, Z_NO_FLUSH); } while (r == Z_OK);
  ADD("split-prime=%s,%s inflate=%s match=%d ", rname(a), rname(b), rname(r), s.total_out == 5000 && memcmp(dst, corpus[2].p, 5000) == 0);
  Z(inflateEnd)(&s);
  memset(&s, 0, sizeof(s));
  Z(inflateInit2_)(&s, -15, ZLIB_VERSION, (int)sizeof(s));
  ADD("sequence:");
  for (int i = 0; i < 6; i++) ADD(" %s", rname(Z(inflatePrime)(&s, 16, 0xbeef)));
  ADD(" 32=%s 17=%s 0=%s -1=%s ", rname(Z(inflatePrime)(&s, 32, 1)), rname(Z(inflatePrime)(&s, 17, 1)), rname(Z(inflatePrime)(&s, 0, 0)), rname(Z(inflatePrime)(&s, -1, 0)));
  Z(inflateEnd)(&s);
  uint64_t seed = 0x1234567ull;
  int ok = 0, data = 0, other = 0, buf = 0, end = 0, prime_err = 0;
  uint64_t h = FNV0;
  for (int t = 0; t < 300; t++) {
    memset(&s, 0, sizeof(s));
    Z(inflateInit2_)(&s, -15, ZLIB_VERSION, (int)sizeof(s));
    int n = (int)(local_rnd(&seed) % 5);
    for (int i = 0; i < n; i++) {
      int bits = (int)(local_rnd(&seed) % 17);
      int pr = Z(inflatePrime)(&s, bits, (int)(local_rnd(&seed) & 0xffff));
      if (pr != Z_OK) prime_err++;
      h = h * 31 + (uint64_t)(pr + 10);
    }
    size_t off = (size_t)(local_rnd(&seed) % 3);
    s.next_in = z.p + off; s.avail_in = (uInt)(z.n - off); s.next_out = dst; s.avail_out = 5001;
    do { r = Z(inflate)(&s, Z_NO_FLUSH); } while (r == Z_OK);
    h = fnv(dst, 5001 - s.avail_out, h * 31 + (uint64_t)(r + 10));
    if (r == Z_STREAM_END) end++; else if (r == Z_DATA_ERROR) data++; else if (r == Z_BUF_ERROR) buf++; else other++;
    (void)ok;
    Z(inflateEnd)(&s);
  }
  ADD("random-prime end=%d data=%d buf=%d other=%d prime-errors=%d hash=%016llx", end, data, buf, other, prime_err, (unsigned long long)h);
  free(dst); free(z.p);
}

static void deflate_prime_loop(Api *A, char *out, size_t cap, int wbits, int mem) {
  z_stream s;
  memset(&s, 0, sizeof(s));
  int r = Z(deflateInit2_)(&s, 6, Z_DEFLATED, wbits, mem, Z_DEFAULT_STRATEGY, ZLIB_VERSION, (int)sizeof(s));
  if (r != Z_OK) { ADD("[wbits=%d mem=%d init=%s] ", wbits, mem, rname(r)); return; }
  int first_fail = -1, fail_ret = Z_OK;
  for (int i = 0; i < 6000; i++) {
    r = Z(deflatePrime)(&s, 16, 0x5a5a);
    if (r != Z_OK) { first_fail = i; fail_ret = r; break; }
  }
  unsigned pending = 0;
  int bits = 0;
  Z(deflatePending)(&s, &pending, &bits);
  u8 buf[512];
  s.next_in = corpus[2].p; s.avail_in = 1000; s.next_out = buf; s.avail_out = sizeof(buf);
  r = Z(deflate)(&s, Z_FINISH);
  ADD("[wbits=%d mem=%d first-fail=%d/%s pending=%u/%d then-deflate=%s] ", wbits, mem, first_fail, rname(fail_ret), pending, bits, rname(r));
  Z(deflateEnd)(&s);
}

static void case_inflate_prime_fast_path(Api *A, char *out, size_t cap) {
  Buf z = {0};
  enc(P[0], corpus[2].p, 8000, 6, -15, 8, Z_FIXED, &z);
  u8 *dst = xmalloc(8400);
  for (int bytes = 1; bytes <= 4; bytes++) {
    z_stream s;
    memset(&s, 0, sizeof(s));
    Z(inflateInit2_)(&s, -15, ZLIB_VERSION, (int)sizeof(s));
    int pr = Z_OK;
    for (int done = 0; done < bytes; done += 2) {
      int take = bytes - done >= 2 ? 2 : 1;
      int value = z.p[done] | (take == 2 ? z.p[done + 1] << 8 : 0);
      pr |= Z(inflatePrime)(&s, take * 8, value);
    }
    size_t rest = z.n - (size_t)bytes;
    u8 *input = xmalloc(rest);
    memcpy(input, z.p + bytes, rest);
    s.next_in = input; s.avail_in = (uInt)rest;
    int r;
    do {
      s.next_out = dst + s.total_out; s.avail_out = 258;
      r = Z(inflate)(&s, Z_NO_FLUSH);
    } while (r == Z_OK);
    ADD("[primed-bytes=%d prime=%d inflate=%s out=%lu match=%d] ", bytes, pr, rname(r), s.total_out, s.total_out == 8000 && memcmp(dst, corpus[2].p, 8000) == 0);
    Z(inflateEnd)(&s);
    free(input);
  }
  free(dst); free(z.p);
}

#define PRIME_CASE(name, w, m) static void name(Api *A, char *out, size_t cap) { deflate_prime_loop(A, out, cap, w, m); }
PRIME_CASE(case_deflate_prime_raw8, -15, 8)
PRIME_CASE(case_deflate_prime_raw1, -15, 1)
PRIME_CASE(case_deflate_prime_raw9bit1, -9, 1)
PRIME_CASE(case_deflate_prime_zlib8, 15, 8)
PRIME_CASE(case_deflate_prime_gzip8, 31, 8)
PRIME_CASE(case_deflate_prime_raw9, -15, 9)

static int back_run(Api *A, const u8 *input, size_t n, size_t chunk, u8 poison, Buf *result) {
  z_stream s;
  memset(&s, 0, sizeof(s));
  u8 window[32768];
  memset(window, poison, sizeof(window));
  Z(inflateBackInit_)(&s, 15, window, ZLIB_VERSION, (int)sizeof(s));
  BackCtx ctx = {input, n, 0, chunk, {0}, 0};
  int r = Z(inflateBack)(&s, back_in, &ctx, back_out, &ctx);
  Z(inflateBackEnd)(&s);
  *result = ctx.out;
  return r;
}

static void back_fuzz(Api *A, char *out, size_t cap, int mutate) {
  Buf z = {0};
  enc(P[0], corpus[2].p, 3000, 6, -15, 8, 0, &z);
  uint64_t seed = 0x9e3779b9ull;
  int counts[4] = {0, 0, 0, 0};
  int window_dependent = 0;
  uint64_t h = FNV0;
  for (int t = 0; t < 600; t++) {
    u8 input[3200];
    size_t n;
    if (!mutate) {
      n = 1 + local_rnd(&seed) % 80;
      for (size_t i = 0; i < n; i++) input[i] = (u8)local_rnd(&seed);
    } else {
      n = z.n < sizeof(input) ? z.n : sizeof(input);
      memcpy(input, z.p, n);
      int edits = 1 + (int)(local_rnd(&seed) % 4);
      for (int e = 0; e < edits; e++) input[local_rnd(&seed) % n] ^= (u8)(1 + local_rnd(&seed) % 255);
    }
    size_t chunk = 1 + local_rnd(&seed) % 300;
    Buf a = {0}, b = {0};
    int ra = back_run(A, input, n, chunk, 0xaa, &a);
    int rb = back_run(A, input, n, chunk, 0x55, &b);
    if (ra != rb || a.n != b.n || (a.n && memcmp(a.p, b.p, a.n) != 0)) window_dependent++;
    h = fnv(a.p ? a.p : (const u8 *)"", a.n, h * 31 + (uint64_t)(ra + 10));
    counts[ra == Z_STREAM_END ? 0 : ra == Z_DATA_ERROR ? 1 : ra == Z_BUF_ERROR ? 2 : 3]++;
    free(a.p); free(b.p);
  }
  ADD("end=%d data=%d buf=%d other=%d window-dependent=%d hash=%016llx", counts[0], counts[1], counts[2], counts[3], window_dependent, (unsigned long long)h);
  free(z.p);
}

static void case_inflate_back_random(Api *A, char *out, size_t cap) { back_fuzz(A, out, cap, 0); }
static void case_inflate_back_mutated(Api *A, char *out, size_t cap) { back_fuzz(A, out, cap, 1); }

static void case_inflate_back_far_distance(Api *A, char *out, size_t cap) {
  enum { DICT = 32768 };
  u8 *dict = xmalloc(DICT);
  for (size_t i = 0; i < DICT; i++) dict[i] = (u8)("0123456789abcdefghijklmnopqrstuvwxyz"[i % 36]);
  z_stream d;
  memset(&d, 0, sizeof(d));
  Z(deflateInit2_)(&d, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, (int)sizeof(d));
  Z(deflateSetDictionary)(&d, dict, DICT);
  u8 raw[4096];
  d.next_in = dict + 100; d.avail_in = 2000; d.next_out = raw; d.avail_out = sizeof(raw);
  Z(deflate)(&d, Z_FINISH);
  size_t rn = sizeof(raw) - d.avail_out;
  Z(deflateEnd)(&d);

  z_stream s;
  memset(&s, 0, sizeof(s));
  u8 window[32768];
  memset(window, 0xaa, sizeof(window));
  Z(inflateBackInit_)(&s, 15, window, ZLIB_VERSION, (int)sizeof(s));
  BackCtx ctx = {raw, rn, 0, rn, {0}, 0};
  int r = Z(inflateBack)(&s, back_in, &ctx, back_out, &ctx);
  size_t poison = 0;
  for (size_t i = 0; i < ctx.out.n; i++) if (ctx.out.p && ctx.out.p[i] == 0xaa) poison++;
  ADD("inflateBack=%s delivered=%zu poison=%zu ", rname(r), ctx.out.n, poison);
  Z(inflateBackEnd)(&s);
  free(ctx.out.p);

  memset(&s, 0, sizeof(s));
  Z(inflateInit2_)(&s, -15, ZLIB_VERSION, (int)sizeof(s));
  u8 dst[4096];
  s.next_in = raw; s.avail_in = (uInt)rn; s.next_out = dst; s.avail_out = sizeof(dst);
  r = Z(inflate)(&s, Z_NO_FLUSH);
  ADD("inflate-no-dict=%s out=%lu ", rname(r), s.total_out);
  Z(inflateEnd)(&s);

  memset(&s, 0, sizeof(s));
  Z(inflateInit2_)(&s, -15, ZLIB_VERSION, (int)sizeof(s));
  r = Z(inflateSetDictionary)(&s, dict, DICT);
  s.next_in = raw; s.avail_in = (uInt)rn; s.next_out = dst; s.avail_out = sizeof(dst);
  int r2 = Z(inflate)(&s, Z_FINISH);
  ADD("set-dict=%s inflate-with-dict=%s match=%d", rname(r), rname(r2), s.total_out == 2000 && memcmp(dst, dict + 100, 2000) == 0);
  Z(inflateEnd)(&s);
  free(dict);
}

static void gz_seek_variant(Api *A, char *out, size_t cap, int v) {
  char path[512];
  snprintf(path, sizeof(path), "%s/fix-seek-%d.gz", g_tmp, (int)getpid());
  gzFile f = Z(gzopen)(path, "wb6");
  long long sk = 0;
  int w = 0, w2 = 0;
  switch (v) {
    case 0: sk = Z(gzseek)(f, 5000, SEEK_CUR); w = Z(gzwrite)(f, "TAIL", 4); break;
    case 1: Z(gzseek)(f, 100, SEEK_CUR); Z(gzseek)(f, 200, SEEK_CUR); sk = Z(gzseek)(f, 300, SEEK_CUR); w = Z(gzwrite)(f, "TAIL", 4); break;
    case 2: w = Z(gzwrite)(f, "HEAD", 4); Z(gzseek)(f, 40000, SEEK_CUR); w2 = Z(gzwrite)(f, "TAIL", 4); sk = Z(gzseek)(f, 30, SEEK_CUR); break;
    case 3: sk = Z(gzseek)(f, 70000, SEEK_SET); break;
    case 4: sk = Z(gzseek)(f, -1, SEEK_CUR); w = Z(gzwrite)(f, "TAIL", 4); break;
    case 5: Z(gzseek)(f, 100000, SEEK_CUR); w = Z(gzwrite)(f, "X", 1); sk = Z(gzseek)(f, 5, SEEK_CUR); w2 = Z(gzwrite)(f, "Y", 1); break;
    case 6: sk = Z(gzseek)(f, 20000, SEEK_CUR); Z(gzflush)(f, Z_SYNC_FLUSH); w = Z(gzwrite)(f, "TAIL", 4); break;
    case 7: sk = Z(gzseek)(f, 300, SEEK_CUR); w = Z(gzputc)(f, 'Z'); w2 = Z(gzputs)(f, "tail"); break;
  }
  int close = Z(gzclose_w)(f);
  Buf o = {0};
  int en = 0, rc = 0;
  gz_read(P[0], path, 0, &o, &en, &rc);
  size_t zeros = 0;
  while (zeros < o.n && o.p[zeros] == 0) zeros++;
  ADD("[v=%d seek=%lld w=%d,%d close=%d -> n=%zu leading-zeros=%zu hash=%016llx err=%d] ", v, sk, w, w2, close, o.n, zeros, (unsigned long long)fnv(o.p ? o.p : (const u8 *)"", o.n, FNV0), en);
  free(o.p);
  unlink(path);
}

static void case_gzseek_write(Api *A, char *out, size_t cap) {
  for (int v = 0; v < 8; v++) gz_seek_variant(A, out, cap, v);
}

static void nonblocking_write(Api *A, char *out, size_t cap, size_t chunk_limit, int flush_mid) {
  enum { TOTAL = 400000 };
  u8 *data = xmalloc(TOTAL);
  uint64_t seed = 0xfeedfaceull;
  for (size_t i = 0; i < TOTAL; i++) data[i] = (u8)local_rnd(&seed);
  int fds[2];
  if (pipe2(fds, O_NONBLOCK) != 0) exit(2);
  gzFile f = Z(gzdopen)(fds[1], "wb");
  Z(gzbuffer)(f, 8192);
  Buf coll = {0};
  size_t ccap = 0, off = 0;
  int stalls = 0, idle = 0, first_en = 0;
  for (int it = 0; it < 4000 && off < TOTAL && idle < 100; it++) {
    size_t len = TOTAL - off;
    if (len > chunk_limit) len = chunk_limit;
    u8 *tmp = xmalloc(len);
    memcpy(tmp, data + off, len);
    int r = Z(gzwrite)(f, tmp, (unsigned)len);
    memset(tmp, 0xee, len);
    free(tmp);
    if (r > 0) { off += (size_t)r; idle = 0; }
    if ((size_t)r != len) {
      int en = 0;
      Z(gzerror)(f, &en);
      if (!stalls) first_en = en;
      stalls++;
      u8 buf[4096];
      ssize_t n, drained = 0;
      while ((n = read(fds[0], buf, sizeof(buf))) > 0) { buf_append(&coll, buf, (size_t)n, &ccap); drained += n; }
      if (r <= 0 && drained == 0) idle++;
    }
    if (flush_mid && it % 3 == 2) Z(gzflush)(f, Z_SYNC_FLUSH);
  }
  u8 buf[4096];
  ssize_t n;
  while ((n = read(fds[0], buf, sizeof(buf))) > 0) buf_append(&coll, buf, (size_t)n, &ccap);
  int close = Z(gzclose_w)(f);
  while ((n = read(fds[0], buf, sizeof(buf))) > 0) buf_append(&coll, buf, (size_t)n, &ccap);
  u8 *back = xmalloc(TOTAL + 64);
  size_t got = 0;
  int r = dec(P[0], coll.p ? coll.p : (const u8 *)"", coll.n, 31, back, TOTAL + 64, &got, NULL);
  ADD("accepted=%zu stalled=%d first-error=%d close=%d decode=%s decoded=%zu match=%d", off, stalls > 0, first_en, close, rname(r), got, got == off && memcmp(back, data, off) == 0);
  free(back); free(coll.p); free(data);
}

static void case_gzwrite_nonblocking_large(Api *A, char *out, size_t cap) { nonblocking_write(A, out, cap, 150000, 0); }
static void case_gzwrite_nonblocking_small(Api *A, char *out, size_t cap) { nonblocking_write(A, out, cap, 3000, 0); }
static void case_gzwrite_nonblocking_flush(Api *A, char *out, size_t cap) { nonblocking_write(A, out, cap, 20000, 1); }

static void case_gzwrite_invalid_lengths(Api *A, char *out, size_t cap) {
  char path[512];
  snprintf(path, sizeof(path), "%s/fix-len-%d.gz", g_tmp, (int)getpid());
  gzFile f = Z(gzopen)(path, "wb");
  u8 small[16] = "0123456789abcde";
  int a = Z(gzwrite)(f, small, 0x80000000u);
  int b = Z(gzwrite)(f, small, 0xffffffffu);
  int c = Z(gzwrite)(f, small, 0);
  size_t d = Z(gzfwrite)(small, (size_t)1 << 63, 3, f);
  size_t e = Z(gzfwrite)(small, 0, 5, f);
  int en = 0;
  Z(gzerror)(f, &en);
  int g = Z(gzwrite)(f, small, 8);
  ADD("huge=%d max=%d zero=%d fwrite-overflow=%zu fwrite-zero=%zu err-after=%d later-write=%d ", a, b, c, d, e, en, g);
  ADD("close=%d ", Z(gzclose_w)(f));
  f = Z(gzopen)(path, "rb");
  u8 buf[32];
  int h = Z(gzread)(f, buf, 0x80000000u);
  Z(gzerror)(f, &en);
  ADD("read-huge=%d err=%d ", h, en);
  ADD("close=%d", Z(gzclose_r)(f));
  unlink(path);
}

static void trailer_variant(Api *A, char *out, size_t cap, int v) {
  char path[512];
  snprintf(path, sizeof(path), "%s/fix-trailer-%d.gz", g_tmp, (int)getpid());
  Buf z = {0};
  enc(P[0], corpus[2].p, 2000, 6, 31, 8, 0, &z);
  u8 *w = xmalloc(z.n + 8);
  size_t n = z.n;
  memcpy(w, z.p, n);
  switch (v) {
    case 0: w[n - 8] ^= 1; break;
    case 1: w[n - 1] ^= 1; break;
    case 2: n -= 4; break;
    case 3: n -= 9; break;
    case 4: memcpy(w + n, "junk!", 5); n += 5; break;
    case 5: memcpy(w + n, "ab", 2); n += 2; break;
    case 6: memcpy(w + n, "\x1f\x8b\x08\x00\x00", 5); n += 5; break;
  }
  write_file(path, w, n);
  free(w);
  for (int style = 0; style < 4; style += (style == 0 ? 2 : 1)) {
    Buf o = {0};
    int en = 0, rc = 0;
    gz_read(A, path, style, &o, &en, &rc);
    ADD("[style=%d n=%zu intact=%d err=%d close=%d] ", style, o.n, o.n <= 2000 && memcmp(o.p, corpus[2].p, o.n) == 0, en, rc);
    free(o.p);
  }
  free(z.p);
  unlink(path);
}

#define TRAILER_CASE(k) static void case_gz_trailer_##k(Api *A, char *out, size_t cap) { trailer_variant(A, out, cap, k); }
TRAILER_CASE(0)
TRAILER_CASE(1)
TRAILER_CASE(2)
TRAILER_CASE(3)
TRAILER_CASE(4)
TRAILER_CASE(5)
TRAILER_CASE(6)

static void case_deflate_set_dictionary_misuse(Api *A, char *out, size_t cap) {
  static const int wraps[] = {15, 31, -15};
  u8 dict[200];
  for (size_t i = 0; i < sizeof(dict); i++) dict[i] = (u8)("dictionary "[i % 11]);
  for (int w = 0; w < 3; w++) {
    z_stream s;
    memset(&s, 0, sizeof(s));
    Z(deflateInit2_)(&s, 6, Z_DEFLATED, wraps[w], 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, (int)sizeof(s));
    int fresh = Z(deflateSetDictionary)(&s, dict, sizeof(dict));
    int again = Z(deflateSetDictionary)(&s, dict, sizeof(dict));
    int null_dict = Z(deflateSetDictionary)(&s, NULL, 10);
    int zero_len = Z(deflateSetDictionary)(&s, dict, 0);
    u8 buf[512];
    s.next_in = dict; s.avail_in = 10; s.next_out = buf; s.avail_out = sizeof(buf);
    Z(deflate)(&s, Z_NO_FLUSH);
    int after_data = Z(deflateSetDictionary)(&s, dict, sizeof(dict));
    Z(deflate)(&s, Z_SYNC_FLUSH);
    int after_flush = Z(deflateSetDictionary)(&s, dict, sizeof(dict));
    Z(deflate)(&s, Z_FINISH);
    int after_finish = Z(deflateSetDictionary)(&s, dict, sizeof(dict));
    ADD("[wbits=%d fresh=%s again=%s null=%s zero=%s after-data=%s after-flush=%s after-finish=%s] ", wraps[w], rname(fresh), rname(again), rname(null_dict), rname(zero_len), rname(after_data), rname(after_flush), rname(after_finish));
    Z(deflateEnd)(&s);
  }
}

static void case_inflate_set_dictionary_null(Api *A, char *out, size_t cap) {
  u8 dict[200] = {0};
  z_stream s;
  memset(&s, 0, sizeof(s));
  Z(inflateInit2_)(&s, -15, ZLIB_VERSION, (int)sizeof(s));
  ADD("null-dict=%s ", rname(Z(inflateSetDictionary)(&s, NULL, 10)));
  ADD("zero-len=%s", rname(Z(inflateSetDictionary)(&s, dict, 0)));
  Z(inflateEnd)(&s);
}

static void case_need_dict_total_in(Api *A, char *out, size_t cap) {
  u8 dict[300];
  for (size_t i = 0; i < sizeof(dict); i++) dict[i] = (u8)("zlib dictionary text "[i % 21]);
  z_stream d;
  memset(&d, 0, sizeof(d));
  Z(deflateInit2_)(&d, 6, Z_DEFLATED, 15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, (int)sizeof(d));
  Z(deflateSetDictionary)(&d, dict, sizeof(dict));
  u8 zbuf[1024];
  d.next_in = dict; d.avail_in = 250; d.next_out = zbuf; d.avail_out = sizeof(zbuf);
  Z(deflate)(&d, Z_FINISH);
  size_t zn = sizeof(zbuf) - d.avail_out;
  Z(deflateEnd)(&d);
  for (int pass = 0; pass < 2; pass++) {
    z_stream s;
    memset(&s, 0, sizeof(s));
    Z(inflateInit2_)(&s, 15, ZLIB_VERSION, (int)sizeof(s));
    u8 dst[512];
    s.next_out = dst; s.avail_out = sizeof(dst);
    size_t fed = 0;
    int r = Z_OK;
    while (r == Z_OK && fed < zn) {
      size_t step = pass ? 1 : zn;
      s.next_in = zbuf + fed - s.avail_in; s.avail_in += (uInt)step;
      fed += step;
      r = Z(inflate)(&s, Z_NO_FLUSH);
    }
    size_t consumed = fed - s.avail_in;
    ADD("[chunk=%s first=%s total_in=%lu consumed=%zu ", pass ? "1" : "all", rname(r), s.total_in, consumed);
    if (r == Z_NEED_DICT) {
      int sd = Z(inflateSetDictionary)(&s, dict, sizeof(dict));
      s.next_in = zbuf + consumed; s.avail_in = (uInt)(zn - consumed);
      do { r = Z(inflate)(&s, Z_NO_FLUSH); } while (r == Z_OK);
      ADD("setdict=%s finish=%s out=%lu final_total_in=%lu match=%d", rname(sd), rname(r), s.total_out, s.total_in, s.total_out == 250 && memcmp(dst, dict, 250) == 0);
    }
    ADD("] ");
    Z(inflateEnd)(&s);
  }
}

static void case_inflate_copy_invalid(Api *A, char *out, size_t cap) {
  z_stream src, dst;
  memset(&src, 0, sizeof(src));
  memset(&dst, 0, sizeof(dst));
  dst.state = (struct internal_state *)(uintptr_t)1;
  int r = Z(inflateCopy)(&dst, &src);
  ADD("invalid-source=%s dest-state-null=%d ", rname(r), dst.state == NULL);
  memset(&src, 0, sizeof(src));
  Z(inflateInit2_)(&src, 15, ZLIB_VERSION, (int)sizeof(src));
  dst.state = (struct internal_state *)(uintptr_t)1;
  r = Z(inflateCopy)(NULL, &src);
  ADD("null-dest=%s ", rname(r));
  Z(inflateEnd)(&src);
}

static void case_reset_keep_mid_stream(Api *A, char *out, size_t cap) {
  static const int levels[] = {1, 4, 6, 9};
  for (int li = 0; li < 4; li++) {
    z_stream s;
    memset(&s, 0, sizeof(s));
    Z(deflateInit2_)(&s, levels[li], Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, (int)sizeof(s));
    u8 sink[2048];
    s.next_in = corpus[2].p; s.avail_in = 60000; s.next_out = sink; s.avail_out = sizeof(sink);
    int first = Z(deflate)(&s, Z_NO_FLUSH);
    int rk = Z(deflateResetKeep)(&s);
    Buf z = {0};
    size_t zcap = 0;
    u8 chunk[1000];
    s.next_in = corpus[5].p; s.avail_in = 40000;
    int r;
    do {
      s.next_out = chunk; s.avail_out = sizeof(chunk);
      r = Z(deflate)(&s, Z_FINISH);
      buf_append(&z, chunk, sizeof(chunk) - s.avail_out, &zcap);
    } while (r == Z_OK);
    u8 *back = xmalloc(40001);
    size_t got = 0;
    int dr = dec(P[0], z.p, z.n, -15, back, 40001, &got, NULL);
    ADD("[level=%d first=%s reset-keep=%s finish=%s decode=%s match=%d] ", levels[li], rname(first), rname(rk), rname(r), rname(dr), got == 40000 && memcmp(back, corpus[5].p, 40000) == 0);
    free(back); free(z.p);
    Z(deflateEnd)(&s);
  }
}

static void case_gzopen_exclusive(Api *A, char *out, size_t cap) {
  char path[512];
  snprintf(path, sizeof(path), "%s/fix-excl-%d.gz", g_tmp, (int)getpid());
  unlink(path);
  gzFile a = Z(gzopen)(path, "wbx");
  int ra = a != NULL;
  if (a) Z(gzclose)(a);
  errno = 0;
  gzFile b = Z(gzopen)(path, "wbx");
  int eb = errno;
  ADD("first-create=%d second-create=%d errno=%d", ra, b != NULL, eb);
  if (b) Z(gzclose)(b);
  unlink(path);
}

static void case_gzseek_read_past_end(Api *A, char *out, size_t cap) {
  char path[512];
  snprintf(path, sizeof(path), "%s/fix-past-%d.gz", g_tmp, (int)getpid());
  int wr, cr;
  gz_write(P[0], path, "wb6", corpus[2].p, 100000, 0, &wr, &cr);
  for (int v = 0; v < 5; v++) {
    gzFile f = Z(gzopen)(path, "rb");
    u8 buf[100];
    long long sk;
    int r = 0;
    switch (v) {
      case 0: sk = Z(gzseek)(f, 500000, SEEK_SET); r = Z(gzread)(f, buf, sizeof(buf)); break;
      case 1: sk = Z(gzseek)(f, 99990, SEEK_SET); r = Z(gzread)(f, buf, sizeof(buf)); break;
      case 2: sk = Z(gzseek)(f, 50000, SEEK_CUR); Z(gzseek)(f, 20000, SEEK_CUR); r = Z(gzread)(f, buf, sizeof(buf)); break;
      case 3: sk = Z(gzseek)(f, 70000, SEEK_SET); r = Z(gzgetc)(f); Z(gzungetc)(r, f); r = Z(gzread)(f, buf, 10) * 1000 + (int)Z(gztell)(f) % 1000; break;
      default: sk = Z(gzseek)(f, 30000, SEEK_SET); r = Z(gzread)(f, buf, 50); sk = sk * 1000 + Z(gzseek)(f, -20, SEEK_CUR); r = r * 1000 + Z(gzread)(f, buf, 40); break;
    }
    int en = 0;
    Z(gzerror)(f, &en);
    long long tell = (long long)Z(gztell)(f);
    int eof = Z(gzeof)(f);
    int closed = Z(gzclose_r)(f);
    ADD("[v=%d seek=%lld read=%d tell=%lld eof=%d err=%d close=%d hash=%016llx] ", v, sk, r, tell, eof, en, closed, (unsigned long long)fnv(buf, sizeof(buf), FNV0));
  }
  unlink(path);
}

static void fixed_paths(void) {
  group_begin("zlib 1.4 fixed paths: invalid windows, sync, priming, dictionaries, gzseek, nonblocking gzwrite");
  run_case("inflateGetDictionary after invalid window size and reset", case_getdict_after_bad_window, NO_KD, "bad-header=Z_DATA_ERROR reset=Z_OK inflate=Z_BUF_ERROR out=99996 getdict=Z_OK len=32768 guard-intact=1 tail-match=1", NULL);
  run_case("inflateGetDictionary with full-size windows", case_getdict_full_window, NO_KD, "[wbits=15 fresh=Z_OK/0", NULL);
  run_case("inflateGetDictionary with 512-byte windows", case_getdict_small_window, KD_GETDICT_SMALL_WINDOW,
    "[wbits=9 fresh=Z_OK/0 half=Z_OK/512/1 end=Z_STREAM_END full=Z_OK/512/guard1/tail0 len-only=Z_OK/512 dict-only=Z_OK none=Z_OK] [wbits=-9 fresh=Z_OK/0 half=Z_OK/512/1 end=Z_STREAM_END full=Z_OK/512/guard1/tail1 len-only=Z_OK/512 dict-only=Z_OK none=Z_OK] ",
    "[wbits=9 fresh=Z_OK/0 half=Z_OK/25004/1 end=Z_STREAM_END full=Z_OK/25004/guard1/tail0 len-only=Z_OK/25004 dict-only=Z_OK none=Z_OK] [wbits=-9 fresh=Z_OK/0 half=Z_OK/25004/1 end=Z_STREAM_END full=Z_OK/32768/guard1/tail1 len-only=Z_OK/32768 dict-only=Z_OK none=Z_OK] ");
  run_case("inflateReset with an auto window across streams", case_window_reuse, KD_RESET_AUTO_WINDOW,
    "small=Z_STREAM_END/3000 reset=Z_OK big=Z_STREAM_END/80000 match=1 msg=none big-first=Z_STREAM_END/80000 reset-keep=Z_OK small-after=Z_STREAM_END/3000",
    "small=Z_STREAM_END/3000 reset=Z_OK big=Z_DATA_ERROR/0 match=0 msg=invalid window size big-first=Z_STREAM_END/80000 reset-keep=Z_OK small-after=Z_STREAM_END/3000");
  run_case("inflateSync after a header error, auto window, full flush", case_sync_auto_window_full, NO_KD, "sync=Z_OK", NULL);
  run_case("inflateSync after a header error, auto window, sync flush", case_sync_auto_window_sync, NO_KD, "sync=Z_OK", NULL);
  run_case("inflateSync after a header error, zlib window", case_sync_zlib_window, NO_KD, "sync=Z_OK", NULL);
  run_case("inflateSync after a header error, raw window", case_sync_raw_window, NO_KD, "first=Z_DATA_ERROR sync=Z_OK", NULL);
  run_case("inflateSync after a header error, gzip auto window", case_sync_gzip_auto, NO_KD, "sync=Z_OK", NULL);
  run_case("repeated inflatePrime", case_inflate_prime, NO_KD, "split-prime=Z_OK,Z_OK inflate=Z_STREAM_END match=1", NULL);
  run_case("inflatePrime with whole bytes before the inflate_fast path", case_inflate_prime_fast_path, NO_KD, "[primed-bytes=1 prime=0 inflate=Z_STREAM_END out=8000 match=1] [primed-bytes=2 prime=0 inflate=Z_STREAM_END out=8000 match=1] [primed-bytes=3 prime=0 inflate=Z_STREAM_END out=8000 match=1] [primed-bytes=4 prime=0 inflate=Z_STREAM_END out=8000 match=1] ", NULL);
  run_case("repeated deflatePrime, raw, memLevel 8", case_deflate_prime_raw8, NO_KD, "first-fail=", NULL);
  run_case("repeated deflatePrime, raw, memLevel 1", case_deflate_prime_raw1, KD_DEFLATE_PRIME, "[wbits=-15 mem=1 first-fail=256/Z_BUF_ERROR pending=512/0 then-deflate=Z_OK] ", " CRASH signal 6");
  run_case("repeated deflatePrime, raw 9-bit window, memLevel 1", case_deflate_prime_raw9bit1, KD_DEFLATE_PRIME, "[wbits=-9 mem=1 first-fail=256/Z_BUF_ERROR pending=512/0 then-deflate=Z_OK] ", " CRASH signal 6");
  run_case("repeated deflatePrime, zlib, memLevel 8", case_deflate_prime_zlib8, NO_KD, "first-fail=", NULL);
  run_case("repeated deflatePrime, gzip, memLevel 8", case_deflate_prime_gzip8, NO_KD, "first-fail=", NULL);
  run_case("repeated deflatePrime, raw, memLevel 9", case_deflate_prime_raw9, NO_KD, "first-fail=", NULL);
  run_case("inflateBack on random garbage", case_inflate_back_random, KD_INFLATE_BACK, "end=2 data=560 buf=38 other=0 window-dependent=0 hash=9dd19bbf7601b27b", "end=2 data=540 buf=58 other=0 window-dependent=23 hash=4525a1151a545c55");
  run_case("inflateBack on mutated valid streams", case_inflate_back_mutated, KD_INFLATE_BACK, "end=142 data=449 buf=9 other=0 window-dependent=0 hash=a1463d1e71c39c69", "end=319 data=265 buf=16 other=0 window-dependent=216 hash=79930244ffc1653d");
  run_case("inflateBack on a stream that needs a dictionary", case_inflate_back_far_distance, NO_KD, "inflateBack=Z_DATA_ERROR", NULL);
  run_case("gzseek as the first write action and repeated gzseek", case_gzseek_write, NO_KD, "[v=0 seek=5000 w=4,0 close=0 -> n=5004 leading-zeros=5000", NULL);
  run_case("gzwrite into a full nonblocking pipe, large writes", case_gzwrite_nonblocking_large, KD_GZWRITE_LARGE, "accepted=400000 stalled=1 first-error=-1 close=0 decode=Z_STREAM_END decoded=400000 match=1", " CRASH signal 11");
  run_case("gzwrite into a full nonblocking pipe, small writes", case_gzwrite_nonblocking_small, KD_GZWRITE_ACCOUNT, "accepted=400000 stalled=1 first-error=-1 close=0 decode=Z_STREAM_END decoded=400000 match=1", "accepted=90000 stalled=1 first-error=-1 close=0 decode=Z_STREAM_END decoded=90112 match=0");
  run_case("gzwrite into a full nonblocking pipe, with flushes", case_gzwrite_nonblocking_flush, KD_GZWRITE_ACCOUNT, "accepted=400000 stalled=1 first-error=-1 close=0 decode=Z_STREAM_END decoded=400000 match=1", "accepted=60000 stalled=1 first-error=-1 close=0 decode=Z_STREAM_END decoded=80000 match=0");
  run_case("gzwrite and gzfwrite length limits", case_gzwrite_invalid_lengths, NO_KD, NULL, NULL);
  run_case("gzread, bad CRC", case_gz_trailer_0, KD_GZ_DELIVER_ALL, "[style=0 n=2000 intact=1 err=-3 close=0] [style=2 n=2000 intact=1 err=-3 close=0] [style=3 n=2000 intact=1 err=-3 close=0] ", "[style=0 n=0 intact=1 err=-3 close=0] [style=2 n=0 intact=1 err=-3 close=0] [style=3 n=0 intact=1 err=-3 close=0] ");
  run_case("gzread, bad length", case_gz_trailer_1, KD_GZ_DELIVER_ALL, "[style=0 n=2000 intact=1 err=-3 close=0] [style=2 n=2000 intact=1 err=-3 close=0] [style=3 n=2000 intact=1 err=-3 close=0] ", "[style=0 n=0 intact=1 err=-3 close=0] [style=2 n=0 intact=1 err=-3 close=0] [style=3 n=0 intact=1 err=-3 close=0] ");
  run_case("gzread, trailer cut to four bytes", case_gz_trailer_2, NO_KD, NULL, NULL);
  run_case("gzread, trailer cut to no bytes", case_gz_trailer_3, NO_KD, NULL, NULL);
  run_case("gzread, five bytes of trailing junk", case_gz_trailer_4, NO_KD, NULL, NULL);
  run_case("gzread, two bytes of trailing junk", case_gz_trailer_5, NO_KD, NULL, NULL);
  run_case("gzread, trailing partial gzip header", case_gz_trailer_6, NO_KD, NULL, NULL);
  run_case("deflateSetDictionary misuse", case_deflate_set_dictionary_misuse, NO_KD, "after-data=Z_STREAM_ERROR", NULL);
  run_case("inflateSetDictionary with a null dictionary", case_inflate_set_dictionary_null, KD_INFLATE_NULL_DICT, "null-dict=Z_STREAM_ERROR zero-len=Z_OK", "null-dict=Z_OK zero-len=Z_OK");
  run_case("total_in when inflate returns Z_NEED_DICT", case_need_dict_total_in, NO_KD, "[chunk=all first=Z_NEED_DICT total_in=6", NULL);
  run_case("inflateCopy with an invalid source", case_inflate_copy_invalid, KD_INFLATE_COPY_STATE, "invalid-source=Z_STREAM_ERROR dest-state-null=1 null-dest=Z_STREAM_ERROR ", "invalid-source=Z_STREAM_ERROR dest-state-null=0 null-dest=Z_STREAM_ERROR ");
  run_case("deflateResetKeep in the middle of a stream", case_reset_keep_mid_stream, KD_RESET_KEEP,
    "[level=1 first=Z_OK reset-keep=Z_OK finish=Z_STREAM_END decode=Z_STREAM_END match=1] [level=4 first=Z_OK reset-keep=Z_OK finish=Z_STREAM_END decode=Z_STREAM_END match=1] [level=6 first=Z_OK reset-keep=Z_OK finish=Z_STREAM_END decode=Z_STREAM_END match=1] [level=9 first=Z_OK reset-keep=Z_OK finish=Z_STREAM_END decode=Z_STREAM_END match=1] ",
    "[level=1 first=Z_OK reset-keep=Z_OK finish=Z_STREAM_END decode=Z_DATA_ERROR match=0] [level=4 first=Z_OK reset-keep=Z_OK finish=Z_STREAM_END decode=Z_DATA_ERROR match=0] [level=6 first=Z_OK reset-keep=Z_OK finish=Z_STREAM_END decode=Z_DATA_ERROR match=0] [level=9 first=Z_OK reset-keep=Z_OK finish=Z_STREAM_END decode=Z_DATA_ERROR match=0] ");
  run_case("gzopen with the x mode on an existing file", case_gzopen_exclusive, NO_KD, NULL, NULL);
  run_case("gzseek and gzread past the end of a gzip file", case_gzseek_read_past_end, NO_KD, NULL, NULL);
  group_end();
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s ORACLE.so CANDIDATE.so [TMPDIR] [group...]\n", argv[0]);
    return 2;
  }
  Api oracle, candidate;
  if (load_api(&oracle, "oracle", argv[1]) != 0 || load_api(&candidate, "candidate", argv[2]) != 0) return 2;
  if (argc > 3) g_tmp = argv[3];
  P[0] = &oracle;
  P[1] = &candidate;
  build_corpus();
  printf("oracle %s, candidate %s\n", oracle.zlibVersion(), candidate.zlibVersion());
  roundtrip_matrix();
  wrapper_matrix();
  oneshot();
  streaming();
  flush_modes();
  params_dictionary();
  gzip_headers();
  inflate_back();
  gzip_files();
  checksums();
  hostile_inputs();
  invalid_arguments();
  inflate_sync();
  fixed_paths();
  allocators();
  bombs();
  int known = 0;
  for (int i = 0; i < KD_COUNT; i++) {
    known += kd_count[i];
    if (kd_count[i]) printf("KNOWN DIVERGENCE (%d samples): %s\n", kd_count[i], kd_text[i]);
  }
  printf("%s: %d groups, %d checks, %d failures in %d groups, %d known divergence samples\n", g_fail ? "DIFFERENTIAL FAILED" : (known ? "DIFFERENTIAL OK WITH KNOWN DIVERGENCES" : "DIFFERENTIAL OK"), g_groups, g_checks, g_fail, g_failed_groups, known);
  return g_fail ? 1 : 0;
}
