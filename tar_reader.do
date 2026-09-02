import { decodeUtf8 } from "std/blob"
import { IoError, readBlob } from "std/fs"
import { gunzip } from "std/gzip"
import { Instant } from "std/time"
import { TarArchive, TarEntry, TarEntryKind } from "./types"

readonly TAR_BLOCK_SIZE = 512L
readonly TAR_NAME_OFFSET = 0L
readonly TAR_NAME_LENGTH = 100L
readonly TAR_MODE_OFFSET = 100L
readonly TAR_MODE_LENGTH = 8L
readonly TAR_SIZE_OFFSET = 124L
readonly TAR_SIZE_LENGTH = 12L
readonly TAR_MTIME_OFFSET = 136L
readonly TAR_MTIME_LENGTH = 12L
readonly TAR_CHECKSUM_OFFSET = 148L
readonly TAR_CHECKSUM_LENGTH = 8L
readonly TAR_TYPE_OFFSET = 156L
readonly TAR_LINK_NAME_OFFSET = 157L
readonly TAR_LINK_NAME_LENGTH = 100L
readonly TAR_MAGIC_OFFSET = 257L
readonly TAR_PREFIX_OFFSET = 345L
readonly TAR_PREFIX_LENGTH = 155L

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
    IoError.Unsupported -> "unsupported operation",
  }
}

function isGzipTarPath(path: string): bool {
  return path.length >= 7 && path.slice(path.length - 7) == ".tar.gz"
}

export function isZeroRange(data: readonly byte[], offset: long, length: long): bool {
  if offset < 0L || length < 0L || offset > long(data.length) || length > long(data.length) - offset {
    return false
  }
  let index = offset
  while index < offset + length {
    if data[int(index)] != 0 {
      return false
    }
    index = index + 1L
  }
  return true
}

function fieldEnd(data: readonly byte[], offset: long, length: long): long {
  let index = offset
  while index < offset + length {
    if data[int(index)] == 0 {
      return index
    }
    index = index + 1L
  }
  return offset + length
}

export function readTextField(data: readonly byte[], offset: long, length: long, context: string): Result<string, string> {
  end := fieldEnd(data, offset, length)
  bytes := data.slice(int(offset), int(end))
  decoded := decodeUtf8(bytes) else {
    return Failure { error: "tar read failed: invalid UTF-8 in " + context }
  }
  return Success(decoded)
}

export function parseOctalField(data: readonly byte[], offset: long, length: long, context: string): Result<long, string> {
  let value = 0L
  let sawDigit = false
  let ended = false

  let index = offset
  while index < offset + length {
    character := data[int(index)]
    if character == 0 || character == 32 {
      if sawDigit {
        ended = true
      }
      index = index + 1L
      continue
    }
    if ended || character < 48 || character > 55 {
      return Failure { error: "tar read failed: invalid octal " + context }
    }
    digit := long(character - 48)
    if value > (9223372036854775807L - digit) \ 8L {
      return Failure { error: "tar read failed: overflowing octal " + context }
    }
    value = value * 8L + digit
    sawDigit = true
    index = index + 1L
  }

  if !sawDigit {
    return Success(0L)
  }
  return Success(value)
}

function headerChecksum(data: readonly byte[], offset: long): long {
  let sum = 0L
  let relative = 0L
  while relative < TAR_BLOCK_SIZE {
    if relative >= TAR_CHECKSUM_OFFSET && relative < TAR_CHECKSUM_OFFSET + TAR_CHECKSUM_LENGTH {
      sum = sum + 32L
    } else {
      sum = sum + long(data[int(offset + relative)])
    }
    relative = relative + 1L
  }
  return sum
}

export function validateHeader(data: readonly byte[], offset: long): Result<none, string> {
  try storedChecksum := parseOctalField(data, offset + TAR_CHECKSUM_OFFSET, TAR_CHECKSUM_LENGTH, "checksum")
  if storedChecksum != headerChecksum(data, offset) {
    return Failure { error: "tar read failed: header checksum mismatch" }
  }

  if data[int(offset + TAR_MAGIC_OFFSET)] != 117 ||
     data[int(offset + TAR_MAGIC_OFFSET + 1L)] != 115 ||
     data[int(offset + TAR_MAGIC_OFFSET + 2L)] != 116 ||
     data[int(offset + TAR_MAGIC_OFFSET + 3L)] != 97 ||
     data[int(offset + TAR_MAGIC_OFFSET + 4L)] != 114 ||
     data[int(offset + TAR_MAGIC_OFFSET + 5L)] != 0 {
    return Failure { error: "tar read failed: unsupported header format" }
  }
  return Success()
}

export function readHeaderName(data: readonly byte[], offset: long): Result<string, string> {
  try name := readTextField(data, offset + TAR_NAME_OFFSET, TAR_NAME_LENGTH, "entry name")
  try prefix := readTextField(data, offset + TAR_PREFIX_OFFSET, TAR_PREFIX_LENGTH, "entry prefix")
  if prefix.length > 0 && name.length > 0 {
    return Success(prefix + "/" + name)
  }
  if prefix.length > 0 {
    return Success(prefix)
  }
  return Success(name)
}

export function parseDecimal(value: string, context: string): Result<long, string> {
  if value.length == 0 {
    return Failure { error: "tar read failed: empty PAX " + context }
  }
  let result = 0L
  for index of 0..<value.length {
    character := value.charAt(index)
    if character < '0' || character > '9' {
      return Failure { error: "tar read failed: invalid PAX " + context }
    }
    digit := long(int(character) - int('0'))
    if result > (9223372036854775807L - digit) \ 10L {
      return Failure { error: "tar read failed: overflowing PAX " + context }
    }
    result = result * 10L + digit
  }
  return Success(result)
}

export function parsePaxMtime(value: string): Result<Instant, string> {
  if value.length == 0 {
    return Failure { error: "tar read failed: empty PAX mtime" }
  }

  let negative = false
  let start = 0
  first := value.charAt(0)
  if first == '-' || first == '+' {
    negative = first == '-'
    start = 1
  }

  let decimal = value.indexOf(".")
  if decimal < 0 {
    decimal = value.length
  }
  if start >= value.length || decimal == start {
    return Failure { error: "tar read failed: invalid PAX mtime" }
  }

  try seconds := parseDecimal(value.substring(start, decimal), "mtime")
  let nanos = 0L
  if decimal < value.length {
    fraction := value.slice(decimal + 1)
    if fraction.length == 0 || fraction.length > 9 {
      return Failure { error: "tar read failed: unsupported PAX mtime precision" }
    }
    try fractionValue := parseDecimal(fraction, "mtime fraction")
    nanos = fractionValue
    let fractionDigits = fraction.length
    while fractionDigits < 9 {
      nanos = nanos * 10L
      fractionDigits = fractionDigits + 1
    }
  }

  if seconds > 9223372036L ||
     (seconds == 9223372036L && nanos > 854775807L) {
    return Failure { error: "tar read failed: PAX mtime is out of range" }
  }
  magnitude := seconds * 1000000000L + nanos
  epochNanos := if negative then -magnitude else magnitude
  return Success(Instant.ofEpochNanos(epochNanos))
}

export function parsePaxRecords(
  data: readonly byte[],
  offset: long,
  size: long,
  values: Map<string, string>,
): Result<none, string> {
  end := offset + size
  let position = offset

  while position < end {
    let lengthEnd = position
    while lengthEnd < end && data[int(lengthEnd)] != 32 {
      character := data[int(lengthEnd)]
      if character < 48 || character > 57 {
        return Failure { error: "tar read failed: invalid PAX record length" }
      }
      lengthEnd = lengthEnd + 1L
    }
    if lengthEnd == position || lengthEnd >= end {
      return Failure { error: "tar read failed: invalid PAX record length" }
    }

    try lengthText := readTextField(data, position, lengthEnd - position, "PAX record length")
    try recordLength := parseDecimal(lengthText, "record length")
    if recordLength <= lengthEnd - position + 2L || recordLength > end - position {
      return Failure { error: "tar read failed: invalid PAX record bounds" }
    }
    recordEnd := position + recordLength
    if data[int(recordEnd - 1L)] != 10 {
      return Failure { error: "tar read failed: PAX record is missing newline" }
    }

    contentStart := lengthEnd + 1L
    let equals = contentStart
    while equals < recordEnd - 1L && data[int(equals)] != 61 {
      equals = equals + 1L
    }
    if equals == contentStart || equals >= recordEnd - 1L {
      return Failure { error: "tar read failed: invalid PAX key/value record" }
    }

    keyBytes := data.slice(int(contentStart), int(equals))
    valueBytes := data.slice(int(equals + 1L), int(recordEnd - 1L))
    key := decodeUtf8(keyBytes) else {
      return Failure { error: "tar read failed: invalid UTF-8 in PAX key" }
    }
    value := decodeUtf8(valueBytes) else {
      return Failure { error: "tar read failed: invalid UTF-8 in PAX value" }
    }
    values.set(key, value)
    position = recordEnd
  }
  return Success()
}

export function paxValue(local: Map<string, string>, global: Map<string, string>, key: string): string | none {
  return case local.get(key) {
    found: Success -> found.value,
    _: Failure -> case global.get(key) {
      found: Success -> found.value,
      _: Failure -> none,
    },
  }
}

export function alignedPayloadEnd(contentOffset: long, size: long, dataLength: long): Result<long, string> {
  if size < 0L || contentOffset < 0L || contentOffset > dataLength || size > dataLength - contentOffset {
    return Failure { error: "tar read failed: truncated entry payload" }
  }
  payloadEnd := contentOffset + size
  padding := (TAR_BLOCK_SIZE - (size % TAR_BLOCK_SIZE)) % TAR_BLOCK_SIZE
  if padding > dataLength - payloadEnd {
    return Failure { error: "tar read failed: truncated entry padding" }
  }
  return Success(payloadEnd + padding)
}

export function readTarBlob(data: readonly byte[]): Result<TarArchive, string> {
  if long(data.length) < TAR_BLOCK_SIZE * 2L || long(data.length) % TAR_BLOCK_SIZE != 0L {
    return Failure { error: "tar read failed: archive must contain complete 512-byte blocks" }
  }

  let offset = 0L
  let entries: TarEntry[] = []
  globalPax: Map<string, string> := {}
  let localPax: Map<string, string> = {}

  while offset + TAR_BLOCK_SIZE <= long(data.length) {
    if isZeroRange(data, offset, TAR_BLOCK_SIZE) {
      if offset + TAR_BLOCK_SIZE * 2L > long(data.length) || !isZeroRange(data, offset + TAR_BLOCK_SIZE, TAR_BLOCK_SIZE) {
        return Failure { error: "tar read failed: archive terminator requires two zero blocks" }
      }
      if !isZeroRange(data, offset + TAR_BLOCK_SIZE * 2L, long(data.length) - offset - TAR_BLOCK_SIZE * 2L) {
        return Failure { error: "tar read failed: non-zero data follows archive terminator" }
      }
      return Success(TarArchive { data, entries: entries.drainToReadonly() })
    }

    try validateHeader(data, offset)
    try baseName := readHeaderName(data, offset)
    try baseMode := parseOctalField(data, offset + TAR_MODE_OFFSET, TAR_MODE_LENGTH, "entry mode")
    try baseSize := parseOctalField(data, offset + TAR_SIZE_OFFSET, TAR_SIZE_LENGTH, "entry size")
    try baseMtime := parseOctalField(data, offset + TAR_MTIME_OFFSET, TAR_MTIME_LENGTH, "entry modification time")
    if baseMode > 2147483647L {
      return Failure { error: "tar read failed: entry mode is out of range" }
    }
    if baseMtime > 9223372036L {
      return Failure { error: "tar read failed: entry modification time is out of range" }
    }
    typeFlag := data[int(offset + TAR_TYPE_OFFSET)]
    contentOffset := offset + TAR_BLOCK_SIZE
    try nextOffset := alignedPayloadEnd(contentOffset, baseSize, long(data.length))

    if typeFlag == 120 || typeFlag == 103 {
      target := if typeFlag == 103 then globalPax else localPax
      try parsePaxRecords(data, contentOffset, baseSize, target)
      offset = nextOffset
      continue
    }

    pathValue := paxValue(localPax, globalPax, "path")
    resolvedName := if pathValue == none then baseName else pathValue!
    try baseLinkName := readTextField(
      data,
      offset + TAR_LINK_NAME_OFFSET,
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
      try updatedOffset := alignedPayloadEnd(contentOffset, resolvedSize, long(data.length))
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

export function readTarFile(path: string): Result<TarArchive, string> {
  bytes := readBlob(path) else error {
    return Failure { error: "tar file read failed: " + ioErrorText(error) }
  }
  if isGzipTarPath(path) {
    decoded := gunzip(bytes) else error {
      return Failure { error: "tar file read failed: " + error }
    }
    return readTarBlob(decoded)
  }
  return readTarBlob(bytes)
}
