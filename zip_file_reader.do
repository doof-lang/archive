import { BlobReader } from "std/blob"
import { ZipFileEntry } from "./types"
import {
  findEndOfCentralDirectory, readCentralDirectoryEntry, readZipDirectoryInfo,
  unpackZipPayload, validateZipPayload, zipPayloadOffset,
} from "./reader"

readonly ZIP_END_SEARCH_SIZE = 65557L
readonly ZIP_LOCAL_HEADER_SIZE = 30L
readonly MAX_BLOB_SIZE = 2147483647L

import class NativeArchiveFile from "native_archive_file.hpp" as doof_archive::NativeArchiveFile {
  isolated static open(path: string): Result<NativeArchiveFile, string>
  isolated size(): long
  isolated read(offset: long, size: long): Result<readonly byte[], string>
}

export function scanZipFile(path: string): Result<readonly ZipFileEntry[], string> {
  file := NativeArchiveFile.open(path) else error {
    return Failure { error: "zip file scan failed: " + error }
  }
  fileSize := file.size()
  if fileSize < 22L {
    return Failure { error: "zip read failed: input is too small" }
  }

  tailSize := if fileSize > ZIP_END_SEARCH_SIZE then ZIP_END_SEARCH_SIZE else fileSize
  tailOffset := fileSize - tailSize
  tail := file.read(tailOffset, tailSize) else error {
    return Failure { error: "zip file scan failed: " + error }
  }
  try eocdOffset := findEndOfCentralDirectory(tail)
  try directory := readZipDirectoryInfo(tail, eocdOffset, tailOffset, fileSize)
  if directory.size > MAX_BLOB_SIZE {
    return Failure { error: "zip file scan failed: central directory is too large" }
  }

  directoryBytes := file.read(directory.offset, directory.size) else error {
    return Failure { error: "zip file scan failed: " + error }
  }
  reader := BlobReader(directoryBytes)
  let entries: ZipFileEntry[] = []
  for index of 0..<directory.entryCount {
    try entry := readCentralDirectoryEntry(reader)
    if entry.localHeaderOffset > fileSize - ZIP_LOCAL_HEADER_SIZE {
      return Failure { error: "zip read failed: local file header is out of bounds for " + entry.name }
    }
    entries.push(entry)
  }
  if reader.getPosition() > directory.size {
    return Failure { error: "zip read failed: central directory entries exceed declared size" }
  }
  return Success(entries.drainToReadonly())
}

export function readZipEntry(path: string, entry: ZipFileEntry): Result<readonly byte[], string> {
  if entry.compressedSize > MAX_BLOB_SIZE || entry.size > MAX_BLOB_SIZE {
    return Failure { error: "zip entry read failed: entry is too large for a byte array" }
  }

  file := NativeArchiveFile.open(path) else error {
    return Failure { error: "zip entry read failed: " + error }
  }
  if entry.localHeaderOffset < 0L || entry.localHeaderOffset > file.size() - ZIP_LOCAL_HEADER_SIZE {
    return Failure { error: "zip entry read failed: local file header is out of bounds" }
  }

  header := file.read(entry.localHeaderOffset, ZIP_LOCAL_HEADER_SIZE) else error {
    return Failure { error: "zip entry read failed: " + error }
  }
  payloadOffset := zipPayloadOffset(header, entry.localHeaderOffset) else error {
    return Failure { error: "zip entry read failed: " + error }
  }
  compressed := file.read(payloadOffset, entry.compressedSize) else error {
    return Failure { error: "zip entry read failed: " + error }
  }
  payload := unpackZipPayload(compressed, entry.compression) else error {
    return Failure { error: "zip entry read failed: " + error }
  }
  _ := validateZipPayload(payload, entry) else error {
    return Failure { error: "zip entry read failed: " + error }
  }
  return Success(payload)
}
