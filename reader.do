import { BlobReader } from "std/blob"
import { crc32, inflateRaw as inflate } from "std/gzip"
import { ArchiveEntryKind, ZipCompression, ZipEntry, ZipFileEntry } from "./types"

readonly LOCAL_FILE_HEADER_SIGNATURE = 0x04034b50L
readonly CENTRAL_DIRECTORY_SIGNATURE = 0x02014b50L
readonly END_OF_CENTRAL_DIRECTORY_SIGNATURE = 0x06054b50L

function entryKindForName(name: string): ArchiveEntryKind {
  if name.length > 0 && name.slice(name.length - 1) == "/" {
    return .Directory
  }
  return .File
}

export class ZipDirectoryInfo {
  readonly entryCount: int
  readonly offset: long
  readonly size: long
}

export function requireRemaining(reader: BlobReader, length: long, context: string): Result<none, string> {
  if reader.remaining() < length {
    return Failure { error: "zip read failed: truncated " + context }
  }
  return Success()
}

function readCompression(method: int): Result<ZipCompression, string> {
  if method == ZipCompression.Store.value {
    return Success(ZipCompression.Store)
  }
  if method == ZipCompression.Deflate.value {
    return Success(ZipCompression.Deflate)
  }
  return Failure { error: "zip read failed: unsupported compression method " + string(method) }
}

export function readCentralDirectoryEntry(reader: BlobReader): Result<ZipFileEntry, string> {
  try requireRemaining(reader, 46L, "central directory entry")
  signature := reader.readUnsignedInt()
  if signature != CENTRAL_DIRECTORY_SIGNATURE {
    return Failure { error: "zip read failed: invalid central directory signature" }
  }

  reader.skip(4L)
  flags := reader.readUnsignedShort()
  method := reader.readUnsignedShort()
  reader.skip(4L)
  crc := reader.readUnsignedInt()
  compressedSize := reader.readUnsignedInt()
  size := reader.readUnsignedInt()
  nameLength := reader.readUnsignedShort()
  extraLength := reader.readUnsignedShort()
  commentLength := reader.readUnsignedShort()
  reader.skip(8L)
  localHeaderOffset := reader.readUnsignedInt()

  try requireRemaining(reader, long(nameLength + extraLength + commentLength), "central directory entry payload")
  name := reader.readString(long(nameLength))
  reader.skip(long(extraLength + commentLength))

  if (flags & 8) != 0 {
    return Failure { error: "zip read failed: data descriptors are not supported" }
  }

  try compression := readCompression(method)
  return Success(ZipFileEntry {
    name,
    kind: entryKindForName(name),
    size,
    compressedSize,
    crc32: crc,
    compression,
    localHeaderOffset,
  })
}

export function findEndOfCentralDirectory(data: readonly byte[]): Result<long, string> {
  if data.length < 22 {
    return Failure { error: "zip read failed: input is too small" }
  }

  lastStart := data.length - 22
  lowerBound := if data.length > 65557 then data.length - 65557 else 0
  for distance of 0..<lastStart - lowerBound + 1 {
    index := lastStart - distance
    if data[index] == 0x50 && data[index + 1] == 0x4b && data[index + 2] == 0x05 && data[index + 3] == 0x06 {
      commentLength := int(data[index + 20]) + int(data[index + 21]) * 256
      if index + 22 + commentLength == data.length {
        return Success(long(index))
      }
    }
  }

  return Failure { error: "zip read failed: end of central directory not found" }
}

export function readZipDirectoryInfo(
  data: readonly byte[],
  eocdOffset: long,
  dataOffset: long,
  archiveSize: long,
): Result<ZipDirectoryInfo, string> {
  reader := BlobReader(data)
  reader.setPosition(eocdOffset)
  try requireRemaining(reader, 22L, "end of central directory")

  signature := reader.readUnsignedInt()
  if signature != END_OF_CENTRAL_DIRECTORY_SIGNATURE {
    return Failure { error: "zip read failed: invalid end of central directory signature" }
  }

  diskNumber := reader.readUnsignedShort()
  centralDirectoryDisk := reader.readUnsignedShort()
  diskEntryCount := reader.readUnsignedShort()
  entryCount := reader.readUnsignedShort()
  centralDirectorySize := reader.readUnsignedInt()
  centralDirectoryOffset := reader.readUnsignedInt()
  commentLength := reader.readUnsignedShort()

  if diskNumber != 0 || centralDirectoryDisk != 0 || diskEntryCount != entryCount {
    return Failure { error: "zip read failed: multi-disk archives are not supported" }
  }
  if eocdOffset + 22L + long(commentLength) != long(data.length) ||
     dataOffset + eocdOffset + 22L + long(commentLength) != archiveSize {
    return Failure { error: "zip read failed: truncated archive comment" }
  }

  absoluteEocdOffset := dataOffset + eocdOffset
  if centralDirectoryOffset + centralDirectorySize > absoluteEocdOffset {
    return Failure { error: "zip read failed: central directory is out of bounds" }
  }

  return Success(ZipDirectoryInfo {
    entryCount,
    offset: centralDirectoryOffset,
    size: centralDirectorySize,
  })
}

export function unpackZipPayload(compressed: readonly byte[], compression: ZipCompression): Result<readonly byte[], string> {
  if compression == .Store {
    return Success(compressed)
  }
  return inflate(compressed)
}

export function zipPayloadOffset(header: readonly byte[], localHeaderOffset: long): Result<long, string> {
  reader := BlobReader(header)
  try requireRemaining(reader, 30L, "local file header")

  signature := reader.readUnsignedInt()
  if signature != LOCAL_FILE_HEADER_SIGNATURE {
    return Failure { error: "zip read failed: invalid local file header signature" }
  }

  reader.skip(22L)
  nameLength := reader.readUnsignedShort()
  extraLength := reader.readUnsignedShort()
  return Success(localHeaderOffset + 30L + long(nameLength + extraLength))
}

export function validateZipPayload(payload: readonly byte[], central: ZipFileEntry): Result<none, string> {
  if long(payload.length) != central.size {
    return Failure { error: "zip read failed: uncompressed size mismatch for " + central.name }
  }
  if crc32(payload) != central.crc32 {
    return Failure { error: "zip read failed: crc mismatch for " + central.name }
  }
  return Success()
}

function readEntryPayload(data: readonly byte[], central: ZipFileEntry): Result<ZipEntry, string> {
  if central.localHeaderOffset > long(data.length) - 30L {
    return Failure { error: "zip read failed: truncated local file header" }
  }
  header := data.slice(int(central.localHeaderOffset), int(central.localHeaderOffset + 30L))
  try payloadOffset := zipPayloadOffset(header, central.localHeaderOffset)
  payloadEnd := payloadOffset + central.compressedSize

  if payloadEnd > long(data.length) {
    return Failure { error: "zip read failed: truncated entry payload" }
  }

  compressed := data.slice(int(payloadOffset), int(payloadEnd))
  try payload := unpackZipPayload(compressed, central.compression)
  try validateZipPayload(payload, central)

  return Success(ZipEntry {
    name: central.name,
    kind: central.kind,
    size: central.size,
    compressedSize: central.compressedSize,
    crc32: central.crc32,
    compression: central.compression,
    data: payload,
  })
}

export function readZip(data: readonly byte[]): Result<ZipEntry[], string> {
  try eocdOffset := findEndOfCentralDirectory(data)
  try directory := readZipDirectoryInfo(data, eocdOffset, 0L, long(data.length))

  reader := BlobReader(data)
  reader.setPosition(directory.offset)
  let centralEntries: ZipFileEntry[] = []
  for index of 0..<directory.entryCount {
    try entry := readCentralDirectoryEntry(reader)
    centralEntries.push(entry)
  }
  if reader.getPosition() > directory.offset + directory.size {
    return Failure { error: "zip read failed: central directory entries exceed declared size" }
  }

  let entries: ZipEntry[] = []
  for entry of centralEntries {
    try payload := readEntryPayload(data, entry)
    entries.push(payload)
  }
  return Success(entries)
}
