use std::collections::BTreeMap;
use std::env;
use std::fmt::Write as _;
use std::path::Path;
use std::process::ExitCode;

use mzdata::io::{ChromatogramSource, MZFileReader, MZReader, SpectrumSource};
use mzdata::spectrum::RawSpectrum;

const PEER_VERSION: &str = "0.1.0";
const MZDATA_VERSION: &str = "0.66.7";
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

    fn text(&mut self, value: &str) {
        self.u64(value.len() as u64);
        self.bytes(value.as_bytes());
    }

    fn u64(&mut self, value: u64) {
        self.bytes(&value.to_le_bytes());
    }

    fn f64(&mut self, value: f64) {
        self.bytes(&value.to_le_bytes());
    }
}

#[derive(Default)]
struct Stats {
    spectra: usize,
    chromatograms: Option<usize>,
    arrays: usize,
    values: usize,
    mismatches: usize,
    ms_levels: BTreeMap<u32, usize>,
    fingerprint: Fingerprint,
}

impl Default for Fingerprint {
    fn default() -> Self {
        Self::new()
    }
}

impl Stats {
    fn add_spectrum(&mut self, ordinal: usize, spectrum: &RawSpectrum) {
        let mzs = spectrum.mzs();
        let intensities = spectrum.intensities();
        let ms_level = u32::from(spectrum.ms_level());
        let id = spectrum.id().to_string();
        let retention_time = spectrum.start_time();

        self.spectra += 1;
        self.arrays += usize::from(!mzs.is_empty());
        self.arrays += usize::from(!intensities.is_empty());
        self.values += mzs.len() + intensities.len();
        if mzs.len() != intensities.len() {
            self.mismatches += 1;
        }
        *self.ms_levels.entry(ms_level).or_default() += 1;

        self.fingerprint.text("spectrum");
        self.fingerprint.text(&id);
        self.fingerprint.u64(ordinal as u64);
        self.fingerprint.u64(u64::from(ms_level));
        self.fingerprint.f64(retention_time);
        self.fingerprint.u64(mzs.len() as u64);
        for mz in mzs.iter() {
            self.fingerprint.f64(*mz);
        }
        self.fingerprint.u64(intensities.len() as u64);
        for intensity in intensities.iter() {
            self.fingerprint.f64(f64::from(*intensity));
        }
    }
}

fn render_stats(mode: &str, stats: &Stats, random_index: Option<usize>) -> String {
    let mut output = String::new();
    output.push('{');
    let _ = write!(
        output,
        "\"backend\":\"mzdata\",\"peer_version\":\"{}\",\"package_version\":\"{}\",\"mode\":\"{}\"",
        PEER_VERSION, MZDATA_VERSION, mode
    );
    if let Some(index) = random_index {
        let _ = write!(output, ",\"index\":{},\"access\":\"indexed\"", index);
    }
    let _ = write!(output, ",\"spectra\":{},\"chromatograms\":", stats.spectra);
    match stats.chromatograms {
        Some(count) => {
            let _ = write!(output, "{count}");
        }
        None => output.push_str("null"),
    }
    let _ = write!(
        output,
        ",\"arrays\":{},\"values\":{},\"array_length_mismatches\":{},\"fingerprint\":\"{:016x}\",\"ms_levels\":{{",
        stats.arrays,
        stats.values,
        stats.mismatches,
        stats.fingerprint.0
    );
    for (position, (level, count)) in stats.ms_levels.iter().enumerate() {
        if position > 0 {
            output.push(',');
        }
        let _ = write!(output, "\"{}\":{}", level, count);
    }
    output.push_str("}}");
    output
}

fn usage() -> &'static str {
    "usage: mzdata-peer [--version] <summary|fingerprint|random> FILE [INDEX]"
}

fn read_all(path: &Path, include_chromatograms: bool) -> Result<Stats, String> {
    let mut reader = MZReader::open_path(path)
        .map_err(|error| format!("could not open {}: {error}", path.display()))?;
    let indexed_spectra = reader.len();
    let mut stats = Stats::default();
    if include_chromatograms {
        stats.chromatograms = Some(reader.count_chromatograms());
    }
    for (ordinal, spectrum) in reader.by_ref().enumerate() {
        let raw = spectrum
            .into_raw()
            .map_err(|error| format!("could not materialize spectrum {ordinal}: {error}"))?;
        stats.add_spectrum(ordinal, &raw);
    }
    if indexed_spectra != stats.spectra {
        return Err(format!(
            "reader index advertised {indexed_spectra} spectra, but only {} could be decoded",
            stats.spectra
        ));
    }
    Ok(stats)
}

fn read_one(path: &Path, index: usize) -> Result<Stats, String> {
    let mut reader = MZReader::open_path(path)
        .map_err(|error| format!("could not open {}: {error}", path.display()))?;
    let spectrum = reader
        .get_spectrum_by_index(index)
        .ok_or_else(|| format!("spectrum index {index} is out of range"))?;
    let mut stats = Stats::default();
    let raw = spectrum
        .into_raw()
        .map_err(|error| format!("could not materialize spectrum {index}: {error}"))?;
    stats.add_spectrum(index, &raw);
    Ok(stats)
}

fn main() -> ExitCode {
    let mut arguments = env::args().skip(1);
    let Some(command) = arguments.next() else {
        eprintln!("{}", usage());
        return ExitCode::from(2);
    };

    if command == "--version" || command == "-V" {
        println!("mzdata-peer {PEER_VERSION}; mzdata {MZDATA_VERSION}; features=mzml,numpress,miniz_oxide");
        return ExitCode::SUCCESS;
    }
    if command == "--help" || command == "-h" {
        println!("{}", usage());
        return ExitCode::SUCCESS;
    }

    let Some(path) = arguments.next() else {
        eprintln!("{}", usage());
        return ExitCode::from(2);
    };
    let path = Path::new(&path);
    let result =
        match command.as_str() {
            "summary" | "fingerprint" => read_all(path, command == "summary")
                .map(|stats| render_stats(&command, &stats, None)),
            "random" => {
                let Some(index) = arguments.next() else {
                    eprintln!("{}", usage());
                    return ExitCode::from(2);
                };
                match index.parse::<usize>() {
                    Ok(index) => read_one(path, index)
                        .map(|stats| render_stats("random", &stats, Some(index))),
                    Err(error) => Err(format!("invalid spectrum index {index}: {error}")),
                }
            }
            _ => Err(format!("unknown command {command}; {}", usage())),
        };

    match result {
        Ok(output) => {
            println!("{output}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("mzdata-peer: {error}");
            ExitCode::from(1)
        }
    }
}
