# Downstream patches

This fork is based on upstream `flutter_nfc_kit` 3.6.2, commit
`531ec8e25649f959aba567c09296c6bf3a94008c`.

## Android build compatibility

The Android library build supports Android Gradle Plugin 9 Built-in Kotlin
while retaining the legacy Kotlin Android plugin for older AGP versions or
when Built-in Kotlin is explicitly disabled. It compiles against Android SDK
36 and targets JVM 17 for Java and Kotlin.

## Android polling cancellation

Calling `finish()` while an Android `poll()` is pending completes that poll
with a structured Flutter platform error:

- code: `409`
- message: `Session canceled`
- details: `null`

The `finish()` call itself normally succeeds after cleanup. A native cleanup
failure is returned by `finish()`, while the canceled poll still completes
exactly once with `409`. Calling `finish()` without an active poll is harmless.
Poll timeout remains error `408`. Public Dart method signatures are unchanged,
and consumers should inspect `PlatformException.code` rather than parse an
error message.

Starting another poll while one is already pending is rejected with error
`429` (`Polling operation already in progress`). This keeps the existing `409`
code unambiguous for session cancellation without changing the type or purpose
of the error details field.

Each poll receives a monotonically increasing operation ID and uniquely owns
its pending method result. Finish, timeout, tag discovery, and activity detach
take that ownership before completing the result, so only one path can win.
Timeout work and reader callbacks carry the operation ID; stale work cannot
claim a newer result or disable its reader session. All ownership changes and
NFC cleanup are serialized on the plugin's NFC handler thread. Cancellation is
reported to Dart only after tag technologies and Reader Mode have been cleaned
up, and before the corresponding `finish()` call completes.

### Verification

Verified locally with Flutter 3.47.5, Dart 3.13.4, and Java 17:

- `dart format --output=none --set-exit-if-changed lib`: passed
- `dart analyze`: passed
- Android ownership and error-contract unit tests: passed
- AGP 8.13.0 legacy Kotlin fallback unit tests and debug build: passed
- AGP 9.0.1 Built-in Kotlin with Kotlin 2.3.20 unit tests and debug build: passed

The tests cover finish cancellation and cleanup order, timeout and concurrent
poll error contracts, tag discovery ownership, finish-after-discovery, repeated
finish, stale timeout, stale callback, concurrent begin rejection, activity
detach ownership, and cleanup failure. `lintDebug` reaches Android lint but
reports the upstream dynamic `"${AGPVersion}"` declaration as an unparseable
plugin version; no lint finding points to the cancellation implementation.

Actual Reader Mode behavior, tag discovery, and activity transitions still
require an NFC-capable Android device.

## iOS session ownership

Each CoreNFC polling session receives an operation ID. Session invalidation,
tag detection, connection, NDEF status, FeliCa polling, and delayed multi-tag
restart callbacks verify both the `NFCTagReaderSession` identity and operation
ID before reading or completing state. A stale callback cannot complete or
clear a later poll.

Calling `finish()` marks the active operation as finishing and waits for the
matching CoreNFC invalidation callback. The pending poll completes with `409`
before `finish()` completes. Repeated finish calls share the same invalidation
and all complete after it. Starting another poll before invalidation completes
is rejected with `429`. Calling finish without an active session remains a
successful no-op.

The plugin publishes its instance to Flutter and implements engine detach
cleanup. Detach invalidates the matching CoreNFC session, completes an active
poll with `409`, completes any pending finish calls, and clears ownership before
late invalidation callbacks can arrive.

`iosRestartPolling()` no longer takes ownership of the pending poll result. It
restarts the current non-finishing session and completes its own `Future<void>`
immediately. Delayed restart work is ignored after finish or session rollover.

The pure Swift ownership controller has XCTest coverage independent of Flutter
and CoreNFC. The example application is also built for an unsigned iOS device
to verify Flutter, CocoaPods, Swift Package, and CoreNFC integration. CoreNFC
invalidation timing and real tag callbacks still require an NFC-capable iPhone.

### Verification

- Swift ownership controller build: passed
- Swift ownership controller tests: 7 passed
- `flutter build ios --debug --no-codesign`: passed
- `dart analyze`: passed

The controller tests cover exactly-once completion, finish after tag discovery,
repeated finish, detach, concurrent begin rejection, and stale operation IDs.

This patch supersedes the cancellation direction proposed in upstream
[PR #142](https://github.com/nfcim/flutter_nfc_kit/pull/142). That PR uses a
global callback without per-operation ownership and includes unrelated build,
platform, example, WebUSB, and SDK constraint changes.

## Removing this fork

Consumers can return to an upstream release after it includes equivalent AGP
9 Built-in Kotlin support and Android and iOS polling cancellation
implementations with per-operation ownership and stale-callback protection.
