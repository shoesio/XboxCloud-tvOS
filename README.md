# Xbox Cloud for Apple TV

A native tvOS Xbox Cloud Gaming launcher based on [CloudNow](https://github.com/owenselles/CloudNow).

The Xbox Cloud app presents recently played games as full-screen Top Shelf cards
with branded artwork, descriptions and available game metadata. Both Play and
More Info launch the selected game directly. Selecting the app icon resumes its
retained game session, or launches the first recent-game card when no session is
retained. The app itself only shows loading, sign-in and error surfaces alongside
the streamed game.

## Build and install

1. Clone this repository and open `Forza6.xcodeproj` in Xcode.
2. Select the **Forza6** scheme. Its installed display name is **Xbox Cloud**;
   the older project and bundle names preserve the existing installation's data.
3. Select your Apple Developer team for the app and Top Shelf extension, and use
   bundle IDs and app groups provisioned for your account. Update matching app
   group values in `Forza6/Info.plist`, `TopShelf-Info.plist` and the entitlements.
4. Let Xcode resolve the WebRTC and OpenSSL Swift packages.
5. Select your Apple TV and build/run. The project currently targets tvOS 26.4.
6. Sign in with your Xbox account if required, then put Xbox Cloud in the Apple
   TV Home Screen's top row to display the carousel.

The required PunktfunkKit source, prebuilt framework and its licence notices are
included under `ThirdParty/PunktfunkKit`; project references use that local path.
Moonlight sources, Opus libraries and the optional PyroWave runtime are also
included because the shared CloudNow target still builds those components.
The runtime is stored under `Runtime/PyroWave`.
Generated Xcode build products, signing credentials, device diagnostics and
unrelated Steam app projects are excluded.

## Project layout

- `Forza6.xcodeproj`, `Forza6/`: generic Xbox Cloud app configuration and artwork.
- `CloudNow/`, `CloudNowTopShelf/`: shared launcher, streaming and carousel code.
- `Scripts/`: current icon generator and targeted checks.
- `Docs/XboxCloud.md`: current launch and carousel behaviour.

To regenerate the generic Xbox Cloud icon, run
`ruby Scripts/generate-xcloud-assets.rb`. The icon uses the official white Xbox
mark on a green gradient.

Targeted source checks:

```sh
ruby Scripts/test-xcloud-launch-routes.rb
ruby Scripts/test-xcloud-sign-in-messages.rb
```

This repository contains the current Xbox Cloud app, not the older per-game app
variants. Some shared source files retain historical type names such as
`FortniteLauncherView`; they implement this app's current streaming surface.
The `Forza6` project/configuration folder names retain the installed app's identity.

This is a source snapshot, not an upload of
Microsoft account data. Xbox credentials remain in the device Keychain. Xbox
Cloud access and game availability depend on your account and Microsoft's service.

## Attribution

CloudNow is copyright Owen Selles and licensed under MIT; see `LICENSE`.
Dependencies retain their licences and notices in `ThirdParty/`. Xbox and game
artwork belong to their respective owners. This is an unofficial client and is
not affiliated with Microsoft or the game publishers.
