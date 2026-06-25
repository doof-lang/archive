export import function deflate(data: readonly byte[]): readonly byte[] from "native_archive.hpp" as doof_archive::deflateRaw
export import function inflate(data: readonly byte[]): Result<readonly byte[], string> from "native_archive.hpp" as doof_archive::inflateRaw
export import function crc32(data: readonly byte[]): long from "native_archive.hpp" as doof_archive::crc32Bytes
