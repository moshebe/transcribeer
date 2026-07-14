#include "include/ZstdExtractor.h"

#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

// Pull in libarchive from the macOS dyld shared cache.
// The library is always present on macOS 10.9+ and includes zstd support.
// We declare only the symbols we need so we don't require the headers.

// Opaque types
struct archive;
struct archive_entry;

// Return codes
#define ARCHIVE_EOF   1
#define ARCHIVE_OK    0
#define ARCHIVE_WARN -1
#define ARCHIVE_FAILED -2
#define ARCHIVE_FATAL -3

// Entry type flags
#define AE_IFREG  0100000
#define AE_IFLNK  0120000
#define AE_IFDIR  0040000

// Function declarations (resolved at link time from libarchive.2.dylib)
extern struct archive *archive_read_new(void);
extern int archive_read_support_filter_all(struct archive *);
extern int archive_read_support_format_all(struct archive *);
extern int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern int archive_read_data_block(struct archive *, const void **buf, size_t *size, long long *offset);
extern int archive_read_close(struct archive *);
extern int archive_read_free(struct archive *);
extern const char *archive_error_string(struct archive *);

extern struct archive *archive_write_disk_new(void);
extern int archive_write_disk_set_options(struct archive *, int flags);
extern int archive_write_disk_set_standard_lookup(struct archive *);
extern int archive_write_header(struct archive *, struct archive_entry *);
extern int archive_write_data_block(struct archive *, const void *buf, size_t size, long long offset);
extern int archive_write_finish_entry(struct archive *);
extern int archive_write_close(struct archive *);
extern int archive_write_free(struct archive *);

extern const char *archive_entry_pathname(struct archive_entry *);
extern void archive_entry_set_pathname(struct archive_entry *, const char *);

// Write disk flags
#define ARCHIVE_EXTRACT_TIME         (0x0004)
#define ARCHIVE_EXTRACT_PERM         (0x0002)
#define ARCHIVE_EXTRACT_ACL          (0x0020)
#define ARCHIVE_EXTRACT_FFLAGS       (0x0040)
#define ARCHIVE_EXTRACT_SECURE_NODOTDOT (0x0200)
#define ARCHIVE_EXTRACT_SECURE_SYMLINKS (0x0100)

static void copy_error(struct archive *a, char *buf, int bufLen) {
    const char *msg = archive_error_string(a);
    if (msg && buf && bufLen > 0) {
        strncpy(buf, msg, (size_t)(bufLen - 1));
        buf[bufLen - 1] = '\0';
    }
}

int zstd_extract(
    const char *srcPath,
    const char *destDir,
    char *errorBuf,
    int errorBufLen
) {
    if (errorBuf && errorBufLen > 0) errorBuf[0] = '\0';

    // Resolve symlinks so ARCHIVE_EXTRACT_SECURE_SYMLINKS doesn't reject
    // destinations that go through intermediate symlinks (e.g. /var → /private/var on macOS).
    char resolvedDest[4096];
    if (realpath(destDir, resolvedDest) == NULL) {
        // Fall back to the original path if realpath fails.
        strncpy(resolvedDest, destDir, sizeof(resolvedDest) - 1);
        resolvedDest[sizeof(resolvedDest) - 1] = '\0';
    }
    destDir = resolvedDest;

    struct archive *reader = archive_read_new();
    if (!reader) {
        if (errorBuf && errorBufLen > 0)
            strncpy(errorBuf, "archive_read_new() failed", (size_t)(errorBufLen - 1));
        return -1;
    }

    archive_read_support_filter_all(reader);
    archive_read_support_format_all(reader);

    int r = archive_read_open_filename(reader, srcPath, 16384);
    if (r != ARCHIVE_OK) {
        copy_error(reader, errorBuf, errorBufLen);
        archive_read_free(reader);
        return r;
    }

    struct archive *writer = archive_write_disk_new();
    if (!writer) {
        if (errorBuf && errorBufLen > 0)
            strncpy(errorBuf, "archive_write_disk_new() failed", (size_t)(errorBufLen - 1));
        archive_read_free(reader);
        return -1;
    }

    int flags = ARCHIVE_EXTRACT_TIME
              | ARCHIVE_EXTRACT_PERM
              | ARCHIVE_EXTRACT_SECURE_NODOTDOT
              | ARCHIVE_EXTRACT_SECURE_SYMLINKS;
    archive_write_disk_set_options(writer, flags);
    archive_write_disk_set_standard_lookup(writer);

    // Build destination prefix (ensure trailing slash)
    size_t destLen = strlen(destDir);
    char prefix[4096];
    if (destLen + 2 >= sizeof(prefix)) {
        if (errorBuf && errorBufLen > 0)
            strncpy(errorBuf, "destDir path too long", (size_t)(errorBufLen - 1));
        archive_write_free(writer);
        archive_read_free(reader);
        return -1;
    }
    memcpy(prefix, destDir, destLen);
    if (prefix[destLen - 1] != '/') {
        prefix[destLen] = '/';
        prefix[destLen + 1] = '\0';
    } else {
        prefix[destLen] = '\0';
    }
    size_t prefixLen = strlen(prefix);

    struct archive_entry *entry;
    char fullPath[8192];

    while (1) {
        r = archive_read_next_header(reader, &entry);
        if (r == ARCHIVE_EOF) break;
        if (r < ARCHIVE_OK) {
            copy_error(reader, errorBuf, errorBufLen);
            if (r < ARCHIVE_WARN) goto cleanup;
        }

        // Prepend destDir to the entry path
        const char *entryPath = archive_entry_pathname(entry);
        if (!entryPath) continue;

        size_t entryLen = strlen(entryPath);
        if (prefixLen + entryLen + 1 >= sizeof(fullPath)) continue; // skip excessively long paths

        memcpy(fullPath, prefix, prefixLen);
        memcpy(fullPath + prefixLen, entryPath, entryLen + 1);
        archive_entry_set_pathname(entry, fullPath);

        r = archive_write_header(writer, entry);
        if (r < ARCHIVE_OK) {
            copy_error(writer, errorBuf, errorBufLen);
            if (r < ARCHIVE_WARN) goto cleanup;
        }

        // Copy data blocks
        const void *buf;
        size_t size;
        long long offset;
        while (1) {
            r = archive_read_data_block(reader, &buf, &size, &offset);
            if (r == ARCHIVE_EOF) { r = ARCHIVE_OK; break; }
            if (r < ARCHIVE_OK) {
                copy_error(reader, errorBuf, errorBufLen);
                goto cleanup;
            }
            r = archive_write_data_block(writer, buf, size, offset);
            if (r < ARCHIVE_OK) {
                copy_error(writer, errorBuf, errorBufLen);
                goto cleanup;
            }
        }

        r = archive_write_finish_entry(writer);
        if (r < ARCHIVE_OK) {
            copy_error(writer, errorBuf, errorBufLen);
            if (r < ARCHIVE_WARN) goto cleanup;
        }
        r = ARCHIVE_OK;
    }

cleanup:
    archive_write_close(writer);
    archive_write_free(writer);
    archive_read_close(reader);
    archive_read_free(reader);

    return (r == ARCHIVE_EOF || r == ARCHIVE_OK) ? 0 : r;
}
