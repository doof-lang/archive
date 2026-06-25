import { ArchiveEntryKind, ZipCompression, ZipEntry, crc32, deflate, inflate, readZip, writeZip } from "../index"
import { BlobBuilder } from "std/blob"

function bytes(text: string): readonly byte[] {
  builder := BlobBuilder()
  builder.writeString(text)
  return builder.build()
}

function assertBytes(actual: readonly byte[], expected: readonly byte[]): void {
  assert(actual.length == expected.length, "expected byte lengths to match")
  for index of 0..<actual.length {
    assert(actual[index] == expected[index], "expected bytes to match")
  }
}

export function testRawDeflateRoundTrips(): void {
  input := bytes("hello raw deflate\nhello raw deflate\n")
  compressed := deflate(input)
  inflated := try! inflate(compressed)

  assert(compressed.length > 0, "expected deflate to produce output")
  assertBytes(inflated, input)
}

export function testWriteAndReadZipArchive(): void {
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

export function testReadZipRejectsInvalidInput(): void {
  invalid := readZip(bytes("not a zip"))
  assert(invalid.isFailure(), "expected invalid zip input to fail")
}
