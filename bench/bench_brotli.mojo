"""Compress and decompress throughput over 16 MiB, through the shared harness
(magmalake/bench.mojo).

    pixi run -e bench bench
    pixi run -e bench bench -- --json
    pixi run -e bench bench -- --only bench_decompress

16 MiB rather than the 64 MiB the lz4 and zstd benches use, and no quality-11
compression benchmark: brotli at its default quality runs at single-digit MB/s,
so a 64 MiB q11 pass would dominate the whole suite's wall clock without
telling us anything the q5 number does not. Decompression is the number that
matters for Parquet anyway — reads are the hot path.

Each body rebuilds its input and, for the decompress benchmark, recompresses
it. The harness re-enters a body once per phase and times only what is inside
`b.iter`, so that setup is wall-clock cost and never enters the numbers.
"""

from bench import Benchmark, BenchSuite, Metric, keep

from brotli import compress, decompress

comptime SIZE = 16 * 1024 * 1024
comptime PHRASE: StaticString = (
    "brotli.mojo: Parquet BROTLI pages via libbrotli. "
)


def _pattern(n: Int) -> List[UInt8]:
    var phrase = String(PHRASE).as_bytes()
    var out = List[UInt8](capacity=n)
    var i = 0
    while len(out) < n:
        out.append(phrase[i % len(phrase)])
        i += 1
    return out^


def bench_compress_q1(mut b: Benchmark) raises:
    var src = _pattern(SIZE)
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        var stream = compress(src, quality=1)
        keep(stream)

    b.iter[call]()
    keep(src)


def bench_compress_q5(mut b: Benchmark) raises:
    var src = _pattern(SIZE)
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        var stream = compress(src, quality=5)
        keep(stream)

    b.iter[call]()
    keep(src)


def bench_decompress(mut b: Benchmark) raises:
    var src = _pattern(SIZE)
    var stream = compress(src, quality=5)
    # Rate is against the uncompressed size: payload bytes recovered/second.
    b.throughput(Metric.bytes(), SIZE)

    @parameter
    def call() raises:
        var back = decompress(stream, SIZE)
        keep(back)

    b.iter[call]()
    keep(src)
    keep(stream)


def _print_shape() raises:
    """Compressed sizes and the round-trip check, once. Asserting a round trip
    inside a timing region does not belong there."""
    var src = _pattern(SIZE)
    var q1 = compress(src, quality=1)
    var q5 = compress(src, quality=5)
    if len(decompress(q5, SIZE)) != SIZE:
        raise Error("round trip size mismatch")
    print(
        "input", SIZE // (1024 * 1024), "MiB compressible |",
        "q1 ->", len(q1) // 1024, "KiB",
        "(", Float64(SIZE) / Float64(len(q1)), "x ) |",
        "q5 ->", len(q5) // 1024, "KiB",
        "(", Float64(SIZE) / Float64(len(q5)), "x )",
    )


def main() raises:
    _print_shape()
    BenchSuite.run[__functions_in_module()]()
