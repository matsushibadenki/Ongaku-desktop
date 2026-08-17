# Ongaku Desktop releases

Published builds are a single macOS Universal Binary containing both Apple
Silicon (`arm64`) and Intel/AMD64 (`x86_64`) slices. Generated archives and
packages belong in `Releases/build` and `Releases/dist`; both are ignored by
Git. Release metadata, scripts, and the signed Sparkle appcast stay versioned.
The application links the verified local Sparkle 2.9.5 package under
`Vendor/Sparkle`, so ordinary Xcode builds do not depend on SwiftPM's shared
binary-download cache. Matching signed release utilities are kept in
`Releases/SparkleTools` for offline, reproducible appcast generation.

## One-time setup

The Sparkle EdDSA private key is stored in the current user's macOS Keychain
under account `com.ongaku.desktop`. Never export it into this repository. The
matching public key already embedded in the app is:

```text
BDsXs9EbQOTcuSo9Jx+R49lpRVR3C0I4olojiX0N5kw=
```

Back up the Keychain signing key to an encrypted secret store outside this
repository. Losing it prevents existing installations from trusting future
updates; exposing it lets an attacker forge a trusted update.

Configure a Developer ID Application certificate in Xcode and create a
notarytool profile once:

```sh
xcrun notarytool store-credentials ongaku-notary
```

## Build a release

Set the signing identity, team, and the Keychain profile created for
`notarytool`, then pass a semantic version and increasing bundle build number:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Hironori Suzawa (3WH28SSRZC)" \
DEVELOPMENT_TEAM="3WH28SSRZC" \
NOTARY_PROFILE="ongaku-notary" \
./Releases/build-release.sh 1.0.0 100
```

The script archives with `arm64 x86_64`, verifies both Mach-O slices, verifies
code signing, notarizes and staples the app, creates a signed and notarized APFS
DMG with an Applications shortcut, creates its SHA-256 checksum, signs the DMG
update with Sparkle, and updates `appcast.xml`.

Before publishing, review the generated appcast and release notes. Upload the
DMG and checksum to the GitHub release tagged `v<version>`, then commit the
updated `Releases/appcast.xml`. The same DMG is used for manual GitHub installs
and in-app updates. The app's **Software Update…** command reads that HTTPS feed
and Sparkle validates the EdDSA signature before installing.

After authenticating GitHub CLI, a release can be created with:

```sh
gh release create v1.0.0 \
  Releases/dist/OngakuDesktop-1.0.0-universal.dmg \
  Releases/dist/OngakuDesktop-1.0.0-universal.dmg.sha256 \
  --title "Ongaku Desktop 1.0.0" \
  --notes-file Releases/dist/OngakuDesktop-1.0.0-universal.md
```

Publish the GitHub release before pushing the updated appcast so clients never
receive an update URL whose DMG has not been uploaded yet.

For a local Universal Binary DMG without Developer ID or notarization:

```sh
./Releases/build-release.sh --local 1.0.0 100
```

Local DMGs are deliberately not added to the appcast and must not be published.
