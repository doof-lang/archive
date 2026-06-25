import { BlobBuilder } from "std/blob"
import { crc32, deflate } from "./native"
import { ArchiveEntryKind, ZipCompression, ZipEntry } from "./types"

const LOCAL_FILE_HEADER_SIGNATURE = 0x04034b50L
const CENTRAL_DIRECTORY_SIGNATURE = 0x02014b50L
const END_OF_CENTRAL_DIRECTORY_SIGNATURE = 0x06054b50L
const ZIP_VERSION_NEEDED = 20
const ZIP_VERSION_MADE_BY = 20
const ZIP_UTF8_FLAG = 1 << 11

function encodedName(name: string): readonly byte[] {
  builder := BlobBuilder()
  builder.writeString(name)
  return builder.build()
}

function writeLocalHeader(builder: BlobBuilder, entry: ZipEntry, nameBytes: readonly byte[], compressed: readonly byte[]): void {
  builder.writeUnsignedInt(LOCAL_FILE_HEADER_SIGNATURE)
  builder.writeUnsignedShort(ZIP_VERSION_NEEDED)
  builder.writeUnsignedShort(ZIP_UTF8_FLAG)
  builder.writeUnsignedShort(entry.compression.value)
  builder.writeUnsignedShort(0)
  builder.writeUnsignedShort(0)
  builder.writeUnsignedInt(entry.crc32)
  builder.writeUnsignedInt(long(compressed.length))
  builder.writeUnsignedInt(long(entry.data.length))
  builder.writeUnsignedShort(nameBytes.length)
  builder.writeUnsignedShort(0)
  builder.writeBytes(nameBytes)
}

function writeCentralHeader(builder: BlobBuilder, entry: ZipEntry, nameBytes: readonly byte[], localHeaderOffset: long): void {
  builder.writeUnsignedInt(CENTRAL_DIRECTORY_SIGNATURE)
  builder.writeUnsignedShort(ZIP_VERSION_MADE_BY)
  builder.writeUnsignedShort(ZIP_VERSION_NEEDED)
  builder.writeUnsignedShort(ZIP_UTF8_FLAG)
  builder.writeUnsignedShort(entry.compression.value)
  builder.writeUnsignedShort(0)
  builder.writeUnsignedShort(0)
  builder.writeUnsignedInt(entry.crc32)
  builder.writeUnsignedInt(entry.compressedSize)
  builder.writeUnsignedInt(long(entry.data.length))
  builder.writeUnsignedShort(nameBytes.length)
  builder.writeUnsignedShort(0)
  builder.writeUnsignedShort(0)
  builder.writeUnsignedShort(0)
  builder.writeUnsignedShort(0)
  builder.writeUnsignedInt(0L)
  builder.writeUnsignedInt(localHeaderOffset)
  builder.writeBytes(nameBytes)
}

function compressEntry(entry: ZipEntry): readonly byte[] {
  if entry.kind == .Directory || entry.compression == .Store {
    return entry.data
  }
  return deflate(entry.data)
}

export function writeZip(entries: readonly ZipEntry[]): readonly byte[] {
  builder := BlobBuilder()
  centralBuilder := BlobBuilder()

  for source of entries {
    nameBytes := encodedName(source.name)
    localHeaderOffset := builder.length()
    compressed := compressEntry(source)
    compression: ZipCompression := if source.kind == ArchiveEntryKind.Directory then ZipCompression.Store else source.compression
    entry := ZipEntry {
      name: source.name,
      kind: source.kind,
      size: long(source.data.length),
      compressedSize: long(compressed.length),
      crc32: crc32(source.data),
      compression,
      data: source.data,
    }

    writeLocalHeader(builder, entry, nameBytes, compressed)
    builder.writeBytes(compressed)
    writeCentralHeader(centralBuilder, entry, nameBytes, localHeaderOffset)
  }

  centralDirectory := centralBuilder.build()
  centralDirectoryOffset := builder.length()
  builder.writeBytes(centralDirectory)
  builder.writeUnsignedInt(END_OF_CENTRAL_DIRECTORY_SIGNATURE)
  builder.writeUnsignedShort(0)
  builder.writeUnsignedShort(0)
  builder.writeUnsignedShort(entries.length)
  builder.writeUnsignedShort(entries.length)
  builder.writeUnsignedInt(long(centralDirectory.length))
  builder.writeUnsignedInt(centralDirectoryOffset)
  builder.writeUnsignedShort(0)
  return builder.build()
}
