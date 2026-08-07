import {
  ArchiveEntryKind, TarEntryKind, TarWriteEntry, ZipCompression, ZipEntry, crc32, deflate,
  inflate, readTarBlob, readTarFile, readZip, writeTarBlob, writeTarFile, writeZip,
} from "../index"
import { BlobBuilder } from "std/blob"
import { readBlob, remove } from "std/fs"
import { join, tempDirectory } from "std/path"
import { Instant } from "std/time"

function bytes(text: string): readonly byte[] {
  builder := BlobBuilder()
  builder.writeString(text)
  return builder.build()
}

function assertBytes(actual: readonly byte[], expected: readonly byte[]): none {
  assert(actual.length == expected.length, "expected byte lengths to match")
  for index of 0..<actual.length {
    assert(actual[index] == expected[index], "expected bytes to match")
  }
}

function failureMessage<T>(result: Result<T, string>): string {
  return case result {
    _: Success -> "",
    failure: Failure -> failure.error,
  }
}

function repeatText(value: string, count: int): string {
  let result = ""
  for index of 0..<count {
    result = result + value
  }
  return result
}

function replaceByte(data: readonly byte[], offset: int, value: byte): readonly byte[] {
  builder := BlobBuilder()
  builder.writeBytes(data)
  builder.setPosition(long(offset))
  builder.writeByte(value)
  return builder.build()
}

function octal(value: long): string {
  if value == 0L { return "0" }
  let remaining = value
  let result = ""
  while remaining > 0L {
    result = string(remaining % 8L) + result
    remaining = remaining \ 8L
  }
  return result
}

function patchFirstHeaderType(data: readonly byte[], typeFlag: byte): readonly byte[] {
  builder := BlobBuilder()
  builder.writeBytes(data)
  builder.setPosition(156L)
  builder.writeByte(typeFlag)
  builder.setPosition(148L)
  builder.writeString("        ")
  provisional := builder.build()

  let checksum = 0L
  for index of 0..<512 {
    checksum = checksum + long(provisional[index])
  }
  digits := octal(checksum)
  let padded = digits
  while padded.length < 6 { padded = "0" + padded }

  patched := BlobBuilder()
  patched.writeBytes(provisional)
  patched.setPosition(148L)
  patched.writeString(padded)
  patched.writeByte(0)
  patched.writeByte(32)
  return patched.build()
}

function replaceFirstPaxPathKey(data: readonly byte[]): readonly byte[] {
  for index of 512..<1020 {
    if data[index] == 112 && data[index + 1] == 97 && data[index + 2] == 116 &&
       data[index + 3] == 104 && data[index + 4] == 61 {
      let replaced = replaceByte(data, index, 110)
      replaced = replaceByte(replaced, index + 1, 111)
      replaced = replaceByte(replaced, index + 2, 112)
      return replaceByte(replaced, index + 3, 101)
    }
  }
  assert(false, "expected PAX path key")
  return data
}

function patchHeaderSize(data: readonly byte[], headerOffset: int, size: long): readonly byte[] {
  digits := octal(size)
  let padded = digits
  while padded.length < 11 { padded = "0" + padded }

  builder := BlobBuilder()
  builder.writeBytes(data)
  builder.setPosition(long(headerOffset + 124))
  builder.writeString(padded)
  builder.writeByte(0)
  builder.setPosition(long(headerOffset + 148))
  builder.writeString("        ")
  provisional := builder.build()

  let checksum = 0L
  for index of headerOffset..<headerOffset + 512 {
    checksum = checksum + long(provisional[index])
  }
  checksumDigits := octal(checksum)
  let checksumPadded = checksumDigits
  while checksumPadded.length < 6 { checksumPadded = "0" + checksumPadded }

  patched := BlobBuilder()
  patched.writeBytes(provisional)
  patched.setPosition(long(headerOffset + 148))
  patched.writeString(checksumPadded)
  patched.writeByte(0)
  patched.writeByte(32)
  return patched.build()
}

function encodeLength(value: string): int {
  builder := BlobBuilder()
  builder.writeString(value)
  return builder.build().length
}

function paxRecordText(key: string, value: string): string {
  body := key + "=" + value + "\n"
  let length = encodeLength("0 " + body)
  while true {
    record := string(length) + " " + body
    actualLength := encodeLength(record)
    if actualLength == length { return record }
    length = actualLength
  }
}

function paxSizePayload(totalLength: int, size: int): readonly byte[] {
  sizeRecord := paxRecordText("size", string(size))
  remaining := totalLength - encodeLength(sizeRecord)
  fillerLength := remaining - string(remaining).length - 4
  fillerRecord := string(remaining) + " x=" + repeatText("z", fillerLength) + "\n"
  builder := BlobBuilder()
  builder.writeString(sizeRecord)
  builder.writeString(fillerRecord)
  payload := builder.build()
  assert(payload.length == totalLength, "expected replacement PAX payload length")
  return payload
}

export function testRawDeflateRoundTrips(): none {
  input := bytes("hello raw deflate\nhello raw deflate\n")
  compressed := deflate(input)
  inflated := try! inflate(compressed)

  assert(compressed.length > 0, "expected deflate to produce output")
  assertBytes(inflated, input)
}

export function testWriteAndReadZipArchive(): none {
  payload := bytes("hello zip\nhello zip\n")
  archive := writeZip([
    ZipEntry {
      name: "docs/",
      kind: .Directory,
      compression: .Store,
    },
    ZipEntry {
      name: "docs/hello.txt",
      data: payload,
      compression: .Deflate,
    },
    ZipEntry {
      name: "stored.txt",
      data: bytes("stored"),
      compression: .Store,
    },
  ])

  entries := try! readZip(archive)
  assert(entries.length == 3, "expected zip entry count")
  assert(entries[0].name == "docs/", "expected directory name")
  assert(entries[0].kind == ArchiveEntryKind.Directory, "expected directory kind")
  assert(entries[1].name == "docs/hello.txt", "expected file name")
  assert(entries[1].compression == ZipCompression.Deflate, "expected deflate compression")
  assert(entries[1].size == long(payload.length), "expected original size")
  assert(entries[1].crc32 == crc32(payload), "expected crc32")
  assertBytes(entries[1].data, payload)
  assertBytes(entries[2].data, bytes("stored"))
}

export function testReadZipRejectsInvalidInput() {
  invalid := readZip(bytes("not a zip"))
  assert(invalid.isFailure(), "expected invalid zip input to fail")
}

export function testTarBlobRoundTripsWithoutEagerPayloadCopies(): none {
  emptyArchive := try! readTarBlob(writeTarBlob([]))
  assert(emptyArchive.entries.length == 0, "expected empty TAR archive")

  payload := bytes("hello tar")
  archiveBytes := writeTarBlob([
    TarWriteEntry { name: "docs/", kind: .Directory },
    TarWriteEntry {
      name: "docs/hello.txt",
      data: payload,
      mode: 493,
      mtime: Instant.ofEpochSeconds(1234L),
    },
    TarWriteEntry { name: "empty.txt" },
    TarWriteEntry { name: "docs/hello.txt", data: bytes("duplicate") },
  ])

  archive := try! readTarBlob(archiveBytes)
  assert(archive.data.length == archiveBytes.length, "expected retained tar blob")
  assert(archive.entries.length == 4, "expected tar entry count")
  assert(archive.entries[0].kind == TarEntryKind.Directory, "expected tar directory")
  assert(archive.entries[0].mode == 493, "expected default tar directory mode")
  assert(archive.entries[0].mtime.equals(Instant.EPOCH), "expected default tar directory mtime")
  assert(archive.entries[0].size == 0L, "expected empty directory payload")
  assert(archive.entries[1].name == "docs/hello.txt", "expected tar file name")
  assert(archive.entries[1].contentOffset == 1024L, "expected content span after directory and file headers")
  assert(archive.entries[1].size == long(payload.length), "expected tar content size")
  assert(archive.entries[1].mode == 493, "expected explicit tar file mode")
  assert(archive.entries[1].mtime.equals(Instant.ofEpochSeconds(1234L)), "expected explicit tar file mtime")
  assertBytes(archive.entryData(archive.entries[1]), payload)
  assertBytes(archive.entryData(archive.entries[2]), [])
  assertBytes(archive.entryData(archive.entries[3]), bytes("duplicate"))
  assert(archiveBytes.length % 512 == 0, "expected block-aligned tar output")
  for index of archiveBytes.length - 1024..<archiveBytes.length {
    assert(archiveBytes[index] == 0, "expected two zero terminator blocks")
  }
}

export function testTarModeAndPaxMtimeRoundTrip(): none {
  fractional := Instant.ofEpochNanos(1234567890123L)
  beforeEpoch := Instant.ofEpochNanos(-1500000000L)
  archive := try! readTarBlob(writeTarBlob([
    TarWriteEntry { name: "fractional", mode: 448, mtime: fractional },
    TarWriteEntry { name: "before-epoch", mtime: beforeEpoch },
  ]))

  assert(archive.entries[0].mode == 448, "expected explicit tar mode")
  assert(archive.entries[0].mtime.equals(fractional), "expected fractional PAX mtime")
  assert(archive.entries[1].mtime.equals(beforeEpoch), "expected pre-epoch PAX mtime")
}

export function testTarPaxPathsAndGlobalLocalPrecedence(): none {
  longPath := "root/" + repeatText("segment/", 20) + "héllo.txt"
  localPath := "local/" + repeatText("nested/", 20) + "válue.txt"
  payload := bytes("pax payload")

  longArchive := writeTarBlob([TarWriteEntry { name: longPath, data: payload }])
  parsedLong := try! readTarBlob(longArchive)
  assert(parsedLong.entries.length == 1, "expected PAX metadata to stay internal")
  assert(parsedLong.entries[0].name == longPath, "expected PAX UTF-8 path")
  assert(parsedLong.entries[0].contentOffset == 1536L, "expected payload after PAX metadata and file header")
  assertBytes(parsedLong.entryData(parsedLong.entries[0]), payload)

  localArchive := writeTarBlob([TarWriteEntry { name: localPath, data: payload }])
  globalPrefix := patchFirstHeaderType(longArchive.slice(0, 1024), 103)
  combined := BlobBuilder()
  combined.writeBytes(globalPrefix)
  combined.writeBytes(localArchive)
  parsedCombined := try! readTarBlob(combined.build())
  assert(parsedCombined.entries.length == 1, "expected global and local PAX headers to stay internal")
  assert(parsedCombined.entries[0].name == localPath, "expected local PAX path to override global path")

  unknownKey := replaceFirstPaxPathKey(longArchive)
  parsedUnknown := try! readTarBlob(unknownKey)
  assert(parsedUnknown.entries[0].name == "PaxEntry/0", "expected unknown PAX keys to be ignored")

  let paxPayloadLength = 0
  while longArchive[512 + paxPayloadLength] != 10 {
    paxPayloadLength = paxPayloadLength + 1
  }
  paxPayloadLength = paxPayloadLength + 1
  sizePayload := paxSizePayload(paxPayloadLength, payload.length)
  replacedPayload := BlobBuilder()
  replacedPayload.writeBytes(longArchive)
  replacedPayload.setPosition(512L)
  replacedPayload.writeBytes(sizePayload)
  sizeOverrideArchive := patchHeaderSize(replacedPayload.build(), 1024, 0L)
  parsedSizeOverride := try! readTarBlob(sizeOverrideArchive)
  assert(parsedSizeOverride.entries[0].size == long(payload.length), "expected PAX size to override base header")
  assertBytes(parsedSizeOverride.entryData(parsedSizeOverride.entries[0]), payload)
}

export function testTarFileEntryPointsMatchBlobEntryPoints(): none {
  path := join([tempDirectory(), "std-archive-tar-round-trip.tar"])
  gzipPath := join([tempDirectory(), "std-archive-tar-round-trip.tar.gz"])
  entries := readonly [
    TarWriteEntry { name: "alpha.txt", data: bytes("alpha") },
    TarWriteEntry { name: "aligned.bin", data: writeTarBlob([]).slice(0, 512) },
  ]
  expected := writeTarBlob(entries)
  try! writeTarFile(path, entries)
  assertBytes(try! readBlob(path), expected)
  fromFile := try! readTarFile(path)
  assert(fromFile.entries.length == 2, "expected direct file TAR entries")
  assertBytes(fromFile.entryData(fromFile.entries[0]), bytes("alpha"))
  try! remove(path)

  try! writeTarFile(gzipPath, entries)
  compressed := try! readBlob(gzipPath)
  assert(compressed.length > 2 && compressed[0] == 31 && compressed[1] == 139, "expected .tar.gz gzip header")
  fromGzipFile := try! readTarFile(gzipPath)
  assert(fromGzipFile.entries.length == 2, "expected .tar.gz entries")
  assertBytes(fromGzipFile.entryData(fromGzipFile.entries[0]), bytes("alpha"))
  assertBytes(fromGzipFile.entryData(fromGzipFile.entries[1]), entries[1].data)
  try! remove(gzipPath)

  try! writeTarFile("build/tar-interop.tar", readonly [
    TarWriteEntry { name: "interop/", kind: .Directory },
    TarWriteEntry { name: "interop/" + repeatText("long/", 25) + "héllo.txt", data: bytes("from doof") },
  ])

  readFailure := readTarFile(join([tempDirectory(), "std-archive-missing.tar"]))
  assert(readFailure.isFailure(), "expected missing TAR file read to fail")
  assert(failureMessage(readFailure).contains("tar file read failed"), "expected contextual TAR file read error")
  writeFailure := writeTarFile(tempDirectory(), entries)
  assert(writeFailure.isFailure(), "expected writing TAR to a directory to fail")
  assert(failureMessage(writeFailure).contains("tar file write failed"), "expected contextual TAR file write error")
}

export function testTarRejectsMalformedAndUnsupportedArchives(): none {
  valid := writeTarBlob([TarWriteEntry { name: "file.txt", data: bytes("payload") }])

  badChecksum := replaceByte(valid, 0, 120)
  assert(readTarBlob(badChecksum).isFailure(), "expected bad TAR checksum to fail")

  badSize := replaceByte(valid, 124, 57)
  assert(readTarBlob(badSize).isFailure(), "expected invalid TAR octal size to fail")

  truncated := valid.slice(0, valid.length - 1)
  assert(readTarBlob(truncated).isFailure(), "expected truncated TAR to fail")

  oneTerminator := valid.slice(0, valid.length - 512)
  assert(readTarBlob(oneTerminator).isFailure(), "expected one TAR terminator block to fail")

  nonZeroTrailing := replaceByte(valid, valid.length - 1, 1)
  assert(readTarBlob(nonZeroTrailing).isFailure(), "expected non-zero TAR trailing data to fail")

  unsupported := patchFirstHeaderType(valid, 50)
  assert(readTarBlob(unsupported).isFailure(), "expected unsupported TAR type to fail")

  longPath := repeatText("long/", 30) + "fíle.txt"
  paxArchive := writeTarBlob([TarWriteEntry { name: longPath, data: bytes("payload") }])
  malformedLength := replaceByte(paxArchive, 512, 32)
  assert(readTarBlob(malformedLength).isFailure(), "expected malformed PAX length to fail")
  invalidUtf8 := replaceByte(paxArchive, 520, 255)
  assert(readTarBlob(invalidUtf8).isFailure(), "expected invalid PAX UTF-8 to fail")
}
