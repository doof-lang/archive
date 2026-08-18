import { BlobBuilder } from "std/blob"
import { IoError, writeBlobStream } from "std/fs"
import { GzipStream } from "std/gzip"
import { Instant } from "std/time"
import { TarEntryKind, TarWriteEntry } from "./types"

readonly TAR_BLOCK_SIZE = 512L
readonly TAR_MAX_BASE_SIZE = 8589934591L

class TarChunk {
  readonly data: readonly byte[]
}

class TarChunkStream implements Stream<readonly byte[]> {
  chunks: TarChunk[]
  let index: int = 0
  let currentValue: readonly byte[] = []

  next(): bool {
    if this.index >= this.chunks.length {
      return false
    }
    this.currentValue = this.chunks[this.index].data
    this.index = this.index + 1
    return true
  }

  value(): readonly byte[] => this.currentValue
}

function ioErrorText(error: IoError): string {
  return case error {
    IoError.NotFound -> "not found",
    IoError.PermissionDenied -> "permission denied",
    IoError.AlreadyExists -> "already exists",
    IoError.IsDirectory -> "is a directory",
    IoError.NotDirectory -> "not a directory",
    IoError.InvalidPath -> "invalid path",
    IoError.Interrupted -> "interrupted",
    IoError.Other -> "other I/O error",
  }
}

function isGzipTarPath(path: string): bool {
  return path.length >= 7 && path.slice(path.length - 7) == ".tar.gz"
}

function encodeText(value: string): readonly byte[] {
  builder := BlobBuilder()
  builder.writeString(value)
  return builder.build()
}

function octal(value: long): string {
  if value == 0L {
    return "0"
  }
  let remaining = value
  let result = ""
  while remaining > 0L {
    result = string(remaining % 8L) + result
    remaining = remaining \ 8L
  }
  return result
}

function writeTextAt(builder: BlobBuilder, offset: long, value: string): none {
  builder.setPosition(offset)
  builder.writeString(value)
}

function writeOctalAt(builder: BlobBuilder, offset: long, width: int, value: long): none {
  digits := octal(value)
  let padded = digits
  while padded.length < width - 1 {
    padded = "0" + padded
  }
  writeTextAt(builder, offset, padded)
  builder.writeByte(0)
}

function patchChecksum(header: readonly byte[]): readonly byte[] {
  let checksum = 0L
  for index of 0..<header.length {
    checksum = checksum + if index >= 148 && index < 156 then 32L else long(header[index])
  }

  builder := BlobBuilder()
  builder.writeBytes(header)
  digits := octal(checksum)
  let padded = digits
  while padded.length < 6 {
    padded = "0" + padded
  }
  writeTextAt(builder, 148L, padded)
  builder.writeByte(0)
  builder.writeByte(32)
  return builder.build()
}

class UstarPath {
  readonly name: string
  readonly prefix: string
}

function ustarPath(path: string): UstarPath | none {
  bytes := encodeText(path)
  for value of bytes {
    if value > 127 {
      return none
    }
  }
  if bytes.length <= 100 {
    return UstarPath { name: path, prefix: "" }
  }

  for distance of 1..<path.length {
    slash := path.length - distance
    if path.charAt(slash) != '/' {
      continue
    }
    prefix := path.substring(0, slash)
    name := path.substring(slash + 1, path.length)
    if name.length > 0 && encodeText(prefix).length <= 155 && encodeText(name).length <= 100 {
      return UstarPath { name, prefix }
    }
  }
  return none
}

function buildHeader(
  path: UstarPath,
  size: long,
  mode: int,
  mtime: Instant,
  typeFlag: byte,
  linkName: string = "",
): readonly byte[] {
  builder := BlobBuilder()
  builder.writeZeroes(TAR_BLOCK_SIZE)
  writeTextAt(builder, 0L, path.name)
  writeOctalAt(builder, 100L, 8, long(mode))
  writeOctalAt(builder, 108L, 8, 0L)
  writeOctalAt(builder, 116L, 8, 0L)
  writeOctalAt(builder, 124L, 12, size)
  writeOctalAt(builder, 136L, 12, mtime.toEpochSeconds())
  writeTextAt(builder, 148L, "        ")
  builder.setPosition(156L)
  builder.writeByte(typeFlag)
  writeTextAt(builder, 157L, linkName)
  writeTextAt(builder, 257L, "ustar")
  builder.setPosition(262L)
  builder.writeByte(0)
  writeTextAt(builder, 263L, "00")
  writeTextAt(builder, 345L, path.prefix)
  return patchChecksum(builder.build())
}

function paxRecord(key: string, value: string): readonly byte[] {
  body := key + "=" + value + "\n"
  let length = encodeText("0 " + body).length
  while true {
    record := string(length) + " " + body
    actualLength := encodeText(record).length
    if actualLength == length {
      return encodeText(record)
    }
    length = actualLength
  }
}

function paxMtime(value: Instant): string {
  nanos := value.toEpochNanos()
  seconds := nanos \ 1000000000L
  let remainder = nanos % 1000000000L
  if remainder == 0L {
    return string(seconds)
  }
  if remainder < 0L {
    remainder = -remainder
  }
  fraction := string(remainder).padStart(9, '0').trimEnd('0')
  if nanos < 0L && seconds == 0L {
    return "-0." + fraction
  }
  return string(seconds) + "." + fraction
}

function padding(size: long): readonly byte[] {
  length := int((TAR_BLOCK_SIZE - (size % TAR_BLOCK_SIZE)) % TAR_BLOCK_SIZE)
  if length == 0 {
    return []
  }
  builder := BlobBuilder()
  builder.writeZeroes(long(length))
  return builder.build()
}

function appendPayload(chunks: TarChunk[], data: readonly byte[]): none {
  if data.length > 0 {
    chunks.push(TarChunk { data })
  }
  paddingBytes := padding(long(data.length))
  if paddingBytes.length > 0 {
    chunks.push(TarChunk { data: paddingBytes })
  }
}

function buildTarChunks(entries: readonly TarWriteEntry[]): TarChunk[] {
  let chunks: TarChunk[] = []

  for index of 0..<entries.length {
    entry := entries[index]
    isDirectory := entry.kind == TarEntryKind.Directory
    isSymbolicLink := entry.kind == TarEntryKind.SymbolicLink
    payload: readonly byte[] := if isDirectory || isSymbolicLink then [] else entry.data
    let mode = if isSymbolicLink then 511 else if isDirectory then 493 else 420
    if entry.mode != none {
      mode = entry.mode!
    }
    directPath := ustarPath(entry.name)
    requiresPaxSize := long(payload.length) > TAR_MAX_BASE_SIZE
    epochNanos := entry.mtime.toEpochNanos()
    epochSeconds := entry.mtime.toEpochSeconds()
    requiresPaxMtime := epochNanos < 0L || epochNanos % 1000000000L != 0L || epochSeconds > TAR_MAX_BASE_SIZE
    linkPath := ustarPath(entry.linkName)
    requiresPaxLinkPath := isSymbolicLink && (linkPath == none || linkPath!.prefix.length > 0)

    let headerPath = directPath
    if directPath == none || requiresPaxSize || requiresPaxMtime || requiresPaxLinkPath {
      let paxPayload: readonly byte[] = []
      paxBuilder := BlobBuilder()
      if directPath == none {
        paxBuilder.writeBytes(paxRecord("path", entry.name))
      }
      if requiresPaxSize {
        paxBuilder.writeBytes(paxRecord("size", string(payload.length)))
      }
      if requiresPaxMtime {
        paxBuilder.writeBytes(paxRecord("mtime", paxMtime(entry.mtime)))
      }
      if requiresPaxLinkPath {
        paxBuilder.writeBytes(paxRecord("linkpath", entry.linkName))
      }
      paxPayload = paxBuilder.build()
      paxName := "PaxHeaders/" + string(index)
      chunks.push(TarChunk {
        data: buildHeader(UstarPath { name: paxName, prefix: "" }, long(paxPayload.length), 420, Instant.EPOCH, 120),
      })
      appendPayload(chunks, paxPayload)
      headerPath = UstarPath { name: "PaxEntry/" + string(index), prefix: "" }
    }

    storedSize := if requiresPaxSize then 0L else long(payload.length)
    storedMtime := if requiresPaxMtime then Instant.EPOCH else entry.mtime
    typeFlag: byte := if isDirectory then 53 else if isSymbolicLink then 50 else 48
    storedLinkName := if isSymbolicLink && !requiresPaxLinkPath then entry.linkName else ""
    chunks.push(TarChunk {
      data: buildHeader(headerPath!, storedSize, mode, storedMtime, typeFlag, storedLinkName),
    })
    appendPayload(chunks, payload)
  }

  terminator := BlobBuilder()
  terminator.writeZeroes(TAR_BLOCK_SIZE * 2L)
  chunks.push(TarChunk { data: terminator.build() })
  return chunks
}

export function writeTarBlob(entries: readonly TarWriteEntry[]): readonly byte[] {
  builder := BlobBuilder()
  for chunk of buildTarChunks(entries) {
    builder.writeBytes(chunk.data)
  }
  return builder.build()
}

export function writeTarFile(path: string, entries: readonly TarWriteEntry[]): Result<none, string> {
  source := TarChunkStream { chunks: buildTarChunks(entries) }
  if isGzipTarPath(path) {
    return case writeBlobStream(path, GzipStream(source)) {
      _: Success -> Success(),
      failure: Failure -> Failure { error: "tar file write failed: " + ioErrorText(failure.error) },
    }
  }
  return case writeBlobStream(path, source) {
    _: Success -> Success(),
    failure: Failure -> Failure { error: "tar file write failed: " + ioErrorText(failure.error) },
  }
}
