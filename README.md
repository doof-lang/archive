# std/archive

Archive helpers for byte-oriented ZIP and TAR formats.

## Documentation

- [Guide and API reference](docs/API.md) covers ZIP and TAR/PAX archive reading and writing plus raw deflate helpers.
- Tests can be run with `doof test archive`.

## Usage

```doof
import { ZipEntry, readZip, writeZip } from "std/archive"

archive := writeZip([
  ZipEntry {
    name: "hello.txt",
    data: bytes,
  },
])

entries := try! readZip(archive)
```

TAR supports both blobs and files. Parsed entries retain spans into the
original archive instead of eagerly copying file payloads:

```doof
import { TarEntryKind, TarWriteEntry, readTarBlob, writeTarBlob } from "std/archive"

blob := writeTarBlob([
  TarWriteEntry { name: "hello.txt", data: bytes, mode: 493 },
])
archive := try! readTarBlob(blob)
content := archive.entryData(archive.entries[0])
```

TAR entries use `TarEntryKind`, independently of ZIP's `ArchiveEntryKind`.
Readers retain each entry's numeric mode and modification time as an
`std/time.Instant`. Writers default to mode `0644` for files, `0755` for
directories, and the Unix epoch; `mode` and `mtime` can be supplied explicitly.
Fractional and pre-epoch modification times use the standard PAX `mtime` key.

## Exports

### `readZip(data: readonly byte[]): Result<ZipEntry[], string>`

Read a complete ZIP archive from memory.

### `writeZip(entries: readonly ZipEntry[]): readonly byte[]`

Write a complete ZIP archive to memory.

### `deflate(data: readonly byte[]): readonly byte[]`

Compress bytes with raw deflate, without a zlib or gzip wrapper.

### `inflate(data: readonly byte[]): Result<readonly byte[], string>`

Decompress raw deflate bytes.

### `readTarBlob(data: readonly byte[]): Result<TarArchive, string>`

Index a complete TAR archive while retaining entry payloads as spans into the input blob.

### `readTarFile(path: string): Result<TarArchive, string>`

Read and index a TAR file. Paths ending in `.tar.gz` are gzip-decoded automatically.

### `writeTarBlob(entries: readonly TarWriteEntry[]): readonly byte[]`

Write a deterministic POSIX PAX-compatible archive to a blob.

### `writeTarFile(path: string, entries: readonly TarWriteEntry[]): Result<none, string>`

Write a deterministic POSIX PAX-compatible archive directly to a file. Paths ending in `.tar.gz` are gzip-encoded automatically.
