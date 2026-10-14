# Built with zmz

zmz exists because I kept writing the same mzML layer for every tool I built. These are the tools that now share it. Each one uses a different slice of the library, which is a decent tour of what it can do.

<p align="center">
  <a href="https://github.com/eneskemalergin/mzValidate"><img src="https://raw.githubusercontent.com/eneskemalergin/mzValidate/main/assets/mzvalidate-icon.svg" alt="mzValidate" width="96"></a>
  &nbsp;&nbsp;
  <a href="https://github.com/eneskemalergin/mzarc"><img src="https://raw.githubusercontent.com/eneskemalergin/mzarc/main/assets/mzarc-orbit-mark.svg" alt="mzarc" width="96"></a>
</p>

## mzValidate

[mzValidate](https://github.com/eneskemalergin/mzValidate) validates mzML files: XML syntax, mzML structure, binary integrity, index metadata, vocabulary semantics, and references, mostly in one streaming pass and without building a tree. A validator has to see the document exactly as written, so it works below the mzML model:

- `Events` for every element, attribute, and text run with its source byte offset, which is where each finding's location comes from;
- `model.encodingTerm`, so it classifies array encodings exactly as zmz's readers do;
- `base64`, `zlib`, and `sha1` to check binary payloads and the indexedmzML checksum without decoding into a model.

## mzarc

[mzarc](https://github.com/eneskemalergin/mzarc) is a research codec that compresses mass-spectrometry spectra with domain-specific transforms. It needs the numbers fast and nothing else held in memory:

- `StreamReader` with an array selector, so it decodes only the arrays it archives;
- `DecodedArrays`, reused for the whole file, so a run of any size compresses in flat memory;
- the record helpers and `model.Terms` for the metadata each archived spectrum keeps.

## Add yours

Built something on zmz? Open an issue with a link and a line about what it does, and I'll add it here.
