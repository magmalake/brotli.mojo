"""Unit tests for brotli.mojo: round trips at several sizes, qualities, window
sizes and modes; known-vector cross-checks against CPython's `brotli` package
(baked in as constants, so the test has no Python dependency at run time); and
the corrupt / truncated / buffer-too-small error paths.

The known vectors matter more here than the round trips. A codec that
round-trips against itself proves only that its two halves agree — the ALP
lesson from parquet.mojo, where a decoder read every file without error and
produced entirely wrong values. These streams were produced by the reference
encoder and this library never saw them until it decoded them.
"""

from std.testing import TestSuite, assert_equal, assert_true, assert_raises

from brotli import (
    MODE_FONT,
    MODE_GENERIC,
    MODE_TEXT,
    compress,
    decoder_version,
    decompress,
    decompress_into,
    decompress_unsized,
    encoder_version,
)


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var p = s.unsafe_ptr()
    for i in range(s.byte_length()):
        out.append(p[unsafe_offset=i])
    return out^


comptime PHRASE: StaticString = "brotli.mojo: Parquet BROTLI pages via libbrotli. "


def _pattern(n: Int) -> List[UInt8]:
    """Highly compressible: a short phrase repeated to length `n`. The same
    phrase the Python-side vector generator used."""
    var phrase_bytes = _bytes_of(String(PHRASE))
    var out = List[UInt8](capacity=n)
    var i = 0
    while len(out) < n:
        out.append(phrase_bytes[i % len(phrase_bytes)])
        i += 1
    return out^


def _random_bytes(n: Int) -> List[UInt8]:
    """Deterministic xorshift32 fill — incompressible, unlike `_pattern`."""
    var state: UInt32 = 0x2545F491
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        out.append(UInt8(state & 0xFF))
    return out^


def _assert_bytes_equal(got: List[UInt8], expected: List[UInt8]) raises:
    assert_equal(len(got), len(expected))
    for i in range(len(expected)):
        if got[i] != expected[i]:
            raise Error(
                "byte mismatch at index "
                + String(i)
                + ": got "
                + String(got[i])
                + ", expected "
                + String(expected[i])
            )


# ===----------------------------------------------------------------------===#
# Round trips.
# ===----------------------------------------------------------------------===#


def _roundtrip_sizes() -> List[Int]:
    return [0, 1, 1024, 1024 * 1024]


def test_roundtrip() raises:
    # Quality 5 rather than the default 11: brotli at 11 spends seconds on a
    # megabyte, and nothing here is testing the encoder's search effort.
    for n in _roundtrip_sizes():
        var src = _pattern(n)
        var comp = compress(src, quality=5)
        var back = decompress(comp, n)
        _assert_bytes_equal(back, src)

    var random_src = _random_bytes(1024 * 1024)
    var comp = compress(random_src, quality=5)
    var back = decompress(comp, len(random_src))
    _assert_bytes_equal(back, random_src)


def test_roundtrip_quality_levels() raises:
    var src = _pattern(64 * 1024)
    for q in [0, 1, 5, 9, 11]:
        var comp = compress(src, quality=q)
        var back = decompress(comp, len(src))
        _assert_bytes_equal(back, src)


def test_roundtrip_window_bits() raises:
    var src = _pattern(64 * 1024)
    # 10 is BROTLI_MIN_WINDOW_BITS (1 KiB back-reference window), 24 the max.
    for lgwin in [10, 16, 24]:
        var comp = compress(src, quality=5, lgwin=lgwin)
        var back = decompress(comp, len(src))
        _assert_bytes_equal(back, src)


def test_roundtrip_modes() raises:
    var src = _pattern(16 * 1024)
    for mode in [MODE_GENERIC, MODE_TEXT, MODE_FONT]:
        var comp = compress(src, quality=5, mode=mode)
        var back = decompress(comp, len(src))
        _assert_bytes_equal(back, src)


def test_empty_roundtrip() raises:
    var empty = List[UInt8]()
    var comp = compress(empty)
    # Brotli's degenerate stream: one byte, not zero.
    assert_equal(len(comp), 1)
    var back = decompress(comp, 0)
    assert_equal(len(back), 0)


def test_compression_actually_compresses() raises:
    # Guards against a shim that silently stores instead of compressing.
    var src = _pattern(64 * 1024)
    var comp = compress(src, quality=5)
    assert_true(len(comp) < len(src) // 10)


def test_decompress_into() raises:
    var src = _pattern(4096)
    var comp = compress(src, quality=5)
    var dst = List[UInt8](capacity=len(src))
    dst.resize(len(src), 0)
    var written = decompress_into(comp, dst)
    assert_equal(written, len(src))
    _assert_bytes_equal(dst, src)


def test_decompress_unsized() raises:
    # The size-unknown path: it has to grow past its first guess for a highly
    # compressible input, so this exercises the retry loop, not just one pass.
    for n in [0, 1, 4096, 1024 * 1024]:
        var src = _pattern(n)
        var comp = compress(src, quality=5)
        var back = decompress_unsized(comp)
        _assert_bytes_equal(back, src)


# ===----------------------------------------------------------------------===#
# Known vectors, produced by CPython `brotli` (libbrotli 1.1):
#   brotli.compress(msg, quality=Q)
# Baked in so nothing this library produced is on the input side of the test.
# ===----------------------------------------------------------------------===#


def _known_message() -> String:
    return "The quick brown fox jumps over the lazy dog. Brotli is RFC 7932."


def _known_q11_bytes() -> List[UInt8]:
    """`brotli.compress(msg, quality=11)` — 64 bytes in, 68 out. Incompressible
    at this length, so the encoder emits it as a literal metablock."""
    return [
        139, 31, 128, 84, 104, 101, 32, 113, 117, 105, 99, 107, 32, 98, 114,
        111, 119, 110, 32, 102, 111, 120, 32, 106, 117, 109, 112, 115, 32,
        111, 118, 101, 114, 32, 116, 104, 101, 32, 108, 97, 122, 121, 32, 100,
        111, 103, 46, 32, 66, 114, 111, 116, 108, 105, 32, 105, 115, 32, 82,
        70, 67, 32, 55, 57, 51, 50, 46, 3,
    ]


def _known_q5_bytes() -> List[UInt8]:
    """`brotli.compress(msg, quality=5)` — 65 bytes. Unlike the quality-11
    vector this one actually encodes, so it exercises the Huffman tables and
    Brotli's built-in static dictionary rather than a stored block."""
    return [
        27, 63, 0, 0, 4, 4, 157, 83, 182, 66, 109, 59, 144, 197, 248, 231,
        194, 0, 112, 142, 162, 17, 84, 149, 173, 210, 182, 194, 124, 201, 247,
        229, 153, 169, 151, 151, 254, 154, 214, 131, 229, 174, 246, 3, 99, 27,
        179, 255, 163, 92, 26, 129, 191, 47, 231, 216, 209, 29, 36, 113, 128,
        227, 25, 186, 0,
    ]


def _known_pattern_q9_bytes() -> List[UInt8]:
    """`brotli.compress(pattern(4096), quality=9)` for the same `PHRASE` this
    file repeats — 57 bytes, so it is all back-references."""
    return [
        27, 255, 15, 0, 196, 218, 57, 173, 55, 76, 218, 141, 54, 165, 72, 134,
        229, 191, 12, 175, 215, 35, 100, 47, 26, 61, 150, 214, 181, 53, 62,
        118, 85, 220, 180, 97, 30, 133, 206, 126, 253, 34, 212, 220, 82, 196,
        186, 5, 95, 8, 42, 140, 79, 60, 0, 64, 4,
    ]


def test_decompress_known_q11() raises:
    var expected = _bytes_of(_known_message())
    _assert_bytes_equal(decompress(_known_q11_bytes(), len(expected)), expected)


def test_decompress_known_q5() raises:
    var expected = _bytes_of(_known_message())
    _assert_bytes_equal(decompress(_known_q5_bytes(), len(expected)), expected)


def test_decompress_known_pattern() raises:
    var expected = _pattern(4096)
    _assert_bytes_equal(
        decompress(_known_pattern_q9_bytes(), len(expected)), expected
    )


def test_decompress_known_unsized() raises:
    # Same vectors through the grow-and-retry path.
    var expected = _pattern(4096)
    _assert_bytes_equal(
        decompress_unsized(_known_pattern_q9_bytes()), expected
    )


# ===----------------------------------------------------------------------===#
# Error paths.
# ===----------------------------------------------------------------------===#


def test_corrupt_raises() raises:
    var garbage: List[UInt8] = [
        0xFF, 0x7A, 0x13, 0x02, 0x93, 0x44, 0xC5, 0x21, 0x0E, 0xB7,
    ]
    with assert_raises():
        _ = decompress_unsized(garbage)


def test_truncated_raises() raises:
    var comp = _known_pattern_q9_bytes()
    var cut = List[UInt8]()
    for i in range(len(comp) // 2):
        cut.append(comp[i])
    with assert_raises(contains="truncated"):
        _ = decompress_unsized(cut)


def test_decompress_into_too_small_raises() raises:
    var comp = _known_pattern_q9_bytes()
    var dst = List[UInt8](capacity=64)
    dst.resize(64, 0)
    with assert_raises(contains="too small"):
        _ = decompress_into(comp, dst)


def test_decompress_wrong_size_raises() raises:
    var comp = _known_pattern_q9_bytes()
    # Told it holds less than it does.
    with assert_raises():
        _ = decompress(comp, 1000)
    # Told it holds more than it does.
    with assert_raises(contains="mismatch"):
        _ = decompress(comp, 8192)


# ===----------------------------------------------------------------------===#
# Library identity.
# ===----------------------------------------------------------------------===#


def test_versions() raises:
    var enc = encoder_version()
    var dec = decoder_version()
    assert_true(enc.byte_length() > 0)
    assert_equal(enc, dec)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
