# std/archive Cookbook

This cookbook is the task-oriented companion to the
[API guide](../API.md). It covers common ZIP and TAR workflows, including
selective access to independently compressed artifacts stored in large ZIP or
TAR bundles.

## Choose a container

Use ZIP when each entry should carry its own stored or deflated representation
and an embedded central directory is useful. ZIP creation and eager reading are
byte-array APIs; file scanning and selective entry reads are seekable.

Use TAR when entry ordering, POSIX metadata, deterministic output, or direct
payload offsets matter. A `.tar.gz` file is convenient for distribution, but
its compressed stream is not directly seekable. For random access, keep the
outer TAR plain and compress its individual payloads instead.

## Build and read a ZIP blob

`writeZip` produces a complete ZIP byte array. File entries default to deflate;
use `.Store` for data that is already compressed.

```doof
import { ZipEntry, readZip, writeZip } from "std/archive"

zip := writeZip([
  ZipEntry {
    name: "docs/",
    kind: .Directory,
    compression: .Store,
  },
  ZipEntry {
    name: "docs/readme.txt",
    data: readmeBytes,
  },
  ZipEntry {
    name: "assets/image.png",
    data: pngBytes,
    compression: .Store,
  },
])

for entry of try! readZip(zip) {
  println("${entry.name}: ${entry.size} bytes")
}
```

The ZIP reader verifies structure, compression methods, CRC-32 values, and
uncompressed sizes before returning entries.

## Read one entry from a large ZIP

`scanZipFile` reads the ZIP end record and central directory without loading or
decompressing ordinary payloads. `readZipEntry` then seeks to and verifies only
the selected stored or deflated member.

```doof
import { ZipFileEntry, readZipEntry, scanZipFile } from "std/archive"

function loadNamedZipEntry(path: string, name: string): Result<readonly byte[], string> {
  try entries := scanZipFile(path)
  let selected: ZipFileEntry | none = none
  for entry of entries {
    if entry.name == name {
      selected = entry
      break
    }
  }

  entry := selected else {
    return Failure { error: "missing ZIP entry: " + name }
  }
  return readZipEntry(path, entry)
}

moduleBytes := try! loadNamedZipEntry("stdlib.zip", "modules/archive.tar.zst")
```

Use `ZipCompression.Store` when writing payloads such as `.tar.zst`, PNG, or
other data that is already compressed. This avoids redundant deflate work while
retaining ZIP's built-in random-access index. Keep the ZIP unchanged between
the scan and selective read.

## Build and inspect a TAR blob

Use the blob APIs when the complete TAR already fits in memory. Parsing retains
the input and records payload spans instead of copying every file immediately.

```doof
import { TarWriteEntry, readTarBlob, writeTarBlob } from "std/archive"
import { Instant } from "std/time"

tarBytes := writeTarBlob([
  TarWriteEntry { name: "package/", kind: .Directory },
  TarWriteEntry {
    name: "package/module.do",
    data: sourceBytes,
    mode: 420,
    mtime: Instant.EPOCH,
  },
])

archive := try! readTarBlob(tarBytes)
source := archive.entryData(archive.entries[1])
```

`entryData` returns a standalone slice for the selected entry. Long or
non-ASCII names, long symbolic-link targets, and precise modification times
are represented with PAX metadata automatically.

## Write plain TAR and `.tar.gz` files

`writeTarFile` selects gzip encoding only from a `.tar.gz` suffix. The writer
streams TAR chunks to the destination, so it does not first build one combined
TAR byte array.

```doof
import { TarWriteEntry, readTarFile, writeTarFile } from "std/archive"

entries := readonly [
  TarWriteEntry { name: "release/app", data: executableBytes, mode: 493 },
  TarWriteEntry { name: "release/LICENSE", data: licenseBytes },
]

try! writeTarFile("release.tar", entries)
try! writeTarFile("release.tar.gz", entries)

plain := try! readTarFile("release.tar")
compressed := try! readTarFile("release.tar.gz")
```

`readTarFile` retains the full TAR in memory. For `.tar.gz`, that includes the
complete decompressed TAR. Use seekable scanning for a large plain TAR when
only one or a few payloads are needed.

## Read one entry from a large TAR

`scanTarFile` reads 512-byte TAR headers and required PAX metadata, seeking over
ordinary payloads. It returns the same entry metadata and payload offsets as
the in-memory parser without retaining the archive.

```doof
import { TarEntry, readTarEntry, scanTarFile } from "std/archive"

function loadNamedEntry(path: string, name: string): Result<readonly byte[], string> {
  try entries := scanTarFile(path)
  let selected: TarEntry | none = none
  for entry of entries {
    if entry.name == name {
      selected = entry
      break
    }
  }

  entry := selected else {
    return Failure { error: "missing TAR entry: " + name }
  }
  return readTarEntry(path, entry)
}

moduleBytes := try! loadNamedEntry("stdlib.tar", "modules/archive.tar.zst")
```

Keep the file unchanged between `scanTarFile` and `readTarEntry`; an entry is an
offset/size index into that exact file. Duplicate names are preserved, so the
selection policy—first, last, or all matches—belongs to the caller.

## Bundle independently compressed module archives

For a combined stdlib artifact with conditional module extraction, store each
module as its own `.tar.zst` payload inside a plain outer TAR. The outer TAR
provides offsets; each selected zstd frame decompresses independently.

An outer ZIP is also suitable and is self-indexing through its central
directory. Store each `.tar.zst` member with `.Store`, then use `scanZipFile`
and `readZipEntry`. Choose TAR when its deterministic POSIX-oriented layout is
valuable; choose ZIP when an embedded end-of-file index is more convenient.

```doof
import {
  TarArchive, TarEntry, TarWriteEntry, readTarBlob, readTarEntry, scanTarFile,
  writeTarBlob, writeTarFile,
} from "std/archive"
import { zstdCompress, zstdDecompress } from "std/zstd"

function buildBundle(moduleSource: readonly byte[]): Result<none, string> {
  moduleTar := writeTarBlob([
    TarWriteEntry { name: "archive/index.do", data: moduleSource },
  ])
  try compressed := zstdCompress(moduleTar)
  return writeTarFile("stdlib.tar", [
    TarWriteEntry {
      name: "modules/archive.tar.zst",
      data: compressed,
    },
  ])
}

function loadModule(name: string): Result<TarArchive, string> {
  try entries := scanTarFile("stdlib.tar")
  let selected: TarEntry | none = none
  for entry of entries {
    if entry.name == "modules/" + name + ".tar.zst" {
      selected = entry
      break
    }
  }
  entry := selected else {
    return Failure { error: "stdlib module not found: " + name }
  }

  try compressed := readTarEntry("stdlib.tar", entry)
  try moduleTar := zstdDecompress(compressed)
  return readTarBlob(moduleTar)
}
```

The outer TAR must remain uncompressed. Wrapping it in gzip or zstd would make
its uncompressed entry offsets unusable for direct file reads. If consumers
download the bundle remotely, publish an offset/size/hash index and use HTTP
range requests; the local `scanTarFile` API does not perform network I/O.

## Handle entry paths deliberately

`std/archive` parses and creates archives but does not extract entries into the
filesystem. If an application materializes entries, it must define and enforce
its own path policy before writing anything. In particular, reject absolute
paths, parent traversal, platform-specific separators that violate the policy,
and symbolic-link layouts that could escape the destination.

Do not concatenate an untrusted entry name onto an extraction directory and
write it directly. Parsing a valid archive does not imply that its paths are
safe filesystem destinations.

## Know the current boundaries

- ZIP writing and eager reading are in-memory; seekable file scanning and
  selective reads support ZIP32 stored/deflated entries.
- TAR blob and retained-file reads hold the complete TAR in memory.
- Seekable scanning and selective reads support plain local TAR files only.
- TAR supports regular files, directories, symbolic links, ustar, and selected
  PAX metadata.
- Filesystem extraction, streaming TAR input, hard links, devices, FIFOs,
  sparse files, GNU long-name extensions, and base-256 numeric fields are not
  currently supported.
- Zstandard decompression is currently one-shot, so a selected `.tar.zst`
  member is fully decompressed before its inner TAR is parsed.

Run the archive module tests with:

```bash
doof test archive
```
