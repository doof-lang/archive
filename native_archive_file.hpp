#pragma once

#include "doof_runtime.hpp"

#include <cstdint>
#include <fstream>
#include <limits>
#include <memory>
#include <string>
#include <vector>

namespace doof_archive {

class NativeArchiveFile {
public:
    static doof::Result<std::shared_ptr<NativeArchiveFile>, std::string> open(const std::string& path) {
        if (path.empty() || path.find('\0') != std::string::npos) {
            return doof::Failure<std::string>{"archive file open failed: invalid path"};
        }

        auto stream = std::make_unique<std::ifstream>(path, std::ios::binary | std::ios::ate);
        if (!stream->is_open()) {
            return doof::Failure<std::string>{"archive file open failed"};
        }

        const std::streampos end = stream->tellg();
        const std::streamoff endOffset = static_cast<std::streamoff>(end);
        if (endOffset < 0 ||
            static_cast<uint64_t>(endOffset) > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
            return doof::Failure<std::string>{"archive file open failed: file size is out of range"};
        }

        stream->seekg(0, std::ios::beg);
        if (!*stream) {
            return doof::Failure<std::string>{"archive file open failed: seek failed"};
        }

        return doof::Success<std::shared_ptr<NativeArchiveFile>>{
            std::shared_ptr<NativeArchiveFile>(new NativeArchiveFile(std::move(stream), static_cast<int64_t>(endOffset)))
        };
    }

    int64_t size() const {
        return size_;
    }

    doof::Result<std::shared_ptr<std::vector<uint8_t>>, std::string> read(
        int64_t offset,
        int64_t size
    ) {
        if (offset < 0 || size < 0 || offset > size_ || size > size_ - offset) {
            return doof::Failure<std::string>{"archive file read failed: byte range is out of bounds"};
        }
        if (static_cast<uint64_t>(size) > static_cast<uint64_t>(std::numeric_limits<size_t>::max()) ||
            static_cast<uint64_t>(size) > static_cast<uint64_t>(std::numeric_limits<std::streamsize>::max())) {
            return doof::Failure<std::string>{"archive file read failed: byte range is too large"};
        }

        auto result = std::make_shared<std::vector<uint8_t>>(static_cast<size_t>(size));
        if (size == 0) {
            return doof::Success<std::shared_ptr<std::vector<uint8_t>>>{result};
        }

        stream_->clear();
        stream_->seekg(static_cast<std::streamoff>(offset), std::ios::beg);
        if (!*stream_) {
            return doof::Failure<std::string>{"archive file read failed: seek failed"};
        }

        stream_->read(reinterpret_cast<char*>(result->data()), static_cast<std::streamsize>(size));
        if (stream_->gcount() != static_cast<std::streamsize>(size)) {
            return doof::Failure<std::string>{"archive file read failed: truncated byte range"};
        }

        return doof::Success<std::shared_ptr<std::vector<uint8_t>>>{result};
    }

private:
    NativeArchiveFile(std::unique_ptr<std::ifstream> stream, int64_t size)
        : stream_(std::move(stream)), size_(size) {}

    std::unique_ptr<std::ifstream> stream_;
    int64_t size_;
};

}  // namespace doof_archive
