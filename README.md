# brotli.mojo

[![mojoshelf](https://mojoshelf.org/badge/brotli-mojo.svg)](https://mojoshelf.org/tins/brotli-mojo) [![mojo nightly](https://mojoshelf.org/badge/brotli-mojo/nightly.svg)](https://mojoshelf.org/tins/brotli-mojo)

A Mojo binding to **libbrotli** ([RFC 7932](https://www.rfc-editor.org/rfc/rfc7932))
— compress and decompress. A small C shim (`shim/brotli_wrapper.c`) is compiled
to **`libbrotlimojo.{dylib,so}`** and loaded through an `OwnedDLHandle`. No link
flags for consumers; the shim is `dlopen`ed at runtime.

Part of [**magmalake**](https://magmalake.org) — data lake building blocks in Mojo.

## Install

```sh
pixi shelf add brotli-mojo
```

Working with a coding agent? `npx skills add mojoshelf/mojoshelf --skill mojoshelf-consume --yes` teaches it to find and install tins itself — it installs the `shelf` CLI too.

That resolves the tin from [mojoshelf](https://mojoshelf.org) and adds it — along with the tins it depends on — as **pixi git source dependencies**. magmalake tins are not published to a conda channel, so `pixi add brotli-mojo` will not find them.

## Why brotli.mojo

`BROTLI` is one of the seven compression codecs in the Parquet spec, and it was
the last one [parquet.mojo](https://github.com/magmalake/parquet.mojo) could not
read — the single gap left in its run against
[apache/parquet-testing](https://github.com/apache/parquet-testing) once the
corrupt-checksum files were accounted for.

This is a **binding, not an implementation**. A from-scratch Brotli decoder is
not a weekend of work the way Snappy was: RFC 7932 specifies two prefix-code
forms, context modelling with context maps, block-type switching with its own
Huffman codes, a distance cache with postfix bits, and a 122 KB static
dictionary plus 121 word transforms that are part of the format and have to be
embedded verbatim. That is a few thousand lines before the first correct byte.
Binding libbrotli — the reference implementation, already in conda-forge, and
what pyarrow and parquet-mr link too — reads those files today and matches
`zstd.mojo` and `lz4.mojo`, which are FFI shims for the same reason.

## Prerequisites

- [pixi](https://pixi.sh) — manages the Mojo toolchain and the conda-forge
  `libbrotlidec` / `libbrotlienc` / `libbrotlicommon` dependencies.
- macOS (`osx-arm64`) or Linux (`linux-64`, `linux-aarch64`).

Everything else — the Mojo compiler, libbrotli, and the CMake shim build — is
resolved and built by `pixi install`.

## Use

```mojo
from brotli import compress, decompress, decompress_unsized

# Parquet BROTLI page: the page header carries the uncompressed length.
var page_stream = compress(page_bytes, quality=5)
var page = decompress(page_stream, uncompressed_size)

# Anything that did not record a length (a bare .br blob).
var blob = decompress_unsized(stream_bytes)
```

Build the shim once, then build a consumer with this package on the import
path:

```sh
pixi install                                              # builds libbrotlimojo.{dylib,so} -> $CONDA_PREFIX/lib
mojo build your.mojo -I ../brotli.mojo/src -o your-bin    # no link flags needed
```

`_open_lib()` resolves the shim at `$CONDA_PREFIX/lib/libbrotlimojo.dylib` (or
`.so`; CMake picks the platform's natural extension), falling back to
`build/libbrotlimojo.{dylib,so}` for a bare checkout outside pixi.

## API

```mojo
def compress(
    data: Span[UInt8],
    quality: Int = DEFAULT_QUALITY,       # 11
    lgwin: Int = DEFAULT_WINDOW_BITS,     # 22
    mode: Int = MODE_GENERIC,
) raises -> List[UInt8]

def decompress(data: Span[UInt8], uncompressed_size: Int) raises -> List[UInt8]
def decompress_into(data: Span[UInt8], dst: Span[UInt8]) raises -> Int
def decompress_unsized(data: Span[UInt8]) raises -> List[UInt8]

def encoder_version() raises -> String
def decoder_version() raises -> String
```

Constants: `MODE_GENERIC` / `MODE_TEXT` / `MODE_FONT`, `MIN_QUALITY` (0) /
`MAX_QUALITY` (11) / `DEFAULT_QUALITY` (11), `MIN_WINDOW_BITS` (10) /
`MAX_WINDOW_BITS` (24) / `DEFAULT_WINDOW_BITS` (22).

**A Brotli stream records no uncompressed size** — not in a header, not in a
trailer — which is why there are two decompress entry points rather than one:

- `decompress(data, uncompressed_size)` is the Parquet path. The page header
  carries `uncompressed_page_size`, so the buffer is sized exactly and the
  stream is decoded in a single pass. A stream that decodes to a different
  length is treated as corrupt.
- `decompress_unsized(data)` guesses a capacity and doubles it until the stream
  fits. Each retry decodes from the beginning — Brotli's decoder cannot resume a
  one-shot call into a bigger buffer — so prefer the sized form whenever the
  size is known.

`quality` defaults to libbrotli's own `BROTLI_DEFAULT_QUALITY` of 11, which is
*slow*: single-digit MB/s on large inputs. For Parquet pages, 4 or 5 is the
usual trade.

All functions raise with a descriptive message on corrupt, truncated or
oversized input; decoder failures carry libbrotli's own error string.

## Test

```sh
pixi run test     # nightly (default env)
pixi run -e stable test
```

17 tests: round trips at 0 B, 1 B, 1 KiB, 1 MiB (compressible) and 1 MiB
(random); across qualities 0/1/5/9/11, window sizes 10/16/24, and all three
encoder modes; the sized, into-buffer and unsized decompress paths; and the
corrupt / truncated / buffer-too-small / wrong-size error paths.

The **known-vector** tests are the ones that matter. Three streams produced by
CPython's `brotli` package are baked in as constants (no Python dependency at
run time) and decoded here: a quality-11 stored block, a quality-5 stream that
exercises the Huffman tables and Brotli's static dictionary, and a quality-9
stream that is all back-references. Round-tripping a codec against itself only
proves its two halves agree — parquet.mojo's ALP decoder read every file without
error on its first build and produced entirely wrong values.

## Perf

```sh
pixi run -e bench bench                 # the table below
pixi run -e bench bench -- --json       # every repetition, for tracking
pixi run -e bench bench -- --only bench_decompress
```

Measured on an Apple M4 (osx-arm64), 16 MiB of highly compressible synthetic
input — a repeating phrase, which Brotli's 4 MiB window turns into almost pure
back-references (4 357x at quality 1, 105 517x at quality 5). Treat these as an
upper bound, not a prediction for real column data. Through
[bench.mojo](https://github.com/magmalake/bench.mojo): mean of five timed
repetitions, spread under 2.3% on every row.

| Operation | Time (16 MiB) | Throughput |
|---|---:|---:|
| `compress(quality=1)` | 811 µs | 20.7 GB/s |
| `compress(quality=5)` | 10.2 ms | 1.65 GB/s |
| `decompress` | 6.72 ms | 2.50 GB/s |

Every push to `main` re-runs these on a GitHub runner and appends to a history
published at
[magmalake.github.io/brotli.mojo/benchmarks](https://magmalake.github.io/brotli.mojo/benchmarks/).
Each history is keyed by machine, so runner and laptop numbers stay separate
series and are never averaged together.

There is deliberately no quality-11 benchmark: at libbrotli's default quality a
16 MiB pass takes seconds and would dominate the suite's wall clock without
saying anything the quality-5 row does not. Decompression is the number that
matters for Parquet — reads are the hot path, and Brotli decodes at roughly the
same speed whatever quality produced the stream.

Rates are quoted against the **uncompressed** size in both directions, which is
what a caller cares about: payload bytes moved per second.

**What these numbers measure.** This tin is a binding, not an implementation —
the compression is libbrotli's, reached through the C shim below. The benchmark
measures libbrotli plus the per-call cost of crossing the FFI boundary, and at
16 MiB per call that crossing is noise. It is not a measurement of Mojo code.

## Shim build

`shim/` is a [pixi-build-cmake](https://pixi.sh) package: `CMakeLists.txt` links
`shim/brotli_wrapper.c` against conda-forge's `libbrotlidec` / `libbrotlienc` /
`libbrotlicommon`, producing `libbrotlimojo.{dylib,so}` (natural extension per
platform), installed to `$CONDA_PREFIX/lib` by `pixi install`.

**Why a C shim, not calling libbrotli directly?** Same reasoning as zstd.mojo
and lz4.mojo: a single-call API means Mojo never reads back internal library
state after a foreign call, and `dlopen`ing the shim at runtime means consumers
never need `-l` link flags. The handle is opened once per process and never
closed — on macOS a `dlopen`/`dlclose` cycle of an already-resident library
costs around 450 µs, three orders of magnitude more than decompressing a Parquet
page — and is passed as a borrowed parameter to each worker function so Mojo's
ASAP destruction cannot `dlclose` the library before the C call inside that
worker runs.

The shim has one piece of real logic. It drives the decoder through
`BrotliDecoderDecompressStream` rather than the one-shot
`BrotliDecoderDecompress`, because the one-shot collapses every non-success
result to `BROTLI_DECODER_RESULT_ERROR` — so "your output buffer was too small"
becomes indistinguishable from "this stream is corrupt". Since Brotli records no
uncompressed size, a caller without the size out of band has to guess a capacity
and grow, and that loop needs the distinction. One pass of the streaming decoder
keeps the same one-call shape and reports `NEEDS_MORE_OUTPUT` and
`NEEDS_MORE_INPUT` apart.

## Status / scope

- One-shot only. There are no streaming `Compressor`/`Decompressor` types the
  way `zstd.mojo` has them — Parquet pages and Puffin blobs are whole-buffer
  operations, and nothing in magmalake needs Brotli incrementally yet.
- Lengths are `long long` on both sides of the FFI boundary rather than the
  `int` lz4.mojo uses: a Brotli Parquet column chunk can legitimately exceed
  2 GiB, and the one Brotli file in apache/parquet-testing does.
- Trailing bytes after a complete stream are ignored, matching what Parquet
  readers do with page padding.
- Custom dictionaries (`BrotliEncoderAttachPreparedDictionary` and friends) are
  not exposed. Parquet does not use them.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

libbrotli itself is MIT-licensed and is not vendored here — it is resolved from
conda-forge at install time.
