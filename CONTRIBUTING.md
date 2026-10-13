# Contributing to zmz

Thanks for considering a contribution. Bug reports, fixes, tests, documentation, and ideas are all welcome.

Report security problems privately, as [SECURITY.md](SECURITY.md) describes, not in a public issue.

## Issues

A useful bug report says what you ran, what happened, and what you expected. A small file or snippet that shows the problem helps most, along with the zmz and Zig versions. If you cannot share the file, a description of its source (instrument, converter, and version) still helps.

## Pull requests

For anything larger than a small fix, open an issue first, so we can agree on the direction before you spend time on it.

A change is ready to merge when:

- `zig build test --summary all` passes and `zig fmt --check build.zig src tests tools examples bench` is clean;
- a fix or new behavior comes with a test that shows it;
- untrusted input still cannot crash zmz or reach undefined behavior: lengths, offsets, and counts are checked before use, and failures return a named error.

Commit messages, branch names, and how you split commits are up to you; I may squash or reword them when merging. CI also runs the tests in ReleaseFast and without the CPU-specific code paths, so you do not need to.

If a change is meant to make zmz faster, include `zig build bench` results from before and after on the same machine. The checksums it prints must match: a faster result that reads different data is not faster.

## Conventions in the code

You will see a few conventions; follow them where it is convenient, and I will adjust the rest in review:

- tests are named `[type] - [target]: behavior`, for example `test "[failure] - [mzML reader]: rejects an unterminated binary element"`;
- tests of public behavior live in `tests/`, and tests never read files outside the repository;
- comments explain why the code does something, not what it does or how it changed.

## License

By contributing, you agree that your contribution is licensed under the [Apache License, Version 2.0](LICENSE), as section 5 of the license provides.
