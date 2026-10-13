# Security

zmz reads files that come from instruments, converters, and other people. A file must not be able to crash a program that uses zmz, corrupt its memory, or make it use unbounded memory or time. If you find input that does, please report it privately.

## Supported versions

Until 1.0, only the latest release receives security fixes.

## Reporting a vulnerability

Report it through GitHub's private vulnerability reporting: open the repository's **Security** tab and choose **Report a vulnerability**. Please do not open a public issue, pull request, or discussion about it.

An input that triggers the problem is enough to start with; attach it to the report rather than linking it. If you have them, the zmz and Zig versions, the target and build mode, and what happens (a crash, a hang, memory growth, wrong output) help me reproduce it faster.

## What to expect

- A first response within 14 days.
- An update at least every 14 days until the report is resolved.
- A fix in a new release, and an advisory under the repository's **Security** tab that credits you unless you prefer not to be named.

## Scope

In scope: anything in the library (`src/`) that untrusted input can drive into a crash, undefined behavior, out-of-bounds access, unbounded allocation or work beyond the configured limits, or silently wrong decoded values.

The example programs, the `check-mzml`, `vocabulary`, `libm-data`, and benchmark tools, and the build scripts are not meant to face untrusted input; a problem in them is an ordinary bug, so please open an issue, unless the cause is library code they call. Resource use within the limits a caller configured is expected behavior.
