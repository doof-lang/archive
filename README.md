# std/archive

Archive helpers for byte-oriented ZIP and TAR formats.

## Documentation

- [Guide and API reference](docs/API.md) covers ZIP and TAR/PAX archive reading and writing plus raw deflate helpers.
- [Cookbook](docs/cookbook/README.md) provides task-oriented recipes, including selective reads from ZIP or TAR bundles of `.tar.zst` module archives.
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

Large ZIP files also support seekable metadata scans and selective entry
decompression:

```doof
import { readZipEntry, scanZipFile } from "std/archive"

entries := try! scanZipFile("stdlib.zip")
moduleBytes := try! readZipEntry("stdlib.zip", entries[0])
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

Large uncompressed TAR files can instead be scanned without retaining their
payloads, then read selectively by indexed byte range:

```doof
import { readTarEntry, scanTarFile } from "std/archive"

entries := try! scanTarFile("stdlib.tar")
moduleBytes := try! readTarEntry("stdlib.tar", entries[0])
```

This seekable API supports plain TAR files only. Compressed TAR files must be
decoded before parsing and cannot provide direct entry-range reads.

TAR entries use `TarEntryKind`, independently of ZIP's `ArchiveEntryKind`.
Readers retain each entry's numeric mode and modification time as an
`std/time.Instant`. Writers default to mode `0644` for files, `0755` for
directories, and the Unix epoch; `mode` and `mtime` can be supplied explicitly.
Fractional and pre-epoch modification times use the standard PAX `mtime` key.
Symbolic links use `TarEntryKind.SymbolicLink` and expose their target through
`linkName`; long targets use the standard PAX `linkpath` key.

## Exports

### `readZip(data: readonly byte[]): Result<ZipEntry[], string>`

Read a complete ZIP archive from memory.

### `writeZip(entries: readonly ZipEntry[]): readonly byte[]`

Write a complete ZIP archive to memory.

### `scanZipFile(path: string): Result<readonly ZipFileEntry[], string>`

Read a ZIP file's central directory without loading or decompressing ordinary
entry payloads.

### `readZipEntry(path: string, entry: ZipFileEntry): Result<readonly byte[], string>`

Seek to, decompress, size-check, and CRC-check one entry returned by
`scanZipFile`.

### `deflate(data: readonly byte[]): readonly byte[]`

Compress bytes with raw deflate, without a zlib or gzip wrapper.

### `inflate(data: readonly byte[]): Result<readonly byte[], string>`

Decompress raw deflate bytes.

### `readTarBlob(data: readonly byte[]): Result<TarArchive, string>`

Index a complete TAR archive while retaining entry payloads as spans into the input blob.

### `readTarFile(path: string): Result<TarArchive, string>`

Read and index a TAR file. Paths ending in `.tar.gz` are gzip-decoded automatically.

### `scanTarFile(path: string): Result<readonly TarEntry[], string>`

Index a plain TAR file by reading headers and PAX metadata while skipping
ordinary entry payloads.

### `readTarEntry(path: string, entry: TarEntry): Result<readonly byte[], string>`

Seek to and read one entry returned by `scanTarFile`. The file must remain
unchanged between scanning and reading.

### `writeTarBlob(entries: readonly TarWriteEntry[]): readonly byte[]`

Write a deterministic POSIX PAX-compatible archive to a blob.

### `writeTarFile(path: string, entries: readonly TarWriteEntry[]): Result<none, string>`

Write a deterministic POSIX PAX-compatible archive directly to a file. Paths ending in `.tar.gz` are gzip-encoded automatically.
