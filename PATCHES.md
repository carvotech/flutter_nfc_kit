# Downstream patches

This fork is based on upstream `flutter_nfc_kit` 3.6.2, commit
`531ec8e25649f959aba567c09296c6bf3a94008c`.

## Android build compatibility

The Android library build supports Android Gradle Plugin 9 Built-in Kotlin
while retaining the legacy Kotlin Android plugin for older AGP versions or
when Built-in Kotlin is explicitly disabled. It compiles against Android SDK
36 and targets JVM 17 for Java and Kotlin.

## Removing this fork

Consumers can return to an upstream release after it includes equivalent AGP
9 Built-in Kotlin support and the Android polling cancellation fix documented
below.
