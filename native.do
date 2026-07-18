export import isolated function deflate(data: readonly byte[]): readonly byte[] from "native_archive.hpp" as doof_archive::deflateRaw
export import isolated function inflate(data: readonly byte[]): Result<readonly byte[], string> from "native_archive.hpp" as doof_archive::inflateRaw
export import isolated function crc32(data: readonly byte[]): long from "native_archive.hpp" as doof_archive::crc32Bytes
