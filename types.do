import { Instant } from "std/time"

export enum ArchiveEntryKind {
  File = 0,
  Directory = 1,
}

export enum TarEntryKind {
  File = 0,
  Directory = 1,
}

export enum ZipCompression {
  Store = 0,
  Deflate = 8,
}

export class ZipEntry {
  name: string
  kind: ArchiveEntryKind = .File
  size: long = 0L
  compressedSize: long = 0L
  crc32: long = 0L
  compression: ZipCompression = .Deflate
  data: readonly byte[] = []
}

export class CentralDirectoryEntry {
  name: string
  kind: ArchiveEntryKind
  size: long
  compressedSize: long
  crc32: long
  compression: ZipCompression
  localHeaderOffset: long
}

export class TarEntry {
  readonly name: string
  readonly kind: TarEntryKind
  readonly contentOffset: long
  readonly size: long
  readonly mode: int
  readonly mtime: Instant
}

export class TarArchive {
  readonly data: readonly byte[]
  readonly entries: readonly TarEntry[]

  entryData(entry: TarEntry): readonly byte[] {
    return this.data.slice(int(entry.contentOffset), int(entry.contentOffset + entry.size))
  }
}

export class TarWriteEntry {
  readonly name: string
  readonly kind: TarEntryKind = .File
  readonly data: readonly byte[] = []
  readonly mode: int | none = none
  readonly mtime: Instant = Instant.EPOCH
}
