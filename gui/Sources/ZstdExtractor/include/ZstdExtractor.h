#ifndef ZSTD_EXTRACTOR_H
#define ZSTD_EXTRACTOR_H

/// Extract a .tar.zst (or any libarchive-supported archive) at \p srcPath into \p destDir.
///
/// Returns 0 on success. On failure, returns a non-zero libarchive error code and writes
/// a NUL-terminated description into \p errorBuf (up to \p errorBufLen bytes).
///
/// Both paths must be absolute UTF-8 strings. \p destDir must already exist.
int zstd_extract(
    const char *srcPath,
    const char *destDir,
    char *errorBuf,
    int errorBufLen
);

#endif /* ZSTD_EXTRACTOR_H */
