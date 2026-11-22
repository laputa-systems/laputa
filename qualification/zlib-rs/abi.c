#include <stddef.h>
#include <stdio.h>
#include "zlib.h"

#define FIELD(type, name) printf(#type "." #name " offset=%zu size=%zu\n", offsetof(type, name), sizeof(((type *)0)->name))
#define CONST(name) printf(#name "=%ld\n", (long)(name))

int main(void) {
  printf("sizeof z_stream=%zu\n", sizeof(z_stream));
  FIELD(z_stream, next_in);
  FIELD(z_stream, avail_in);
  FIELD(z_stream, total_in);
  FIELD(z_stream, next_out);
  FIELD(z_stream, avail_out);
  FIELD(z_stream, total_out);
  FIELD(z_stream, msg);
  FIELD(z_stream, state);
  FIELD(z_stream, zalloc);
  FIELD(z_stream, zfree);
  FIELD(z_stream, opaque);
  FIELD(z_stream, data_type);
  FIELD(z_stream, adler);
  FIELD(z_stream, reserved);
  printf("sizeof gz_header=%zu\n", sizeof(gz_header));
  FIELD(gz_header, text);
  FIELD(gz_header, time);
  FIELD(gz_header, xflags);
  FIELD(gz_header, os);
  FIELD(gz_header, extra);
  FIELD(gz_header, extra_len);
  FIELD(gz_header, extra_max);
  FIELD(gz_header, name);
  FIELD(gz_header, name_max);
  FIELD(gz_header, comment);
  FIELD(gz_header, comm_max);
  FIELD(gz_header, hcrc);
  FIELD(gz_header, done);
  printf("sizeof uInt=%zu uLong=%zu voidpf=%zu z_off_t=%zu z_crc_t=%zu\n", sizeof(uInt), sizeof(uLong), sizeof(voidpf), sizeof(z_off_t), sizeof(z_size_t));
  CONST(Z_NO_FLUSH); CONST(Z_PARTIAL_FLUSH); CONST(Z_SYNC_FLUSH); CONST(Z_FULL_FLUSH); CONST(Z_FINISH); CONST(Z_BLOCK); CONST(Z_TREES);
  CONST(Z_OK); CONST(Z_STREAM_END); CONST(Z_NEED_DICT); CONST(Z_ERRNO); CONST(Z_STREAM_ERROR); CONST(Z_DATA_ERROR); CONST(Z_MEM_ERROR); CONST(Z_BUF_ERROR); CONST(Z_VERSION_ERROR);
  CONST(Z_NO_COMPRESSION); CONST(Z_BEST_SPEED); CONST(Z_BEST_COMPRESSION); CONST(Z_DEFAULT_COMPRESSION);
  CONST(Z_FILTERED); CONST(Z_HUFFMAN_ONLY); CONST(Z_RLE); CONST(Z_FIXED); CONST(Z_DEFAULT_STRATEGY);
  CONST(Z_BINARY); CONST(Z_TEXT); CONST(Z_UNKNOWN); CONST(Z_DEFLATED); CONST(MAX_WBITS); CONST(MAX_MEM_LEVEL);
  return 0;
}
