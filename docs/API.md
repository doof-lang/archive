# std/archive Guide

`std/archive` reads and writes ZIP archives in memory. It also exposes raw
deflate helpers for callers that need the compression primitive without a gzip
or zlib container.

The ZIP API uses simple entry value objects, similar to `std/fs` directory
metadata. `readZip` returns `ZipEntry[]`; each entry includes its name, kind,
sizes, CRC32, compression method, and uncompressed data.

## Quick Start

```doof
import { ZipEntry, readZip, writeZip } from "std/archive"

archive := writeZip([
  ZipEntry {
    name: "docs/",
    kind: .Directory,
    compression: .Store,
  },
  ZipEntry {
    name: "docs/hello.txt",
    data: bytes,
  },
])

entries := try! readZip(archive)
```

## ZIP Support

`writeZip` writes ZIP32 archives with UTF-8 entry names. File entries default to
deflate compression. Directory entries should use names ending in `/` and are
stored without compression.

`readZip` supports ZIP32 archives whose entries are either stored or raw
deflated. Invalid, truncated, CRC-mismatched, or unsupported archives return a
`Failure<string>`.

Streaming archives, encrypted archives, ZIP64, and entries that use data
descriptors are not currently supported.

## Raw Deflate

`deflate(data)` and `inflate(data)` operate on raw deflate streams. They do not
include gzip headers or zlib wrappers. Use `std/gzip` when you need a gzip
container.

## API

### `ZipEntry`

```doof
export class ZipEntry {
  name: string
  kind: ArchiveEntryKind = .File
  size: long = 0L
  compressedSize: long = 0L
  crc32: long = 0L
  compression: ZipCompression = .Deflate
  data: readonly byte[] = []
}
```

For input to `writeZip`, callers usually set `name`, `data`, and optionally
`kind` or `compression`. Size and checksum fields are populated by `readZip`.

### `readZip`

```doof
export function readZip(data: readonly byte[]): Result<ZipEntry[], string>
```

Read all entries from a complete ZIP archive.

### `writeZip`

```doof
export function writeZip(entries: readonly ZipEntry[]): readonly byte[]
```

Write a complete ZIP archive.

### `deflate`

```doof
export import function deflate(data: readonly byte[]): readonly byte[]
```

Compress bytes as a raw deflate stream.

### `inflate`

```doof
export import function inflate(data: readonly byte[]): Result<readonly byte[], string>
```

Decompress a raw deflate stream.

### `crc32`

```doof
export import function crc32(data: readonly byte[]): long
```

Return the ZIP-compatible CRC32 checksum for a byte array.
