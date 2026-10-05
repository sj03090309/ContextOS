#ifndef CONTEXTOS_WINDOWS_NATIVE_H
#define CONTEXTOS_WINDOWS_NATIVE_H
#include <stddef.h>
#include <stdint.h>

/* Developer-stage primitives. Their presence does not enable the runtime. */
#define COSW_OK 0
#define COSW_UNAVAILABLE 1
#define COSW_INVALID_PATH 2
#define COSW_UNSAFE_OBJECT 3
#define COSW_IO_ERROR 4
#define COSW_TOO_LARGE 5
#define COSW_PRIVATE_ACL_REQUIRED 6
#define COSW_LOCKED 7
#define COSW_ALREADY_EXISTS 8

typedef struct COSWRoot COSWRoot;
typedef struct COSWLock COSWLock;

int32_t cosw_available(void);
int32_t cosw_root_open(const char *absolute_utf8, COSWRoot **result);
void cosw_root_close(COSWRoot *root);
int32_t cosw_root_read(COSWRoot *root, const char *relative_utf8,
                       size_t byte_limit, void **bytes, size_t *count);
void cosw_buffer_free(void *bytes);
int32_t cosw_private_directory_create(COSWRoot *parent, const char *name_utf8,
                                      COSWRoot **result);
int32_t cosw_private_write_new(COSWRoot *root, const char *name_utf8,
                               const void *bytes, size_t count);
int32_t cosw_lock_acquire(COSWRoot *root, const char *name_utf8, COSWLock **result);
void cosw_lock_release(COSWLock *lock);
int32_t cosw_sha256(const void *bytes, size_t count, uint8_t digest[32]);
#endif
