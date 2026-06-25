# std/archive

Archive helpers for byte-oriented formats.

## Documentation

- [Guide and API reference](docs/API.md) covers ZIP archive reading and writing plus raw deflate helpers.
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

## Exports

### `readZip(data: readonly byte[]): Result<ZipEntry[], string>`

Read a complete ZIP archive from memory.

### `writeZip(entries: readonly ZipEntry[]): readonly byte[]`

Write a complete ZIP archive to memory.

### `deflate(data: readonly byte[]): readonly byte[]`

Compress bytes with raw deflate, without a zlib or gzip wrapper.

### `inflate(data: readonly byte[]): Result<readonly byte[], string>`

Decompress raw deflate bytes.
