//! Exposes source parameter types and optional vocabulary interpretation.

const source = @import("source.zig");

/// Immutable vocabulary metadata and bounded graph queries, separate from source parsing.
pub const Vocabulary = @import("vocabulary.zig");

/// Optional declaration-aware lookup against explicit or bundled vocabulary resources.
pub const Resolver = @import("resolver.zig");

/// An exact accession spelling borrowed from caller-owned text.
pub const Accession = source.Accession;
/// Borrowed prefix and local parts of an accession.
pub const Curie = source.Curie;
/// Optional source metadata for one vocabulary declaration.
pub const Declaration = source.Declaration;
/// Independently optional source unit attributes.
pub const Unit = source.Unit;
/// A controlled parameter with source labels and lexical value.
pub const Param = source.Param;
/// A user parameter with its declared type and lexical value.
pub const UserParam = source.UserParam;
pub const GroupRef = source.GroupRef;
pub const Attribute = source.Attribute;
pub const ParameterXml = source.ParameterXml;
/// One source entry, preserving parameter and group-reference order.
pub const Entry = source.Entry;
/// A borrowed referenceable parameter group.
pub const Group = source.Group;
/// Failures from bounded reference expansion.
pub const ExpansionError = source.ExpansionError;
/// Expands group references at their source positions without mutating input.
pub const EffectiveIterator = source.EffectiveIterator;
/// The result of requesting one accession without discarding repetitions.
pub const Match = source.Match;
/// Lexical failures for optional and typed source values.
pub const ValueError = source.ValueError;
/// Searches an effective parameter sequence by exact accession.
pub const findOne = source.findOne;
/// Parses XML Schema boolean spellings.
pub const parseBoolean = source.parseBoolean;
/// Parses a checked decimal integer without changing source text.
pub const parseInteger = source.parseInteger;
/// Parses checked XML Schema float spellings, including special values.
pub const parseFloat = source.parseFloat;
