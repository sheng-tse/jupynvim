/* abi_check: load libjupynvim the way LuaJIT's FFI does (dlopen, dlsym)
 * and check its C ABI against include/jupynvim.h.
 *
 *   cc -std=gnu99 -Wall -Wextra -Werror -I core/native/include \
 *      tests/native/abi_check.c -o abi_check        (add -ldl on Linux)
 *   abi_check LIB [VERSION]
 *
 * Every export is type-checked against the header's prototype at compile
 * time, so a header that drifts from this program fails to build. At run
 * time it checks the ABI major, the version (when given), the struct sizes,
 * a call on the calling thread, a caught panic, a worker round trip through
 * the wake fd, that jnv_close ends the wake fd and frees the descriptors a
 * context holds, every NULL-handle answer, that no buffer is left, and that
 * the library stays mapped after dlclose (it must never be unloaded while
 * its worker threads may run). Prints "ok <check>" or "FAIL <check>" per
 * check, then "ALL ABI CHECKS PASSED" (exit 0) or "<n> ABI CHECKS FAILED"
 * (exit 1). C99 plus POSIX and RTLD_NOLOAD (an extension every target's
 * libc has; on Linux it needs _GNU_SOURCE, defined below).
 */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "jupynvim.h"

static uint32_t (*p_abi_version)(void);
static const char *(*p_version)(void);
static size_t (*p_sizeof)(uint32_t which);
static int32_t (*p_kind_supported)(uint32_t kind);
static uint64_t (*p_live_buffers)(void);
static void (*p_buf_free)(jnv_buf *buf);
static jnv_ctx *(*p_open)(uint32_t workers, jnv_buf **err);
static int32_t (*p_wake_fd)(jnv_ctx *ctx);
static uint32_t (*p_workers)(const jnv_ctx *ctx);
static void (*p_close)(jnv_ctx *ctx);
static int32_t (*p_call)(jnv_ctx *ctx, uint32_t kind, const char *data, size_t len, jnv_buf **out);
static int32_t (*p_submit)(jnv_ctx *ctx, uint32_t kind, uint32_t flags, const char *data, size_t len,
                           uint64_t *job);
static int32_t (*p_cancel)(jnv_ctx *ctx, uint64_t job);
static size_t (*p_poll)(jnv_ctx *ctx, jnv_done *out, size_t cap);

/* Each pointer above has exactly the type of the header's prototype: the
 * assignments only type-check (sizeof never evaluates its operand, so no
 * symbol is referenced) and an incompatible type is an error under -Werror.
 * clang notes that an unevaluated assignment has no effect, which is the
 * point here, so that one note is off for this function only. */
#ifdef __clang__
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunevaluated-expression"
#endif
static void typecheck(void) {
    (void)sizeof(p_abi_version = jnv_abi_version);
    (void)sizeof(p_version = jnv_version);
    (void)sizeof(p_sizeof = jnv_sizeof);
    (void)sizeof(p_kind_supported = jnv_kind_supported);
    (void)sizeof(p_live_buffers = jnv_live_buffers);
    (void)sizeof(p_buf_free = jnv_buf_free);
    (void)sizeof(p_open = jnv_open);
    (void)sizeof(p_wake_fd = jnv_wake_fd);
    (void)sizeof(p_workers = jnv_workers);
    (void)sizeof(p_close = jnv_close);
    (void)sizeof(p_call = jnv_call);
    (void)sizeof(p_submit = jnv_submit);
    (void)sizeof(p_cancel = jnv_cancel);
    (void)sizeof(p_poll = jnv_poll);
}
#ifdef __clang__
#pragma clang diagnostic pop
#endif

static int failures = 0;

static void check(int cond, const char *what) {
    if (cond) {
        printf("ok %s\n", what);
    } else {
        printf("FAIL %s\n", what);
        failures++;
    }
}

/* dlsym into a function pointer without a cast between object and function
 * pointers (POSIX guarantees they have the same representation). */
#define LOAD(var, name)                                                   \
    do {                                                                  \
        void *sym_ = dlsym(lib, name);                                    \
        check(sym_ != NULL, "dlsym " name);                               \
        if (sym_ != NULL) memcpy(&(var), &sym_, sizeof(var));             \
        else missing++;                                                   \
    } while (0)

/* The buffer holds exactly the len bytes of s. */
static int buf_is(const jnv_buf *b, const char *s, size_t len) {
    return b != NULL && b->ptr != NULL && b->len == len && memcmp(b->ptr, s, len) == 0;
}

/* The buffer's bytes contain the NUL-terminated needle. */
static int buf_contains(const jnv_buf *b, const char *needle) {
    size_t n = strlen(needle);
    if (b == NULL || b->ptr == NULL || b->len < n) return 0;
    for (size_t i = 0; i + n <= b->len; i++) {
        if (memcmp(b->ptr + i, needle, n) == 0) return 1;
    }
    return 0;
}

/* Open descriptors of this process, counted over 0 to 4095 (a new
 * descriptor takes the lowest free number). */
static int open_fds(void) {
    int n = 0;
    for (int fd = 0; fd < 4096; fd++) {
        if (fcntl(fd, F_GETFD) != -1) n++;
    }
    return n;
}

/* Read fd until end of file: 1 when it came, 0 when ms passed with nothing
 * to read. Wake bytes still in the socket are read and skipped on the way. */
static int reads_eof_within(int fd, int ms) {
    char buf[64];
    for (int i = 0; i < 64; i++) {
        struct pollfd pfd = {fd, POLLIN, 0};
        int ready = poll(&pfd, 1, ms);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) return 0;
        ssize_t n = read(fd, buf, sizeof buf);
        if (n == 0) return 1;
        if (n < 0 && errno != EINTR) return 0;
    }
    return 0;
}

static int finish(void) {
    if (failures == 0) {
        printf("ALL ABI CHECKS PASSED\n");
        return 0;
    }
    printf("%d ABI CHECKS FAILED\n", failures);
    return 1;
}

int main(int argc, char **argv) {
    typecheck();
    if (argc < 2 || argc > 3) {
        fprintf(stderr, "usage: %s LIB [VERSION]\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];
    const char *want_version = argc == 3 ? argv[2] : NULL;
    char what[256];

    void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (lib == NULL) {
        printf("FAIL dlopen %s: %s\n", path, dlerror());
        failures++;
        return finish();
    }
    printf("ok dlopen %s\n", path);

    int missing = 0;
    LOAD(p_abi_version, "jnv_abi_version");
    LOAD(p_version, "jnv_version");
    LOAD(p_sizeof, "jnv_sizeof");
    LOAD(p_kind_supported, "jnv_kind_supported");
    LOAD(p_live_buffers, "jnv_live_buffers");
    LOAD(p_buf_free, "jnv_buf_free");
    LOAD(p_open, "jnv_open");
    LOAD(p_wake_fd, "jnv_wake_fd");
    LOAD(p_workers, "jnv_workers");
    LOAD(p_close, "jnv_close");
    LOAD(p_call, "jnv_call");
    LOAD(p_submit, "jnv_submit");
    LOAD(p_cancel, "jnv_cancel");
    LOAD(p_poll, "jnv_poll");
    if (missing > 0) return finish();

    uint32_t abi = p_abi_version();
    snprintf(what, sizeof what, "ABI major 1 (library 0x%08x)", (unsigned)abi);
    check(abi >> 16 == 1, what);

    const char *version = p_version();
    if (want_version != NULL) {
        snprintf(what, sizeof what, "version %s (library %s)", want_version, version ? version : "(null)");
        check(version != NULL && strcmp(version, want_version) == 0, what);
    } else {
        check(version != NULL && version[0] != '\0', "version is a non-empty string");
    }

    snprintf(what, sizeof what, "jnv_sizeof(JNV_SIZEOF_BUF) == sizeof(jnv_buf) == %zu (library %zu)",
             sizeof(jnv_buf), p_sizeof(JNV_SIZEOF_BUF));
    check(p_sizeof(JNV_SIZEOF_BUF) == sizeof(jnv_buf), what);
    snprintf(what, sizeof what, "jnv_sizeof(JNV_SIZEOF_DONE) == sizeof(jnv_done) == %zu (library %zu)",
             sizeof(jnv_done), p_sizeof(JNV_SIZEOF_DONE));
    check(p_sizeof(JNV_SIZEOF_DONE) == sizeof(jnv_done), what);

    check(p_kind_supported(JNV_KIND_ECHO) == 1, "jnv_kind_supported(ECHO) == 1");
    check(p_kind_supported(0) == 0, "jnv_kind_supported(0) == 0");

    jnv_buf *err = NULL;
    jnv_ctx *ctx = p_open(1, &err);
    if (ctx == NULL) {
        if (err != NULL) {
            printf("FAIL jnv_open(1): %.*s\n", (int)err->len, (const char *)err->ptr);
            p_buf_free(err);
        } else {
            printf("FAIL jnv_open(1) returned NULL without a message\n");
        }
        failures++;
    } else {
        check(err == NULL, "jnv_open(1) leaves *err NULL");
        check(p_workers(ctx) == 1, "jnv_workers == 1");

        jnv_buf *out = NULL;
        int32_t st = p_call(ctx, JNV_KIND_ECHO, "abc", 3, &out);
        check(st == JNV_OK && buf_is(out, "abc", 3), "jnv_call ECHO \"abc\"");
        p_buf_free(out);

        out = NULL;
        st = p_call(ctx, JNV_KIND_PANIC, "boom", 4, &out);
        snprintf(what, sizeof what, "jnv_call PANIC caught (status %d, message %.*s)", (int)st,
                 out ? (int)(out->len > 120 ? 120 : out->len) : 0, out ? (const char *)out->ptr : "");
        check(st == JNV_PANIC && buf_contains(out, "boom"), what);
        p_buf_free(out);

        int32_t fd = p_wake_fd(ctx);
        check(fd >= 0, "jnv_wake_fd returns the read end");
        check(p_wake_fd(ctx) == -1, "jnv_wake_fd a second time is -1");
        uint64_t job = 0;
        st = p_submit(ctx, JNV_KIND_ECHO, JNV_PRIO_NORMAL, "xyz", 3, &job);
        check(st == JNV_OK && job >= 1, "jnv_submit ECHO \"xyz\"");
        if (fd >= 0 && st == JNV_OK) {
            struct pollfd pfd = {fd, POLLIN, 0};
            int ready = poll(&pfd, 1, 2000);
            check(ready > 0, "the wake fd becomes readable within 2 s");
            char byte;
            check(ready > 0 && read(fd, &byte, 1) == 1, "one wake byte read");
            jnv_done done[4];
            memset(done, 0, sizeof done);
            size_t n = ready > 0 ? p_poll(ctx, done, 4) : 0;
            check(n == 1 && done[0].job == job && done[0].kind == JNV_KIND_ECHO && done[0].status == JNV_OK &&
                      buf_is(done[0].result, "xyz", 3),
                  "jnv_poll returns the job with \"xyz\"");
            for (size_t i = 0; i < n && i < 4; i++) p_buf_free(done[i].result);
        }
        /* jnv_close closes the wake socket's write end: the read end the
         * caller took reaches end of file. */
        p_close(ctx);
        if (fd >= 0) {
            check(reads_eof_within(fd, 1000), "the wake fd reads end of file after jnv_close");
            close(fd);
        }

        /* A context whose wake fd was never taken holds descriptors until
         * jnv_close frees it with them. */
        int before = open_fds();
        jnv_ctx *idle = p_open(1, NULL);
        int held = open_fds();
        if (idle != NULL) p_close(idle);
        int after = open_fds();
        snprintf(what, sizeof what,
                 "jnv_close frees the context's descriptors (%d before jnv_open, %d open, %d after jnv_close)",
                 before, held, after);
        check(idle != NULL && held > before && after == before, what);
    }
    snprintf(what, sizeof what, "jnv_live_buffers() == 0 (library %llu)", (unsigned long long)p_live_buffers());
    check(p_live_buffers() == 0, what);

    /* Every export that takes a context, given NULL. */
    check(p_wake_fd(NULL) == -1, "jnv_wake_fd(NULL) == -1");
    check(p_workers(NULL) == 0, "jnv_workers(NULL) == 0");
    p_close(NULL);
    check(1, "jnv_close(NULL) returns");
    jnv_buf *nout = NULL;
    check(p_call(NULL, JNV_KIND_ECHO, "a", 1, &nout) == JNV_EINVAL && nout == NULL, "jnv_call(NULL) == JNV_EINVAL");
    uint64_t njob = 0;
    check(p_submit(NULL, JNV_KIND_ECHO, JNV_PRIO_NORMAL, "a", 1, &njob) == JNV_EINVAL,
          "jnv_submit(NULL) == JNV_EINVAL");
    check(p_cancel(NULL, 1) == JNV_EINVAL, "jnv_cancel(NULL) == JNV_EINVAL");
    jnv_done nd[1];
    check(p_poll(NULL, nd, 1) == 0, "jnv_poll(NULL) == 0");

    /* The library is never unloaded: still mapped after dlclose. */
    dlclose(lib);
    void *again = dlopen(path, RTLD_NOW | RTLD_NOLOAD);
    check(again != NULL, "still mapped after dlclose");
    return finish();
}
