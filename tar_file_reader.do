import { Instant } from "std/time"
import { TarEntry, TarEntryKind } from "./types"
import {
  alignedPayloadEnd, isZeroRange, parseDecimal, parseOctalField, parsePaxMtime,
  parsePaxRecords, paxValue, readHeaderName, readTextField, validateHeader,
} from "./tar_reader"

readonly TAR_BLOCK_SIZE = 512L
readonly TAR_MODE_OFFSET = 100L
readonly TAR_MODE_LENGTH = 8L
readonly TAR_SIZE_OFFSET = 124L
readonly TAR_SIZE_LENGTH = 12L
readonly TAR_MTIME_OFFSET = 136L
readonly TAR_MTIME_LENGTH = 12L
readonly TAR_TYPE_OFFSET = 156L
readonly TAR_LINK_NAME_OFFSET = 157L
readonly TAR_LINK_NAME_LENGTH = 100L
readonly MAX_BLOB_SIZE = 2147483647L

import class NativeArchiveFile from "native_archive_file.hpp" as doof_archive::NativeArchiveFile {
  isolated static open(path: string): Result<NativeArchiveFile, string>
  isolated size(): long
  isolated read(offset: long, size: long): Result<readonly byte[], string>
}

function isGzipTarPath(path: string): bool {
  return path.length >= 7 && path.slice(path.length - 7) == ".tar.gz"
}

function readPaxPayload(file: NativeArchiveFile, offset: long, size: long): Result<readonly byte[], string> {
  if size > MAX_BLOB_SIZE {
    return Failure { error: "tar file scan failed: PAX metadata is too large" }
  }
  return file.read(offset, size)
}

export function scanTarFile(path: string): Result<readonly TarEntry[], string> {
  if isGzipTarPath(path) {
    return Failure { error: "tar file scan failed: compressed TAR files are not seekable" }
  }

  file := NativeArchiveFile.open(path) else error {
    return Failure { error: "tar file scan failed: " + error }
  }
  fileSize := file.size()
  if fileSize < TAR_BLOCK_SIZE * 2L || fileSize % TAR_BLOCK_SIZE != 0L {
    return Failure { error: "tar read failed: archive must contain complete 512-byte blocks" }
  }

  let offset = 0L
  let entries: TarEntry[] = []
  globalPax: Map<string, string> := {}
  let localPax: Map<string, string> = {}

  while offset + TAR_BLOCK_SIZE <= fileSize {
    header := file.read(offset, TAR_BLOCK_SIZE) else error {
      return Failure { error: "tar file scan failed: " + error }
    }

    if isZeroRange(header, 0L, TAR_BLOCK_SIZE) {
      if offset + TAR_BLOCK_SIZE * 2L > fileSize {
        return Failure { error: "tar read failed: archive terminator requires two zero blocks" }
      }
      second := file.read(offset + TAR_BLOCK_SIZE, TAR_BLOCK_SIZE) else error {
        return Failure { error: "tar file scan failed: " + error }
      }
      if !isZeroRange(second, 0L, TAR_BLOCK_SIZE) {
        return Failure { error: "tar read failed: archive terminator requires two zero blocks" }
      }

      let trailingOffset = offset + TAR_BLOCK_SIZE * 2L
      while trailingOffset < fileSize {
        trailing := file.read(trailingOffset, TAR_BLOCK_SIZE) else error {
          return Failure { error: "tar file scan failed: " + error }
        }
        if !isZeroRange(trailing, 0L, TAR_BLOCK_SIZE) {
          return Failure { error: "tar read failed: non-zero data follows archive terminator" }
        }
        trailingOffset = trailingOffset + TAR_BLOCK_SIZE
      }
      return Success(entries.drainToReadonly())
    }

    try validateHeader(header, 0L)
    try baseName := readHeaderName(header, 0L)
    try baseMode := parseOctalField(header, TAR_MODE_OFFSET, TAR_MODE_LENGTH, "entry mode")
    try baseSize := parseOctalField(header, TAR_SIZE_OFFSET, TAR_SIZE_LENGTH, "entry size")
    try baseMtime := parseOctalField(header, TAR_MTIME_OFFSET, TAR_MTIME_LENGTH, "entry modification time")
    if baseMode > 2147483647L {
      return Failure { error: "tar read failed: entry mode is out of range" }
    }
    if baseMtime > 9223372036L {
      return Failure { error: "tar read failed: entry modification time is out of range" }
    }

    typeFlag := header[int(TAR_TYPE_OFFSET)]
    contentOffset := offset + TAR_BLOCK_SIZE
    try nextOffset := alignedPayloadEnd(contentOffset, baseSize, fileSize)

    if typeFlag == 120 || typeFlag == 103 {
      try paxPayload := readPaxPayload(file, contentOffset, baseSize)
      target := if typeFlag == 103 then globalPax else localPax
      try parsePaxRecords(paxPayload, 0L, baseSize, target)
      offset = nextOffset
      continue
    }

    pathValue := paxValue(localPax, globalPax, "path")
    resolvedName := if pathValue == none then baseName else pathValue!
    try baseLinkName := readTextField(
      header,
      TAR_LINK_NAME_OFFSET,
      TAR_LINK_NAME_LENGTH,
      "entry link name",
    )
    linkPathValue := paxValue(localPax, globalPax, "linkpath")
    resolvedLinkName := if linkPathValue == none then baseLinkName else linkPathValue!
    sizeText := paxValue(localPax, globalPax, "size")
    let resolvedSize = baseSize
    if sizeText != none {
      try parsedSize := parseDecimal(sizeText!, "size")
      resolvedSize = parsedSize
    }
    let resolvedNextOffset = nextOffset
    if resolvedSize != baseSize {
      try updatedOffset := alignedPayloadEnd(contentOffset, resolvedSize, fileSize)
      resolvedNextOffset = updatedOffset
    }

    mtimeText := paxValue(localPax, globalPax, "mtime")
    let resolvedMtime = Instant.ofEpochSeconds(baseMtime)
    if mtimeText != none {
      try parsedMtime := parsePaxMtime(mtimeText!)
      resolvedMtime = parsedMtime
    }

    let kind = TarEntryKind.File
    if typeFlag == 53 {
      kind = TarEntryKind.Directory
    } else if typeFlag == 50 {
      kind = TarEntryKind.SymbolicLink
    } else if typeFlag != 0 && typeFlag != 48 {
      return Failure { error: "tar read failed: unsupported entry type " + string(typeFlag) }
    }

    entries.push(TarEntry {
      name: resolvedName,
      kind,
      contentOffset,
      size: resolvedSize,
      mode: int(baseMode),
      mtime: resolvedMtime,
      linkName: resolvedLinkName,
    })
    localPax = {}
    offset = resolvedNextOffset
  }

  return Failure { error: "tar read failed: archive terminator not found" }
}

export function readTarEntry(path: string, entry: TarEntry): Result<readonly byte[], string> {
  if isGzipTarPath(path) {
    return Failure { error: "tar entry read failed: compressed TAR files are not seekable" }
  }
  if entry.size > MAX_BLOB_SIZE {
    return Failure { error: "tar entry read failed: entry is too large for a byte array" }
  }

  file := NativeArchiveFile.open(path) else error {
    return Failure { error: "tar entry read failed: " + error }
  }
  data := file.read(entry.contentOffset, entry.size) else error {
    return Failure { error: "tar entry read failed: " + error }
  }
  return Success(data)
}
