#include "MSNumpress.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr char PEER_VERSION[] = "0.1.0";
constexpr char MS_NUMPRESS_COMMIT[] = "61acddbce26db586d1cf4e873f2acf225c9d8526";
constexpr std::uint64_t FNV_OFFSET = 14695981039346656037ULL;
constexpr std::uint64_t FNV_PRIME = 1099511628211ULL;

std::uint64_t fnv_bytes(const unsigned char* data, std::size_t size) {
    std::uint64_t result = FNV_OFFSET;
    for (std::size_t i = 0; i < size; ++i) {
        result ^= static_cast<std::uint64_t>(data[i]);
        result *= FNV_PRIME;
    }
    return result;
}

std::uint64_t fnv_values(const std::vector<double>& values) {
    std::uint64_t result = FNV_OFFSET;
    for (double value : values) {
        std::uint64_t bits = 0;
        static_assert(sizeof(bits) == sizeof(value));
        std::memcpy(&bits, &value, sizeof(bits));
        for (unsigned int byte = 0; byte < 8; ++byte) {
            const auto current = static_cast<unsigned char>((bits >> (byte * 8)) & 0xffU);
            result ^= static_cast<std::uint64_t>(current);
            result *= FNV_PRIME;
        }
    }
    return result;
}

struct EncodedData {
    std::vector<unsigned char> encoded;
    std::vector<double> decoded;
};

std::vector<unsigned char> encode_values(
    const std::string& algorithm,
    const std::vector<double>& input) {
    using ms::numpress::MSNumpress::encodeLinear;
    using ms::numpress::MSNumpress::encodePic;
    using ms::numpress::MSNumpress::encodeSlof;

    std::vector<unsigned char> encoded;
    if (algorithm == "linear") {
        if (input.size() < 2) {
            throw "linear requires at least two values";
        }
        const double fixed_point = ms::numpress::MSNumpress::optimalLinearFixedPoint(
            input.data(), input.size());
        encodeLinear(input, encoded, fixed_point);
    } else if (algorithm == "pic") {
        encodePic(input, encoded);
    } else if (algorithm == "slof") {
        const double fixed_point = ms::numpress::MSNumpress::optimalSlofFixedPoint(
            input.data(), input.size());
        encodeSlof(input, encoded, fixed_point);
    } else {
        throw "unknown algorithm; expected linear, pic, or slof";
    }
    return encoded;
}

std::vector<double> decode_values(
    const std::string& algorithm,
    const std::vector<unsigned char>& encoded) {
    using ms::numpress::MSNumpress::decodeLinear;
    using ms::numpress::MSNumpress::decodePic;
    using ms::numpress::MSNumpress::decodeSlof;

    std::vector<double> decoded;
    if (algorithm == "linear") {
        decodeLinear(encoded, decoded);
    } else if (algorithm == "pic") {
        decodePic(encoded, decoded);
    } else if (algorithm == "slof") {
        decodeSlof(encoded, decoded);
    } else {
        throw "unknown algorithm; expected linear, pic, or slof";
    }
    return decoded;
}

EncodedData encode_and_decode(const std::string& algorithm, const std::vector<double>& input) {
    EncodedData result;
    result.encoded = encode_values(algorithm, input);
    result.decoded = decode_values(algorithm, result.encoded);
    return result;
}

std::string encode_hex(const std::vector<unsigned char>& data) {
    constexpr char digits[] = "0123456789abcdef";
    std::string result;
    result.reserve(data.size() * 2);
    for (unsigned char byte : data) {
        result.push_back(digits[byte >> 4]);
        result.push_back(digits[byte & 0x0fU]);
    }
    return result;
}

unsigned int hex_digit(char value) {
    if (value >= '0' && value <= '9') {
        return static_cast<unsigned int>(value - '0');
    }
    if (value >= 'a' && value <= 'f') {
        return static_cast<unsigned int>(value - 'a' + 10);
    }
    if (value >= 'A' && value <= 'F') {
        return static_cast<unsigned int>(value - 'A' + 10);
    }
    throw std::runtime_error("encoded input contains a non-hexadecimal character");
}

std::vector<unsigned char> decode_hex_from_stdin() {
    std::string token;
    std::string hex;
    while (std::cin >> token) {
        hex += token;
    }
    if (hex.empty()) {
        throw std::runtime_error("encoded input is empty");
    }
    if (hex.size() % 2 != 0) {
        throw std::runtime_error("encoded input has an odd number of hexadecimal characters");
    }
    std::vector<unsigned char> result;
    result.reserve(hex.size() / 2);
    for (std::size_t i = 0; i < hex.size(); i += 2) {
        result.push_back(static_cast<unsigned char>((hex_digit(hex[i]) << 4) | hex_digit(hex[i + 1])));
    }
    return result;
}

void print_result(
    const std::string& algorithm,
    const std::vector<double>& input,
    const EncodedData& result) {
    double max_abs_error = 0.0;
    const std::size_t common_size = std::min(input.size(), result.decoded.size());
    for (std::size_t i = 0; i < common_size; ++i) {
        max_abs_error = std::max(max_abs_error, std::abs(input[i] - result.decoded[i]));
    }
    std::cout << std::setprecision(17)
              << "{\"backend\":\"ms-numpress-cpp\","
              << "\"peer_version\":\"" << PEER_VERSION << "\","
              << "\"source_commit\":\"" << MS_NUMPRESS_COMMIT << "\","
              << "\"algorithm\":\"" << algorithm << "\","
              << "\"input_count\":" << input.size() << ","
              << "\"output_count\":" << result.decoded.size() << ","
              << "\"encoded_bytes\":" << result.encoded.size() << ","
              << "\"max_abs_error\":" << std::scientific << max_abs_error << ","
              << "\"encoded_fingerprint\":\"" << std::hex
              << std::setw(16) << std::setfill('0')
              << fnv_bytes(result.encoded.data(), result.encoded.size()) << "\","
              << "\"decoded_fingerprint\":\"" << std::setw(16)
              << fnv_values(result.decoded) << "\"}\n";
}

void print_encode_result(
    const std::string& algorithm,
    const std::vector<double>& input,
    const EncodedData& result) {
    double max_abs_error = 0.0;
    const std::size_t common_size = std::min(input.size(), result.decoded.size());
    for (std::size_t i = 0; i < common_size; ++i) {
        max_abs_error = std::max(max_abs_error, std::abs(input[i] - result.decoded[i]));
    }
    std::cout << std::setprecision(17)
              << "{\"backend\":\"ms-numpress-cpp\","
              << "\"operation\":\"encode\","
              << "\"algorithm\":\"" << algorithm << "\","
              << "\"input_count\":" << input.size() << ","
              << "\"output_count\":" << result.decoded.size() << ","
              << "\"encoded_bytes\":" << result.encoded.size() << ","
              << "\"max_abs_error\":" << std::scientific << max_abs_error << ","
              << "\"encoded_hex\":\"" << encode_hex(result.encoded) << "\","
              << "\"decoded_fingerprint\":\"" << std::hex
              << std::setw(16) << std::setfill('0')
              << fnv_values(result.decoded) << "\"}\n";
}

void print_decode_result(
    const std::string& algorithm,
    const std::vector<unsigned char>& encoded,
    const std::vector<double>& decoded) {
    std::cout << std::setprecision(17)
              << "{\"backend\":\"ms-numpress-cpp\","
              << "\"operation\":\"decode\","
              << "\"algorithm\":\"" << algorithm << "\","
              << "\"encoded_bytes\":" << encoded.size() << ","
              << "\"output_count\":" << decoded.size() << ","
              << "\"decoded_fingerprint\":\"" << std::hex
              << std::setw(16) << std::setfill('0')
              << fnv_values(decoded) << "\"}\n";
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2 && argc != 3) {
        std::cerr << "usage: ms-numpress-cpp-peer [--version] <linear|pic|slof> < values.txt\n"
                  << "       ms-numpress-cpp-peer encode <linear|pic|slof> < values.txt\n"
                  << "       ms-numpress-cpp-peer decode <linear|pic|slof> < encoded_hex.txt\n";
        return 2;
    }
    const std::string command = argv[1];
    if (command == "--version" || command == "-V") {
        std::cout << "ms-numpress-cpp-peer " << PEER_VERSION
                  << "; source_commit=" << MS_NUMPRESS_COMMIT << '\n';
        return 0;
    }
    if (command == "--help" || command == "-h") {
        std::cout << "usage: ms-numpress-cpp-peer [--version] <linear|pic|slof> < values.txt\n"
                  << "       ms-numpress-cpp-peer encode <linear|pic|slof> < values.txt\n"
                  << "       ms-numpress-cpp-peer decode <linear|pic|slof> < encoded_hex.txt\n";
        return 0;
    }

    if ((command == "encode" || command == "decode") && argc != 3) {
        std::cerr << "encode and decode require linear, pic, or slof\n";
        return 2;
    }
    const std::string algorithm = argc == 3 ? argv[2] : command;

    if (command == "decode") {
        try {
            const std::vector<unsigned char> encoded = decode_hex_from_stdin();
            const std::vector<double> decoded = decode_values(algorithm, encoded);
            print_decode_result(algorithm, encoded, decoded);
            return 0;
        } catch (const char* error) {
            std::cerr << "ms-numpress-cpp-peer: " << error << '\n';
            return 1;
        } catch (const std::exception& error) {
            std::cerr << "ms-numpress-cpp-peer: " << error.what() << '\n';
            return 1;
        }
    }

    std::vector<double> input;
    double value = 0.0;
    while (std::cin >> value) {
        input.push_back(value);
    }
    if (input.empty()) {
        std::cerr << "ms-numpress-cpp-peer: input is empty\n";
        return 1;
    }

    try {
        const EncodedData result = encode_and_decode(algorithm, input);
        if (command == "encode") {
            print_encode_result(algorithm, input, result);
        } else {
            print_result(command, input, result);
        }
        return 0;
    } catch (const char* error) {
        std::cerr << "ms-numpress-cpp-peer: " << error << '\n';
        return 1;
    } catch (const std::exception& error) {
        std::cerr << "ms-numpress-cpp-peer: " << error.what() << '\n';
        return 1;
    }
}
