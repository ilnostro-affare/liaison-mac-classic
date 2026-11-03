# Releasing: signing, notarization, Sparkle

This describes how the 0.2.x releases were made. The release script itself is not part of this extract. No keys,
certificates or account ids are in this repository.

## Build settings

- `Config/Shared.xcconfig` holds `MARKETING_VERSION` and two empty settings, `LIA_SPARKLE_FEED` and
  `LIA_SPARKLE_PUBLIC_KEY`. `Config/Info.plist` maps them to Sparkle's `SUFeedURL` and `SUPublicEDKey`. A dev
  build therefore has no feed and no key. `Updates.configured` (`App/Updates.swift`) is false for it, so it never
  checks for updates and never shows an update error.
- `DEVELOPMENT_TEAM` is per machine, in `Config/Local.xcconfig`. That file is not committed and is included
  optionally from `Shared.xcconfig`.
- Entitlements: `Config/Liaison.entitlements` (camera and microphone under the hardened runtime) is used for any
  build. `Config/Liaison.full.entitlements` (associated domains, app group, `keychain-access-groups` for the notes
  key in iCloud Keychain, notifications) is used only when a Developer ID provisioning profile for the bundle id is
  installed. The script keeps only the keys the profile allows.

## Release flow (run on the release Mac)

1. **Archive and export with Developer ID.** Run `xcodebuild archive`, then `-exportArchive` with
   `Config/ExportOptions.plist` (`method = developer-id`, manual signing; the team id is injected at run time).
   A plain `build` is not enough: the export re-signs every nested part of Sparkle (Autoupdate, Updater.app, the
   XPC services) with our identity, the hardened runtime and a secure timestamp. Without that, the notary service
   rejects the app.
2. **Check the signature.** Run `codesign --verify --deep --strict`. The signed entitlements must not contain an
   unexpanded `$(...)`, because macOS refuses to launch an app whose `keychain-access-groups` is a literal variable.
   Then `otool -l` confirms that `Translation` is weak-linked, so the app still starts on macOS 14.0-14.3.
3. **Notarize and staple** the app, then the `.dmg`. Run `xcrun notarytool submit`, poll `notarytool info` instead
   of keeping one long `--wait` connection open, then `xcrun stapler staple` with retries. The App Store Connect
   API key (`.p8`) and its issuer id stay on the release Mac and are passed as arguments.
4. **Sign the update for Sparkle.** Sparkle's `generate_keys` creates the EdDSA (ed25519) key pair once, in the
   login keychain of the release Mac. The private key never leaves that keychain. `generate_keys -p` prints the
   public key, which is passed to the build as `LIA_SPARKLE_PUBLIC_KEY`. `sign_update <dmg>` produces the
   `sparkle:edSignature` and length attributes for the appcast enclosure.
5. **Write the appcast.** It has one `<item>` per release. `sparkle:version` is a UTC `YYYYMMDDHHmm` build number,
   so it only ever grows, because Sparkle compares it. `sparkle:shortVersionString` is the marketing version, and
   `sparkle:minimumSystemVersion` is 14.0.
6. **Publish in a safe order.** Upload the versioned `.dmg`, then the "latest" `.dmg`, then the appcast last, with
   no-cache. Each upload is retried. If any upload fails, the appcast is not touched, so no client is ever pointed
   at a file that is not there. Example feed: `https://updates.example.com/mac/appcast.xml`.

```xml
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Liaison</title>
    <item>
      <title>Liaison 0.2.13</title>
      <sparkle:version>202610230000</sparkle:version>
      <sparkle:shortVersionString>0.2.13</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="https://updates.example.com/mac/Liaison-0.2.13-202610230000.dmg"
                 sparkle:edSignature="<base64 signature>" length="<bytes>" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
```

## On the client

`Updates.start()` turns on automatic checks and automatic downloads. It checks at launch, on wake, when the app
comes back to the front, hourly through Sparkle, and every 15 minutes on its own timer. Once an update is
downloaded, `UpdatePolicy.decide` (`Shared/Core/UpdatePolicy.swift`) either installs and relaunches at a quiet
moment, or shows a banner, an inbox row and a Home card (Restart / Later). Restart asks first when an agent run, a
pending Yes or unsent text would be lost (`AppBusy`). Quitting the app installs the update too.
