/* jupynvim.h: the C ABI of libjupynvim, the in-process library.
 *
 * Versioning: jnv_abi_version() returns (major << 16) | minor. A loader
 * accepts a library whose major equals its own and whose minor is at least
 * the one it needs. Adding a function, a job kind, a status or a flag bumps
 * the minor; changing or removing anything declared here bumps the major.
 * The library's version (jnv_version) also equals the plugin's.
 *
 * Memory: every jnv_buf the library returns belongs to the caller until it
 * calls jnv_buf_free. Input given to jnv_call is read during the call only.
 * Input given to jnv_submit without JNV_FLAG_COPY is read in place by a
 * worker: the caller keeps it alive and unchanged until jnv_poll has
 * returned that job's jnv_done, or for the rest of the process after
 * jnv_close.
 *
 * Threads: call every function from one thread. Submitted jobs run on the
 * library's worker threads; a finished batch writes one byte to the wake fd
 * and jnv_poll collects the results. The library never writes to stdout or
 * stderr and never unwinds into the caller: a panic becomes JNV_PANIC with
 * its message as the result.
 *
 * Job kinds by range: 0x0001-0x00ff diagnostics (below); later features
 * take 0x0100 painter, 0x0200 markdown, 0x0300 tables, 0x0400 widgets,
 * 0x0500 images, 0x0600 output text, 0x0700 RPC framing.
 */
#ifndef JUPYNVIM_H
#define JUPYNVIM_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* JNV-CDEF-BEGIN */
typedef struct jnv_ctx jnv_ctx;
typedef struct jnv_buf { const uint8_t *ptr; size_t len; } jnv_buf;
typedef struct jnv_done { uint64_t job; uint32_t kind; int32_t status; jnv_buf *result; } jnv_done;
enum {
  JNV_OK = 0, JNV_ERR = 1, JNV_PANIC = 2, JNV_CANCELLED = 3,
  JNV_EINVAL = 4, JNV_EKIND = 5, JNV_ESHUTDOWN = 6, JNV_ENOJOB = 7
};
enum { JNV_PRIO_VISIBLE = 0, JNV_PRIO_NORMAL = 1, JNV_PRIO_BACKGROUND = 2, JNV_FLAG_COPY = 256 };
enum {
  JNV_KIND_NOP = 1, JNV_KIND_ECHO = 2, JNV_KIND_BYTESUM = 3, JNV_KIND_PTR = 4,
  JNV_KIND_SLEEP = 5, JNV_KIND_PANIC = 6, JNV_KIND_FILL = 7
};
enum { JNV_SIZEOF_BUF = 1, JNV_SIZEOF_DONE = 2 };
uint32_t jnv_abi_version(void);
const char *jnv_version(void);
size_t jnv_sizeof(uint32_t which);
int32_t jnv_kind_supported(uint32_t kind);
uint64_t jnv_live_buffers(void);
void jnv_buf_free(jnv_buf *buf);
jnv_ctx *jnv_open(uint32_t workers, jnv_buf **err);
int32_t jnv_wake_fd(jnv_ctx *ctx);
uint32_t jnv_workers(const jnv_ctx *ctx);
void jnv_close(jnv_ctx *ctx);
int32_t jnv_call(jnv_ctx *ctx, uint32_t kind, const char *data, size_t len, jnv_buf **out);
int32_t jnv_submit(jnv_ctx *ctx, uint32_t kind, uint32_t flags, const char *data, size_t len, uint64_t *job);
int32_t jnv_cancel(jnv_ctx *ctx, uint64_t job);
size_t jnv_poll(jnv_ctx *ctx, jnv_done *out, size_t cap);
/* JNV-CDEF-END */
#ifdef __cplusplus
}
#endif
#endif
