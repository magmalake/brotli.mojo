/*
 * brotli.mojo — minimal libbrotli wrapper for Mojo FFI.
 *
 * Mirrors zstd.mojo's and lz4.mojo's shims: one C call per operation, so Mojo
 * never has to read back internal library state after a foreign call. Pointer
 * arguments are void* (passed from Mojo as an address-sized Int); lengths and
 * return values are `long long` rather than the `int` lz4.mojo uses, because a
 * Brotli Parquet column chunk can legitimately exceed 2 GiB (the one Brotli
 * file in apache/parquet-testing does). The caller pre-allocates the output
 * buffer; the return is bytes-written (>=0) or a negative sentinel.
 *
 * Why the decoder is driven through BrotliDecoderDecompressStream and not the
 * one-shot BrotliDecoderDecompress: the one-shot collapses every non-success
 * result to BROTLI_DECODER_RESULT_ERROR, so "your output buffer was too small"
 * becomes indistinguishable from "this stream is corrupt". Brotli records no
 * uncompressed size anywhere in the stream, so a caller that does not have the
 * size out of band (a Parquet page header does; a bare .br file does not) has
 * to guess a capacity and grow — and that loop needs the distinction. Running
 * the streaming decoder for exactly one pass gives the same one-call shape and
 * keeps NEEDS_MORE_OUTPUT and NEEDS_MORE_INPUT apart.
 *
 * Build: shim/CMakeLists.txt -> $CONDA_PREFIX/lib/libbrotlimojo.{dylib,so}
 */

#include <brotli/decode.h>
#include <brotli/encode.h>

#define BRM_ERR_GENERIC   (-1)
#define BRM_ERR_TOO_SMALL (-2)
#define BRM_ERR_TRUNCATED (-3)

/* ------------------------------------------------------------------ */
/* Encoder                                                            */
/* ------------------------------------------------------------------ */

/* Upper bound on the compressed size of `in_len` bytes. Brotli returns 0 for
 * an input so large the bound would overflow; normalize that to an error. */
long long brm_max_compressed_size(long long in_len) {
    size_t bound = BrotliEncoderMaxCompressedSize((size_t)in_len);
    if (bound == 0) return BRM_ERR_GENERIC;
    return (long long)bound;
}

/* quality 0..11 (11 = BROTLI_DEFAULT_QUALITY), lgwin 10..24 window bits
 * (22 = BROTLI_DEFAULT_WINDOW), mode 0 generic / 1 text / 2 font.
 * Returns bytes written, or BRM_ERR_TOO_SMALL — BrotliEncoderCompress reports
 * a single BROTLI_FALSE for every failure, and with a buffer sized by
 * brm_max_compressed_size the only reachable one is a short destination. */
long long brm_compress(const void *in_buf, long long in_len,
                       void *out_buf, long long out_cap,
                       int quality, int lgwin, int mode) {
    size_t encoded_size = (size_t)out_cap;
    BROTLI_BOOL ok = BrotliEncoderCompress(
        quality, lgwin, (BrotliEncoderMode)mode,
        (size_t)in_len, (const uint8_t *)in_buf,
        &encoded_size, (uint8_t *)out_buf
    );
    if (!ok) return BRM_ERR_TOO_SMALL;
    return (long long)encoded_size;
}

/* ------------------------------------------------------------------ */
/* Decoder                                                            */
/* ------------------------------------------------------------------ */

/*
 * Decompresses one Brotli stream in a single pass into a caller-sized buffer.
 *
 * `err_out` (may be NULL) receives BrotliDecoderGetErrorCode so the Mojo side
 * can turn a failure into libbrotli's own message via brm_error_string.
 *
 * Returns bytes written (>=0), BRM_ERR_TOO_SMALL when `out_cap` ran out
 * before the stream finished (grow and retry from the start — Brotli has no
 * resumable one-shot), BRM_ERR_TRUNCATED when the input ended mid-stream, or
 * BRM_ERR_GENERIC for corrupt input. Trailing bytes after a complete stream
 * are ignored, matching what Parquet readers do with page padding.
 */
long long brm_decompress(const void *in_buf, long long in_len,
                         void *out_buf, long long out_cap,
                         int *err_out) {
    /* Brotli never dereferences a zero-length buffer, but a NULL next_out is
     * still a pointer it advances, so hand it somewhere real either way. */
    uint8_t scratch = 0;
    BrotliDecoderState *state;
    const uint8_t *next_in;
    uint8_t *next_out;
    size_t available_in, available_out, total_out;
    BrotliDecoderResult result;

    if (err_out) *err_out = 0;

    state = BrotliDecoderCreateInstance(NULL, NULL, NULL);
    if (state == NULL) return BRM_ERR_GENERIC;

    available_in = (size_t)in_len;
    next_in = (in_len > 0) ? (const uint8_t *)in_buf : &scratch;
    available_out = (size_t)out_cap;
    next_out = (out_cap > 0) ? (uint8_t *)out_buf : &scratch;
    total_out = 0;

    result = BrotliDecoderDecompressStream(
        state, &available_in, &next_in, &available_out, &next_out, &total_out
    );
    if (err_out) *err_out = (int)BrotliDecoderGetErrorCode(state);
    BrotliDecoderDestroyInstance(state);

    switch (result) {
        case BROTLI_DECODER_RESULT_SUCCESS:
            return (long long)total_out;
        case BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT:
            return BRM_ERR_TOO_SMALL;
        case BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT:
            return BRM_ERR_TRUNCATED;
        default:
            return BRM_ERR_GENERIC;
    }
}

/* libbrotli's own static message for a BrotliDecoderErrorCode. Never NULL for
 * a code the library produced; the lifetime is the library's, not a call's. */
const char *brm_error_string(int code) {
    return BrotliDecoderErrorString((BrotliDecoderErrorCode)code);
}

/* ------------------------------------------------------------------ */
/* Versions — encoder and decoder are separate shared libraries and can  */
/* in principle differ, so both are exposed.                            */
/* ------------------------------------------------------------------ */

long long brm_encoder_version(void) {
    return (long long)BrotliEncoderVersion();
}

long long brm_decoder_version(void) {
    return (long long)BrotliDecoderVersion();
}
