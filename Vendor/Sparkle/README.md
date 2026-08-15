# Vendored Sparkle

This directory contains the official Sparkle 2.9.5 Universal XCFramework. It
is checked into the project to avoid a repeatable Xcode/SwiftPM artifact-cache
collision when resolving Sparkle's remote binary target.

Source and releases: https://github.com/sparkle-project/Sparkle

The source ZIP was verified against the SHA-256 published in Sparkle 2.9.5's
official `Package.swift` before extraction:

```text
34b9b2071f3de0012eca3faa3a9290bb94e62131e9a74f6dc91514a000097a6c
```

The bundled framework remains subject to the license in `LICENSE`. When
updating Sparkle, replace the complete XCFramework, update the version above,
then verify both a normal Xcode build and the Universal release archive.
