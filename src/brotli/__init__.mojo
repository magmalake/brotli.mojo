"""`brotli` — Mojo bindings to libbrotlienc/libbrotlidec (RFC 7932) via a thin
C shim (libbrotlimojo.{dylib,so}), loaded through an `OwnedDLHandle`.

Brotli is a Parquet page codec (`CompressionCodec.BROTLI`) and the last one
magmalake could not read. A Brotli stream records **no uncompressed size**
anywhere — not in a header, not in a trailer — which shapes this API:

- `decompress(data, uncompressed_size)` is the Parquet path. A page header
  carries `uncompressed_page_size`, so the output buffer can be sized exactly
  and the stream decoded in a single pass.
- `decompress_unsized(data)` is for everything else (a bare `.br` file, a blob
  from somewhere that did not record a length). It guesses a capacity and
  doubles it until the stream fits, re-decoding from the start each time —
  Brotli's one-shot decoder cannot resume, so a short buffer costs a full
  retry. Use the sized form whenever the size is known.

Mirrors zstd.mojo's and lz4.mojo's FFI pattern: a single-call C wrapper
(shim/brotli_wrapper.c, built to $CONDA_PREFIX/lib/libbrotlimojo.{dylib,so} by
the brotli-shim pixi package) so Mojo never reads back internal library state
after a foreign call. The handle is opened **once per process** and never
closed (`_LIB` below) — a `dlopen`/`dlclose` cycle costs hundreds of
microseconds, far more than decompressing a Parquet page, so opening one per
call made the binding's fixed cost dwarf the work it wrapped. It is passed as
an `imm` borrow to each worker function, so Mojo's ASAP destruction cannot
`dlclose` the library between `get_function` and the call it returned.
"""

from std.os import abort, getenv
from std.ffi import _Global, OwnedDLHandle, c_int, c_long_long


comptime MODE_GENERIC = 0
"""No assumption about the input (`BROTLI_MODE_GENERIC`). The Parquet default."""
comptime MODE_TEXT = 1
"""UTF-8 text (`BROTLI_MODE_TEXT`)."""
comptime MODE_FONT = 2
"""WOFF 2.0 font data (`BROTLI_MODE_FONT`)."""

comptime MIN_QUALITY = 0
comptime MAX_QUALITY = 11
comptime DEFAULT_QUALITY = 11
"""`BROTLI_DEFAULT_QUALITY`. Slow and small; 4–5 is the usual Parquet trade."""
comptime MIN_WINDOW_BITS = 10
comptime MAX_WINDOW_BITS = 24
comptime DEFAULT_WINDOW_BITS = 22
"""`BROTLI_DEFAULT_WINDOW` — a 4 MiB sliding window."""

comptime _ERR_GENERIC = -1
comptime _ERR_TOO_SMALL = -2
comptime _ERR_TRUNCATED = -3


def _open_lib() raises -> OwnedDLHandle:
    """Open libbrotlimojo from `$CONDA_PREFIX/lib` (installed by the
    brotli-shim pixi package), else `build/` for a bare checkout. CMake names
    the shim with the platform's natural shared-library extension, so this
    tries `.dylib` then `.so`."""
    var prefix = getenv("CONDA_PREFIX", "")
    var base = String("")
    if prefix == "":
        base += "build/libbrotlimojo"
    else:
        base += prefix
        base += "/lib/libbrotlimojo"

    try:
        return OwnedDLHandle(base + ".dylib")
    except:
        pass
    try:
        return OwnedDLHandle(base + ".so")
    except:
        pass
    raise Error(
        "brotli.mojo: could not load libbrotlimojo (.dylib/.so) from " + base
    )


def _open_lib_or_abort() -> OwnedDLHandle:
    try:
        return _open_lib()
    except e:
        abort(String(e))


comptime _LIB = _Global["brotli_mojo_shim", _open_lib_or_abort]
"""The shim handle, opened on first use and never closed.

`dlopen`/`dlclose` is not free — on macOS a full open/close cycle of an
already-resident library measures around 450 microseconds, orders of magnitude
more than decompressing a Parquet page. One process-wide handle removes that
fixed cost; `dlsym` on the cached handle costs ~400 ns. `_Global` initialises
exactly once even under concurrent first use, so the handle is safe to reach
from worker threads.
"""


def _lib() raises -> ref[MutUntrackedOrigin] OwnedDLHandle:
    """The cached handle, borrowed. Never destroy the referent."""
    return _LIB.get_or_create_ptr()[]


def _ptr_of(data: Span[UInt8, _]) -> Int:
    """Address of `data`'s backing storage, or 0 for an empty span (the C side
    never dereferences the pointer when the length is 0)."""
    if len(data) == 0:
        return 0
    return Int(data.unsafe_ptr())


def _error_string(imm lib: OwnedDLHandle, code: Int) raises -> String:
    """libbrotli's own message for a `BrotliDecoderErrorCode`.

    The string is one of libbrotli's static literals, so its lifetime outlives
    this call regardless of `lib`."""
    var name_fn = lib.get_function[Int]("brm_error_string")
    var addr = name_fn(c_int(code))
    if addr == 0:
        return String("<unknown brotli error>")
    var p = Pointer[UInt8, ImmUntrackedOrigin](unsafe_from_address=addr)
    return String(unsafe_from_utf8_ptr=p)


# ===----------------------------------------------------------------------===#
# Compression
# ===----------------------------------------------------------------------===#


def _do_compress(
    imm lib: OwnedDLHandle,
    data: Span[UInt8, _],
    quality: Int,
    lgwin: Int,
    mode: Int,
) raises -> List[UInt8]:
    var bound_fn = lib.get_function[c_long_long]("brm_max_compressed_size")
    var compress_fn = lib.get_function[c_long_long]("brm_compress")

    var in_len = len(data)
    var cap = Int(bound_fn(c_long_long(in_len)))
    if cap <= 0:
        raise Error(
            "brotli.compress: input too large to bound ("
            + String(in_len)
            + " bytes)"
        )

    var out = List[UInt8](capacity=cap)
    out.resize(cap, 0)
    var written = Int(
        compress_fn(
            _ptr_of(data),
            c_long_long(in_len),
            Int(out.unsafe_ptr()),
            c_long_long(cap),
            c_int(quality),
            c_int(lgwin),
            c_int(mode),
        )
    )
    if written < 0:
        raise Error("brotli.compress failed (rc=" + String(written) + ")")
    out.resize(written, 0)
    return out^


def compress(
    data: Span[UInt8, _],
    quality: Int = DEFAULT_QUALITY,
    lgwin: Int = DEFAULT_WINDOW_BITS,
    mode: Int = MODE_GENERIC,
) raises -> List[UInt8]:
    """Compress `data` into a single Brotli stream.

    Zero-length `data` is a real (if degenerate) case: Brotli emits a valid
    one-byte stream that decodes back to nothing.

    Args:
        data: Bytes to compress.
        quality: 0..11; higher is slower and smaller. 11 is libbrotli's own
            default and is *very* slow on large inputs — 4 or 5 is the usual
            choice for Parquet pages.
        lgwin: Sliding-window size in bits, 10..24 (22 = 4 MiB).
        mode: `MODE_GENERIC`, `MODE_TEXT`, or `MODE_FONT` — a hint that
            selects the encoder's context model.
    """
    ref lib = _lib()
    return _do_compress(lib, data, quality, lgwin, mode)


# ===----------------------------------------------------------------------===#
# Decompression. Brotli streams carry no uncompressed size, so the sized and
# unsized paths are genuinely different operations.
# ===----------------------------------------------------------------------===#


def _do_decompress_into(
    imm lib: OwnedDLHandle,
    data: Span[UInt8, _],
    dst: Span[mut=True, UInt8, _],
) raises -> Int:
    """One decode pass into `dst`. Returns bytes written, or `_ERR_TOO_SMALL`
    for the caller to grow and retry; raises on corrupt or truncated input."""
    var decompress_fn = lib.get_function[c_long_long]("brm_decompress")

    # A one-element list stands in for the `int*` out-parameter, the same way
    # zstd.mojo passes its streaming positions.
    var err = List[Int32](capacity=1)
    err.resize(1, 0)

    var out_ptr = Int(0)
    if len(dst) > 0:
        out_ptr = Int(dst.unsafe_ptr())
    var written = Int(
        decompress_fn(
            _ptr_of(data),
            c_long_long(len(data)),
            out_ptr,
            c_long_long(len(dst)),
            Int(err.unsafe_ptr()),
        )
    )
    if written == _ERR_TOO_SMALL:
        return _ERR_TOO_SMALL
    if written == _ERR_TRUNCATED:
        raise Error(
            "brotli.decompress: input ended mid-stream (truncated after "
            + String(len(data))
            + " bytes)"
        )
    if written < 0:
        raise Error(
            "brotli.decompress: " + _error_string(lib, Int(err[0]))
        )
    return written


def decompress_into(
    data: Span[UInt8, _], dst: Span[mut=True, UInt8, _]
) raises -> Int:
    """Decompress a Brotli stream into a caller-supplied buffer, returning the
    number of bytes written.

    Raises if `dst` is too small — Brotli records no uncompressed size, so this
    cannot grow the buffer for you. Use `decompress_unsized` when the size is
    genuinely unknown."""
    ref lib = _lib()
    var written = _do_decompress_into(lib, data, dst)
    if written == _ERR_TOO_SMALL:
        raise Error(
            "brotli.decompress_into: destination too small ("
            + String(len(dst))
            + " bytes)"
        )
    return written


def decompress(
    data: Span[UInt8, _], uncompressed_size: Int
) raises -> List[UInt8]:
    """Decompress a Brotli stream whose decoded length is already known — the
    Parquet page path, where `uncompressed_page_size` comes from the page
    header. `uncompressed_size` must be exact; a stream that decodes to a
    different length is treated as corrupt."""
    ref lib = _lib()
    var out = List[UInt8](capacity=uncompressed_size)
    out.resize(uncompressed_size, 0)

    var written = _do_decompress_into(lib, data, Span(out))
    if written == _ERR_TOO_SMALL:
        raise Error(
            "brotli.decompress: stream decodes to more than the "
            + String(uncompressed_size)
            + " bytes it was said to hold"
        )
    if written != uncompressed_size:
        raise Error(
            "brotli.decompress: size mismatch (got "
            + String(written)
            + ", expected "
            + String(uncompressed_size)
            + ")"
        )
    return out^


def decompress_unsized(data: Span[UInt8, _]) raises -> List[UInt8]:
    """Decompress a Brotli stream of unknown decoded length.

    Starts from a guess and doubles until the stream fits. Each retry decodes
    from the beginning — Brotli's decoder cannot resume a one-shot call into a
    bigger buffer — so prefer `decompress` whenever the size is known out of
    band, which for Parquet it always is."""
    ref lib = _lib()

    # Brotli routinely reaches 4–10x on the text it is tuned for; starting at
    # 8x keeps the common case to a single pass without over-allocating wildly.
    var cap = len(data) * 8
    if cap < 4096:
        cap = 4096

    while True:
        var out = List[UInt8](capacity=cap)
        out.resize(cap, 0)
        var written = _do_decompress_into(lib, data, Span(out))
        if written != _ERR_TOO_SMALL:
            out.resize(written, 0)
            return out^
        cap *= 2


# ===----------------------------------------------------------------------===#
# Library versions. Encoder and decoder ship as separate shared libraries and
# can in principle differ, so both are reported.
# ===----------------------------------------------------------------------===#


def _format_version(raw: Int) -> String:
    """libbrotli packs its version as `(major << 24) | (minor << 12) | patch`.
    """
    return String(
        (raw >> 24) & 0xFF, ".", (raw >> 12) & 0xFFF, ".", raw & 0xFFF
    )


def encoder_version() raises -> String:
    """The libbrotlienc version this process is linked against, e.g. "1.1.0".
    """
    ref lib = _lib()
    var version_fn = lib.get_function[c_long_long]("brm_encoder_version")
    return _format_version(Int(version_fn()))


def decoder_version() raises -> String:
    """The libbrotlidec version this process is linked against, e.g. "1.1.0".
    """
    ref lib = _lib()
    var version_fn = lib.get_function[c_long_long]("brm_decoder_version")
    return _format_version(Int(version_fn()))
