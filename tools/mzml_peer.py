#!/usr/bin/env python3
"""Small, local adapters with one comparable mzML reader interface."""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import struct
import sys
from collections import Counter
from datetime import timedelta
from pathlib import Path
from typing import Any, Iterable


BACKENDS = {
    "pyteomics": "pyteomics",
    "pymzml": "pymzml",
    "mzmlpy": "mzmlpy",
    "pyopenms": "pyopenms",
}

FNV_OFFSET = 14_695_981_039_346_656_037
FNV_PRIME = 1_099_511_628_211


class Fingerprint:
    def __init__(self) -> None:
        self.value = FNV_OFFSET

    def bytes(self, value: bytes) -> None:
        for byte in value:
            self.value ^= byte
            self.value = (self.value * FNV_PRIME) & 0xFFFFFFFFFFFFFFFF

    def text(self, value: str) -> None:
        encoded = value.encode("utf-8")
        self.u64(len(encoded))
        self.bytes(encoded)

    def u64(self, value: int) -> None:
        self.bytes(struct.pack("<Q", value))

    def f64(self, value: float) -> None:
        self.bytes(struct.pack("<d", float(value)))


class Stats:
    def __init__(self, mode: str, backend: str, package_version: str) -> None:
        self.mode = mode
        self.backend = backend
        self.package_version = package_version
        self.access: str | None = None
        self.spectra = 0
        self.chromatograms: int | None = None
        self.arrays = 0
        self.values = 0
        self.array_length_mismatches = 0
        self.ms_levels: Counter[str] = Counter()
        self.fingerprint = Fingerprint()

    def add_spectrum(
        self,
        ordinal: int,
        spectrum_id: Any,
        ms_level: Any,
        retention_time_minutes: Any,
        mzs: Any,
        intensities: Any,
    ) -> None:
        mz_values = _values(mzs)
        intensity_values = _values(intensities)
        mz_array_present = mz_values is not None
        intensity_array_present = intensity_values is not None
        if mz_values is None and intensity_values is None:
            mz_values = []
            intensity_values = []
        elif mz_values is None or intensity_values is None:
            raise RuntimeError(
                f"{self.backend}: spectrum {ordinal} has no m/z or intensity array"
            )

        mz_count = len(mz_values)
        intensity_count = len(intensity_values)
        self.spectra += 1
        self.arrays += int(mz_array_present and mz_count > 0)
        self.arrays += int(intensity_array_present and intensity_count > 0)
        self.values += mz_count + intensity_count
        if mz_count != intensity_count:
            self.array_length_mismatches += 1

        level = _integer(ms_level, default=0)
        self.ms_levels[str(level)] += 1

        self.fingerprint.text("spectrum")
        self.fingerprint.text("" if spectrum_id is None else str(spectrum_id))
        self.fingerprint.u64(ordinal)
        self.fingerprint.u64(level)
        self.fingerprint.f64(_retention_minutes(retention_time_minutes))
        self.fingerprint.u64(mz_count)
        for value in mz_values:
            self.fingerprint.f64(value)
        self.fingerprint.u64(intensity_count)
        for value in intensity_values:
            self.fingerprint.f64(value)

    def as_dict(self, index: int | None = None) -> dict[str, Any]:
        result: dict[str, Any] = {
            "backend": self.backend,
            "package_version": self.package_version,
            "mode": self.mode,
        }
        if index is not None:
            result["index"] = index
        if self.access is not None:
            result["access"] = self.access
        result.update(
            {
                "spectra": self.spectra,
                "chromatograms": self.chromatograms,
                "arrays": self.arrays,
                "values": self.values,
                "array_length_mismatches": self.array_length_mismatches,
                "fingerprint": f"{self.fingerprint.value:016x}",
                "ms_levels": dict(sorted(self.ms_levels.items())),
            }
        )
        return result


def _values(value: Any) -> Any:
    if value is None:
        return None
    if isinstance(value, (str, bytes, bytearray)):
        raise RuntimeError(f"binary array was returned as {type(value).__name__}")
    try:
        len(value)
    except TypeError:
        try:
            return [float(item) for item in value]
        except TypeError:
            return [float(value)]
    else:
        return value


def _integer(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _retention_minutes(value: Any) -> float:
    if value is None:
        return 0.0
    if isinstance(value, timedelta):
        return value.total_seconds() / 60.0
    if isinstance(value, (tuple, list)) and len(value) == 2:
        number, unit = value
        if number is None:
            return 0.0
        return _time_to_minutes(number, str(unit))
    if isinstance(value, dict):
        number = value.get("value", value.get("Value"))
        unit = value.get("unitName", value.get("unit", value.get("unit_name", "")))
        return _time_to_minutes(number, str(unit))
    return float(value)


def _time_to_minutes(value: Any, unit: str) -> float:
    number = float(value)
    lowered = unit.lower()
    if "millisecond" in lowered or lowered in {"ms", "millisec"}:
        return number / 60000.0
    if "second" in lowered or lowered in {"s", "sec"}:
        return number / 60.0
    return number


def _member(value: Any, *names: str, default: Any = None) -> Any:
    for name in names:
        if isinstance(value, dict) and name in value:
            return value[name]
        try:
            result = getattr(value, name)
        except AttributeError:
            continue
        return result() if callable(result) and name.startswith("get_") else result
    return default


def _close(value: Any) -> None:
    close = getattr(value, "close", None)
    if close is not None:
        close()


def _pyteomics_time(spectrum: dict[str, Any]) -> Any:
    scan_list = spectrum.get("scanList", {})
    scans = scan_list.get("scan", []) if isinstance(scan_list, dict) else []
    if isinstance(scans, dict):
        scans = [scans]
    if scans:
        scan = scans[0]
        if isinstance(scan, dict) and "scan start time" in scan:
            value = scan["scan start time"]
            if isinstance(value, dict):
                return value
            return (value, scan.get("unitName", scan.get("unit", "minute")))
    return spectrum.get("scan start time", 0.0)


def _pyteomics_spectra(path: Path, stats: Stats) -> None:
    from pyteomics import mzml

    reader = mzml.MzML(
        str(path),
        read_schema=False,
        iterative=True,
        use_index=False,
        decode_binary=True,
    )
    try:
        for ordinal, spectrum in enumerate(reader):
            stats.add_spectrum(
                ordinal,
                spectrum.get("id"),
                spectrum.get("ms level", 0),
                _pyteomics_time(spectrum),
                spectrum.get("m/z array"),
                spectrum.get("intensity array"),
            )
    finally:
        _close(reader)


def _pyteomics_chromatograms(path: Path) -> int:
    from pyteomics import mzml

    reader = mzml.MzML(
        str(path),
        read_schema=False,
        iterative=True,
        use_index=False,
        decode_binary=False,
    )
    try:
        return sum(1 for _ in reader.iterfind("chromatogram"))
    finally:
        _close(reader)


def _pymzml_is_chromatogram(entry: Any) -> bool:
    return type(entry).__name__.lower() == "chromatogram"


def _pymzml_spectra(path: Path, stats: Stats, include_chromatograms: bool) -> None:
    import pymzml

    reader = pymzml.run.Reader(
        str(path),
        build_index_from_scratch=False,
        skip_chromatogram=not include_chromatograms,
    )
    try:
        spectrum_ordinal = 0
        for entry in reader:
            if _pymzml_is_chromatogram(entry):
                if include_chromatograms:
                    stats.chromatograms = (stats.chromatograms or 0) + 1
                continue
            spectrum_id = None
            try:
                spectrum_id = entry["id"]
            except (KeyError, TypeError):
                spectrum_id = _member(entry, "ID", "id", default=None)
            stats.add_spectrum(
                spectrum_ordinal,
                spectrum_id,
                _member(entry, "ms_level", default=0),
                _pymzml_time(entry),
                _member(entry, "mz", default=None),
                _member(entry, "i", "intensity", default=None),
            )
            spectrum_ordinal += 1
        if include_chromatograms and stats.chromatograms is None:
            stats.chromatograms = 0
    finally:
        _close(reader)


def _pymzml_time(entry: Any) -> Any:
    scan_time = getattr(entry, "scan_time_in_minutes", None)
    if callable(scan_time):
        try:
            return scan_time()
        except (AttributeError, TypeError):
            pass
    scan_time = getattr(entry, "scan_time", None)
    if callable(scan_time):
        scan_time = scan_time()
    return scan_time


def _pymzml_spectrum_by_index(path: Path, index: int) -> tuple[Any, str]:
    """Use indexed access, then preserve the API with a sequential fallback."""
    import pymzml

    reader = pymzml.run.Reader(
        str(path),
        build_index_from_scratch=False,
        skip_chromatogram=True,
    )
    try:
        try:
            return reader.get_spectrum(index), "indexed"
        except Exception as direct_error:
            _close(reader)
            reader = pymzml.run.Reader(
                str(path),
                build_index_from_scratch=False,
                skip_chromatogram=True,
            )
            spectrum_ordinal = 0
            for entry in reader:
                if _pymzml_is_chromatogram(entry):
                    continue
                if spectrum_ordinal == index:
                    return entry, "sequential-fallback"
                spectrum_ordinal += 1
            raise IndexError(f"spectrum index {index} is out of range") from direct_error
    finally:
        _close(reader)


def _mzmlpy_ms_level(reader: Any, spectrum: Any) -> Any:
    """Read ms level, including values supplied by a referenceable group."""
    level = _member(spectrum, "ms_level", default=None)
    if level is not None:
        return level

    groups = _member(reader, "referenceable_param_groups", default={})
    for reference in _member(spectrum, "ref_params", default=[]):
        reference_id = _member(reference, "ref", default=None)
        if reference_id is None or not isinstance(groups, dict):
            continue
        group = groups.get(reference_id)
        if group is None:
            continue
        get_cvparam = getattr(group, "get_cvparm", None)
        if get_cvparam is None:
            continue
        cvparam = get_cvparam("MS:1000511")
        if cvparam is not None:
            return getattr(cvparam, "value", None)
    return None


def _mzmlpy_spectra(path: Path, stats: Stats, include_chromatograms: bool) -> None:
    from mzmlpy import Mzml

    with Mzml(str(path), build_index_from_scratch=True) as reader:
        if include_chromatograms:
            try:
                stats.chromatograms = len(reader.chromatograms)
            except (TypeError, RuntimeError):
                stats.chromatograms = sum(1 for _ in reader.chromatograms)
        for ordinal, spectrum in enumerate(reader.spectra):
            stats.add_spectrum(
                ordinal,
                _member(spectrum, "id", default=None),
                _mzmlpy_ms_level(reader, spectrum),
                _member(spectrum, "scan_start_time", "retention_time", "rt", default=0.0),
                _member(spectrum, "mz", default=None),
                _member(spectrum, "intensity", "i", default=None),
            )


def _openms_spectrum(experiment: Any, index: int) -> Any:
    getter = getattr(experiment, "getSpectrum", None)
    if getter is not None:
        return getter(index)
    return experiment[index]


def _openms_chromatogram_count(experiment: Any) -> int:
    getter = getattr(experiment, "getNrChromatograms", None)
    if getter is not None:
        return int(getter())
    chromatograms = getattr(experiment, "getChromatograms", None)
    if chromatograms is not None:
        return len(chromatograms())
    return 0


def _pyopenms_time(spectrum: Any) -> Any:
    """Map OpenMS's -1 missing-RT sentinel to the common zero value."""
    retention_time = float(spectrum.getRT())
    return (retention_time if retention_time >= 0.0 else 0.0, "second")


def _pyopenms_spectra(path: Path, stats: Stats, include_chromatograms: bool) -> None:
    import pyopenms

    experiment = pyopenms.MSExperiment()
    pyopenms.MzMLFile().load(str(path), experiment)
    if include_chromatograms:
        stats.chromatograms = _openms_chromatogram_count(experiment)
    for ordinal in range(int(experiment.getNrSpectra())):
        spectrum = _openms_spectrum(experiment, ordinal)
        mzs, intensities = spectrum.get_peaks()
        stats.add_spectrum(
            ordinal,
            spectrum.getNativeID(),
            spectrum.getMSLevel(),
            _pyopenms_time(spectrum),
            mzs,
            intensities,
        )


def _package_version(backend: str) -> str:
    return importlib.metadata.version(BACKENDS[backend])


def _new_stats(backend: str, mode: str) -> Stats:
    try:
        version = _package_version(backend)
    except importlib.metadata.PackageNotFoundError as error:
        raise RuntimeError(
            f"{backend}: local package {BACKENDS[backend]!r} is not installed"
        ) from error
    return Stats(mode, backend, version)


def _read_all(backend: str, path: Path, mode: str) -> Stats:
    stats = _new_stats(backend, mode)
    include_chromatograms = mode == "summary"
    if backend == "pyteomics":
        _pyteomics_spectra(path, stats)
        if include_chromatograms:
            stats.chromatograms = _pyteomics_chromatograms(path)
    elif backend == "pymzml":
        _pymzml_spectra(path, stats, include_chromatograms)
    elif backend == "mzmlpy":
        _mzmlpy_spectra(path, stats, include_chromatograms)
    elif backend == "pyopenms":
        _pyopenms_spectra(path, stats, include_chromatograms)
    else:
        raise RuntimeError(f"unsupported backend {backend}")
    return stats


def _read_one(backend: str, path: Path, index: int) -> Stats:
    stats = _new_stats(backend, "random")
    if backend == "pyteomics":
        from pyteomics import mzml

        reader = mzml.MzML(
            str(path),
            read_schema=False,
            iterative=False,
            use_index=True,
            decode_binary=True,
        )
        try:
            spectrum = reader[index]
        finally:
            _close(reader)
        stats.access = "indexed"
        stats.add_spectrum(
            index,
            spectrum.get("id"),
            spectrum.get("ms level", 0),
            _pyteomics_time(spectrum),
            spectrum.get("m/z array"),
            spectrum.get("intensity array"),
        )
    elif backend == "pymzml":
        spectrum, stats.access = _pymzml_spectrum_by_index(path, index)
        spectrum_id = None
        try:
            spectrum_id = spectrum["id"]
        except (KeyError, TypeError):
            spectrum_id = _member(spectrum, "ID", "id", default=None)
        stats.add_spectrum(
            index,
            spectrum_id,
            _member(spectrum, "ms_level", default=0),
            _pymzml_time(spectrum),
            _member(spectrum, "mz", default=None),
            _member(spectrum, "i", "intensity", default=None),
        )
    elif backend == "mzmlpy":
        from mzmlpy import Mzml

        with Mzml(str(path), build_index_from_scratch=True) as reader:
            spectrum = reader.spectra[index]
            stats.access = "indexed"
            stats.add_spectrum(
                index,
                _member(spectrum, "id", default=None),
                _mzmlpy_ms_level(reader, spectrum),
                _member(spectrum, "scan_start_time", "retention_time", "rt", default=0.0),
                _member(spectrum, "mz", default=None),
                _member(spectrum, "intensity", "i", default=None),
            )
    elif backend == "pyopenms":
        import pyopenms

        experiment = pyopenms.MSExperiment()
        pyopenms.MzMLFile().load(str(path), experiment)
        spectrum = _openms_spectrum(experiment, index)
        stats.access = "full-file-load"
        mzs, intensities = spectrum.get_peaks()
        stats.add_spectrum(
            index,
            spectrum.getNativeID(),
            spectrum.getMSLevel(),
            _pyopenms_time(spectrum),
            mzs,
            intensities,
        )
    else:
        raise RuntimeError(f"unsupported backend {backend}")
    return stats


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run one mzML peer through the shared local comparison interface."
    )
    parser.add_argument("--backend", choices=sorted(BACKENDS), required=True)
    parser.add_argument("--version", action="store_true", help="print the peer package version")
    subparsers = parser.add_subparsers(dest="command")

    for name in ("summary", "fingerprint"):
        subparser = subparsers.add_parser(name)
        subparser.add_argument("file", type=Path)

    random_parser = subparsers.add_parser("random")
    random_parser.add_argument("file", type=Path)
    random_parser.add_argument("index", type=int)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.version:
        print(f"{args.backend}-peer package={_package_version(args.backend)}")
        return 0
    if args.command is None:
        _parser().error("a command is required")
    if not args.file.is_file():
        raise RuntimeError(f"input file does not exist: {args.file}")
    if args.command == "random" and args.index < 0:
        raise RuntimeError("spectrum index must be non-negative")

    if args.command == "random":
        stats = _read_one(args.backend, args.file, args.index)
        result = stats.as_dict(index=args.index)
    else:
        stats = _read_all(args.backend, args.file, args.command)
        result = stats.as_dict()
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(1)
    except Exception as error:
        print(f"mzml-peer: {error}", file=sys.stderr)
        raise SystemExit(1)
