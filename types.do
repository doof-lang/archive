export enum ArchiveEntryKind {
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
