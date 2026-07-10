#pragma once

#include "doof_runtime.hpp"

#include <array>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <string>
#include <vector>
#include <zlib.h>

namespace doof_archive {

inline std::shared_ptr<std::vector<uint8_t>> safeBytes(const std::shared_ptr<std::vector<uint8_t>>& data) {
    return data ? data : std::make_shared<std::vector<uint8_t>>();
}

inline doof::Result<std::shared_ptr<std::vector<uint8_t>>, std::string> zlibError(
    const char* operation,
    int code,
    const z_stream& stream
) {
    std::string message = std::string("deflate ") + operation + " failed";
    if (stream.msg != nullptr) {
        message += ": ";
        message += stream.msg;
    } else {
        message += " with zlib code ";
        message += std::to_string(code);
    }
    return doof::Failure<std::string>{message};
}

inline std::shared_ptr<std::vector<uint8_t>> deflateRaw(const std::shared_ptr<std::vector<uint8_t>>& data) {
    auto input = safeBytes(data);
    z_stream stream {};
    const int initialized = deflateInit2(
        &stream,
        Z_DEFAULT_COMPRESSION,
        Z_DEFLATED,
        -MAX_WBITS,
        8,
        Z_DEFAULT_STRATEGY
    );
    if (initialized != Z_OK) {
        doof::panic("deflate initialize failed with zlib code " + std::to_string(initialized));
    }

    struct DeflateEnd {
        z_stream* stream;
        ~DeflateEnd() { deflateEnd(stream); }
    } cleanup { &stream };

    stream.next_in = input->empty() ? nullptr : const_cast<Bytef*>(reinterpret_cast<const Bytef*>(input->data()));
    stream.avail_in = static_cast<uInt>(std::min(input->size(), static_cast<size_t>(std::numeric_limits<uInt>::max())));

    auto output = std::make_shared<std::vector<uint8_t>>();
    std::array<uint8_t, 65536> buffer {};

    while (true) {
        stream.next_out = buffer.data();
        stream.avail_out = static_cast<uInt>(buffer.size());

        const int result = deflate(&stream, Z_FINISH);
        const size_t produced = buffer.size() - static_cast<size_t>(stream.avail_out);
        output->insert(output->end(), buffer.begin(), buffer.begin() + static_cast<std::ptrdiff_t>(produced));

        if (result == Z_STREAM_END) {
            return output;
        }
        if (result != Z_OK) {
            doof::panic("deflate failed with zlib code " + std::to_string(result));
        }
    }
}

inline doof::Result<std::shared_ptr<std::vector<uint8_t>>, std::string> inflateRaw(
    const std::shared_ptr<std::vector<uint8_t>>& data
) {
    auto input = safeBytes(data);
    z_stream stream {};
    const int initialized = inflateInit2(&stream, -MAX_WBITS);
    if (initialized != Z_OK) {
        return doof::Failure<std::string>{"inflate initialize failed with zlib code " + std::to_string(initialized)};
    }

    struct InflateEnd {
        z_stream* stream;
        ~InflateEnd() { inflateEnd(stream); }
    } cleanup { &stream };

    stream.next_in = input->empty() ? nullptr : const_cast<Bytef*>(reinterpret_cast<const Bytef*>(input->data()));
    stream.avail_in = static_cast<uInt>(std::min(input->size(), static_cast<size_t>(std::numeric_limits<uInt>::max())));

    auto output = std::make_shared<std::vector<uint8_t>>();
    std::array<uint8_t, 65536> buffer {};

    while (true) {
        stream.next_out = buffer.data();
        stream.avail_out = static_cast<uInt>(buffer.size());

        const int result = inflate(&stream, Z_NO_FLUSH);
        const size_t produced = buffer.size() - static_cast<size_t>(stream.avail_out);
        output->insert(output->end(), buffer.begin(), buffer.begin() + static_cast<std::ptrdiff_t>(produced));

        if (result == Z_STREAM_END) {
            return doof::Success<std::shared_ptr<std::vector<uint8_t>>>{output};
        }
        if (result != Z_OK) {
            std::string message = "inflate failed";
            if (stream.msg != nullptr) {
                message += ": ";
                message += stream.msg;
            } else {
                message += " with zlib code ";
                message += std::to_string(result);
            }
            return doof::Failure<std::string>{message};
        }
        if (stream.avail_in == 0 && produced == 0) {
            return doof::Failure<std::string>{"inflate failed: truncated input"};
        }
    }
}

inline int64_t crc32Bytes(const std::shared_ptr<std::vector<uint8_t>>& data) {
    auto input = safeBytes(data);
    uLong crc = ::crc32(0L, Z_NULL, 0);
    crc = ::crc32(
        crc,
        input->empty() ? nullptr : reinterpret_cast<const Bytef*>(input->data()),
        static_cast<uInt>(std::min(input->size(), static_cast<size_t>(std::numeric_limits<uInt>::max())))
    );
    return static_cast<int64_t>(crc);
}

}  // namespace doof_archive
