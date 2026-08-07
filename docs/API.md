# std/archive Guide

`std/archive` reads and writes ZIP and TAR archives. It also exposes raw
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

For TAR files, choose explicit blob or file entry points:

```doof
import { TarWriteEntry, readTarBlob, readTarFile, writeTarBlob, writeTarFile } from "std/archive"

tarBlob := writeTarBlob([
  TarWriteEntry { name: "docs/hello.txt", data: bytes },
])
archive := try! readTarBlob(tarBlob)
content := archive.entryData(archive.entries[0])

try! writeTarFile("docs.tar", [
  TarWriteEntry { name: "docs/hello.txt", data: bytes },
])
fromFile := try! readTarFile("docs.tar")
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

## TAR and PAX Support

`readTarBlob` indexes a complete TAR blob without copying regular-file
payloads. Each `TarEntry` records a `contentOffset` and `size` describing a
half-open span in `TarArchive.data`. Call `entryData(entry)` when a standalone
copy is needed.

`readTarFile` reads the file into one immutable blob and then uses the same
parser. Paths ending in `.tar.gz` are gzip-decoded automatically. `writeTarFile`
streams TAR headers, payloads, padding, and the terminator directly to the
destination, passing those chunks through gzip encoding for `.tar.gz` paths.

The reader accepts POSIX ustar archives and PAX `g` and `x` extended headers.
Per-entry values override global values, which override base-header values. The
`path` and `size` keys are supported; unknown PAX keys are ignored. Regular
files and directories are returned. Unsupported entry types, malformed
checksums or numbers, invalid UTF-8, truncated data, and invalid terminators
return `Failure<string>`.

The writer produces deterministic PAX-compatible archives. Entries whose ASCII
paths fit ustar use ordinary headers; long or non-ASCII paths automatically use
PAX metadata. File modes default to `0644`, directory modes default to `0755`,
and modification times default to `Instant.EPOCH`; callers can override mode
and modification time per entry. UID and GID are zero. The base ustar header
stores non-negative whole-second modification times. The writer automatically
uses the standard PAX `mtime` key for fractional, pre-epoch, or out-of-range
values, preserving the `Instant` at nanosecond precision. Duplicate names and
input order are preserved.

TAR blob APIs are not compressed. Compose them with `std/gzip` when working
with in-memory `.tar.gz` data:

```doof
compressed := gzip(writeTarBlob(entries))
archive := try! readTarBlob(try! gunzip(compressed))
```

Streaming TAR input, symlinks, hard links, devices, FIFOs, sparse files, GNU
long-name extensions, base-256 numeric fields, and filesystem extraction are
not currently supported.

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

### `TarEntry`

```doof
export class TarEntry {
  readonly name: string
  readonly kind: TarEntryKind
  readonly contentOffset: long
  readonly size: long
  readonly mode: int
  readonly mtime: Instant
}
```

Describes an entry, its numeric POSIX mode, modification time, and content span
inside `TarArchive.data`.

### `TarEntryKind`

```doof
export enum TarEntryKind {
  File = 0,
  Directory = 1,
}
```

TAR has its own entry-kind type so its future link, device, and special-file
support can evolve independently of ZIP's `ArchiveEntryKind`.

### `TarArchive`

```doof
export class TarArchive {
  readonly data: readonly byte[]
  readonly entries: readonly TarEntry[]
  entryData(entry: TarEntry): readonly byte[]
}
```

Owns the retained TAR blob and its indexed entries. `entryData` copies the
selected entry payload.

### `TarWriteEntry`

```doof
export class TarWriteEntry {
  readonly name: string
  readonly kind: TarEntryKind = .File
  readonly data: readonly byte[] = []
  readonly mode: int | none = none
  readonly mtime: Instant = Instant.EPOCH
}
```

Input value for TAR writing. Directory payloads are written empty. A `none`
mode selects `0644` for files and `0755` for directories.

### `readTarBlob`

```doof
export function readTarBlob(data: readonly byte[]): Result<TarArchive, string>
```

Index a complete in-memory TAR archive without copying entry payloads.

### `readTarFile`

```doof
export function readTarFile(path: string): Result<TarArchive, string>
```

Read a TAR file into a retained blob and index it. A `.tar.gz` suffix enables
automatic gzip decoding.

### `writeTarBlob`

```doof
export function writeTarBlob(entries: readonly TarWriteEntry[]): readonly byte[]
```

Write a complete deterministic PAX-compatible TAR blob.

### `writeTarFile`

```doof
export function writeTarFile(path: string, entries: readonly TarWriteEntry[]): Result<none, string>
```

Write a deterministic PAX-compatible TAR archive to a file. A `.tar.gz` suffix
enables automatic gzip encoding.

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
