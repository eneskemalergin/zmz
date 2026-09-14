use std::env;
use std::fmt::Write as _;
use std::io::{self, Read};
use std::process::ExitCode;

use numpress_rs::{decode_linear, decode_pic, decode_slof, encode_linear, encode_pic, encode_slof};
use numpress_rs::{optimal_scaling, optimal_slof_fixed_point};

const PEER_VERSION: &str = "0.1.0";
const NUMPRESS_VERSION: &str = "1.1.1";
const FNV_OFFSET: u64 = 14_695_981_039_346_656_037;
const FNV_PRIME: u64 = 1_099_511_628_211;

struct Fingerprint(u64);

impl Fingerprint {
    fn new() -> Self {
        Self(FNV_OFFSET)
    }

    fn bytes(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.0 ^= u64::from(*byte);
            self.0 = self.0.wrapping_mul(FNV_PRIME);
        }
    }

    fn f64(&mut self, value: f64) {
        self.bytes(&value.to_le_bytes());
    }
}

fn fingerprint_bytes(bytes: &[u8]) -> u64 {
    let mut fingerprint = Fingerprint::new();
    fingerprint.bytes(bytes);
    fingerprint.0
}

fn fingerprint_values(values: &[f64]) -> u64 {
    let mut fingerprint = Fingerprint::new();
    for value in values {
        fingerprint.f64(*value);
    }
    fingerprint.0
}

struct EncodedData {
    encoded: Vec<u8>,
    decoded: Vec<f64>,
}

fn encode_values(algorithm: &str, input: &[f64]) -> Result<Vec<u8>, String> {
    if algorithm == "linear" && input.len() < 2 {
        return Err("linear requires at least two values".to_string());
    }
    let mut encoded = Vec::new();
    match algorithm {
        "linear" => {
            let scaling = optimal_scaling(input);
            encode_linear(input, &mut encoded, scaling)
                .map_err(|error| format!("linear encode failed: {error}"))?;
        }
        "pic" => {
            encode_pic(input, &mut encoded)
                .map_err(|error| format!("pic encode failed: {error}"))?;
        }
        "slof" => {
            let scaling = optimal_slof_fixed_point(input);
            encode_slof(input, &mut encoded, scaling)
                .map_err(|error| format!("slof encode failed: {error}"))?;
        }
        _ => {
            return Err(format!(
                "unknown algorithm {algorithm}; expected linear, pic, or slof"
            ))
        }
    }
    Ok(encoded)
}

fn decode_values(algorithm: &str, encoded: &[u8]) -> Result<Vec<f64>, String> {
    let mut decoded = Vec::new();
    match algorithm {
        "linear" => decode_linear(encoded, &mut decoded)
            .map_err(|error| format!("linear decode failed: {error}"))?,
        "pic" => decode_pic(encoded, &mut decoded)
            .map_err(|error| format!("pic decode failed: {error}"))?,
        "slof" => decode_slof(encoded, &mut decoded)
            .map_err(|error| format!("slof decode failed: {error}"))?,
        _ => {
            return Err(format!(
                "unknown algorithm {algorithm}; expected linear, pic, or slof"
            ))
        }
    };
    Ok(decoded)
}

fn encode_and_decode(algorithm: &str, input: &[f64]) -> Result<EncodedData, String> {
    let encoded = encode_values(algorithm, input)?;
    let decoded = decode_values(algorithm, &encoded)?;
    Ok(EncodedData { encoded, decoded })
}

fn encode_hex(bytes: &[u8]) -> String {
    let mut result = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        use std::fmt::Write as _;
        let _ = write!(result, "{byte:02x}");
    }
    result
}

fn hex_digit(value: u8) -> Result<u8, String> {
    match value {
        b'0'..=b'9' => Ok(value - b'0'),
        b'a'..=b'f' => Ok(value - b'a' + 10),
        b'A'..=b'F' => Ok(value - b'A' + 10),
        _ => Err("encoded input contains a non-hexadecimal character".to_string()),
    }
}

fn decode_hex(text: &str) -> Result<Vec<u8>, String> {
    let compact: String = text.split_whitespace().collect();
    let bytes = compact.as_bytes();
    if bytes.is_empty() {
        return Err("encoded input is empty".to_string());
    }
    if !bytes.len().is_multiple_of(2) {
        return Err("encoded input has an odd number of hexadecimal characters".to_string());
    }
    let mut result = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.as_chunks::<2>().0 {
        result.push((hex_digit(pair[0])? << 4) | hex_digit(pair[1])?);
    }
    Ok(result)
}

fn render_result(algorithm: &str, input: &[f64], encoded: &[u8], decoded: &[f64]) -> String {
    let max_abs_error = input
        .iter()
        .zip(decoded.iter())
        .map(|(expected, actual)| (expected - actual).abs())
        .fold(0.0_f64, f64::max);
    let mut output = String::new();
    let _ = write!(
        output,
        "{{\"backend\":\"numpress-rs\",\"peer_version\":\"{}\",\"package_version\":\"{}\",\"algorithm\":\"{}\",\"input_count\":{},\"output_count\":{},\"encoded_bytes\":{},\"max_abs_error\":{:.17e},\"encoded_fingerprint\":\"{:016x}\",\"decoded_fingerprint\":\"{:016x}\"}}",
        PEER_VERSION,
        NUMPRESS_VERSION,
        algorithm,
        input.len(),
        decoded.len(),
        encoded.len(),
        max_abs_error,
        fingerprint_bytes(encoded),
        fingerprint_values(decoded)
    );
    output
}

fn render_encode_result(algorithm: &str, input: &[f64], result: &EncodedData) -> String {
    let max_abs_error = input
        .iter()
        .zip(result.decoded.iter())
        .map(|(expected, actual)| (expected - actual).abs())
        .fold(0.0_f64, f64::max);
    let mut output = String::new();
    let _ = write!(
        output,
        "{{\"backend\":\"numpress-rs\",\"operation\":\"encode\",\"algorithm\":\"{}\",\"input_count\":{},\"output_count\":{},\"encoded_bytes\":{},\"max_abs_error\":{:.17e},\"encoded_hex\":\"{}\",\"decoded_fingerprint\":\"{:016x}\"}}",
        algorithm,
        input.len(),
        result.decoded.len(),
        result.encoded.len(),
        max_abs_error,
        encode_hex(&result.encoded),
        fingerprint_values(&result.decoded)
    );
    output
}

fn render_decode_result(algorithm: &str, encoded: &[u8], decoded: &[f64]) -> String {
    format!(
        "{{\"backend\":\"numpress-rs\",\"operation\":\"decode\",\"algorithm\":\"{}\",\"encoded_bytes\":{},\"output_count\":{},\"decoded_fingerprint\":\"{:016x}\"}}",
        algorithm,
        encoded.len(),
        decoded.len(),
        fingerprint_values(decoded)
    )
}

fn usage() -> &'static str {
    "usage: numpress-rs-peer [--version] <linear|pic|slof> < values.txt\n       numpress-rs-peer encode <linear|pic|slof> < values.txt\n       numpress-rs-peer decode <linear|pic|slof> < encoded_hex.txt"
}

fn main() -> ExitCode {
    let mut arguments = env::args().skip(1);
    let Some(command) = arguments.next() else {
        eprintln!("{}", usage());
        return ExitCode::from(2);
    };
    if command == "--version" || command == "-V" {
        println!(
            "numpress-rs-peer {PEER_VERSION}; numpress-rs {NUMPRESS_VERSION}; source=crates.io"
        );
        return ExitCode::SUCCESS;
    }
    if command == "--help" || command == "-h" {
        println!("{}", usage());
        return ExitCode::SUCCESS;
    }

    let algorithm = if command == "encode" || command == "decode" {
        let Some(algorithm) = arguments.next() else {
            eprintln!("numpress-rs-peer: encode and decode require linear, pic, or slof");
            return ExitCode::from(2);
        };
        algorithm
    } else {
        command.clone()
    };

    if command == "decode" {
        let mut encoded_text = String::new();
        if let Err(error) = io::stdin().read_to_string(&mut encoded_text) {
            eprintln!("numpress-rs-peer: could not read stdin: {error}");
            return ExitCode::from(1);
        }
        match decode_hex(&encoded_text).and_then(|encoded| {
            decode_values(&algorithm, &encoded).map(|decoded| (encoded, decoded))
        }) {
            Ok((encoded, decoded)) => {
                println!("{}", render_decode_result(&algorithm, &encoded, &decoded));
                return ExitCode::SUCCESS;
            }
            Err(error) => {
                eprintln!("numpress-rs-peer: {error}");
                return ExitCode::from(1);
            }
        }
    }

    let mut input_text = String::new();
    if let Err(error) = io::stdin().read_to_string(&mut input_text) {
        eprintln!("numpress-rs-peer: could not read stdin: {error}");
        return ExitCode::from(1);
    }
    let input = match input_text
        .split_whitespace()
        .map(str::parse::<f64>)
        .collect::<Result<Vec<_>, _>>()
    {
        Ok(input) => input,
        Err(error) => {
            eprintln!("numpress-rs-peer: input is not a sequence of decimal numbers: {error}");
            return ExitCode::from(1);
        }
    };
    if input.is_empty() {
        eprintln!("numpress-rs-peer: input is empty");
        return ExitCode::from(1);
    }

    match encode_and_decode(&algorithm, &input) {
        Ok(result) => {
            if command == "encode" {
                println!("{}", render_encode_result(&algorithm, &input, &result));
            } else {
                println!(
                    "{}",
                    render_result(&algorithm, &input, &result.encoded, &result.decoded)
                );
            }
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("numpress-rs-peer: {error}");
            ExitCode::from(1)
        }
    }
}
