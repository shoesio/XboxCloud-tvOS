# Xbox Cloud for Apple TV

A native Xbox Cloud Gaming launcher for Apple TV, based on
[CloudNow](https://github.com/owenselles/CloudNow). Browse your recently played
games on the Apple TV Home Screen and jump straight into a cloud session.

## How it works

- Put **Xbox Cloud** in the Home Screen's top row to see a full-screen Top Shelf
  carousel with game artwork, logos, descriptions and available metadata.
- Choose **Play** or **More Info** to launch that game directly.
- Click the app icon to resume its running game, or launch the first recent-game
  card when no session is retained.
- Press **Back** on the remote to return Home. The app keeps the cloud session
  available for resuming.

The app goes straight into streaming, with only loading, sign-in and error
screens when needed. Game controllers are supported, alongside remote navigation.

The carousel currently shows **eight recently played cloud games**. To add a
game, play it through [Xbox Cloud Gaming](https://www.xbox.com/play) using the
same account, then reopen the Apple TV app to refresh the list. There is no
in-app game browser or favourites manager.

## Build and install

You need an Apple TV running **tvOS 26.4 or later**, a Mac with a matching Xcode
SDK, an Apple Developer account for signing, and an Xbox account with access to
the games you want to stream.

1. Clone this repository and open **Forza6.xcodeproj** in Xcode.
2. Select the **Forza6** scheme. The installed app is named **Xbox Cloud**; the
   project retains its earlier name for installation compatibility.
3. Configure your signing team, bundle IDs and app group for both the app and
   Top Shelf extension. Keep the app group consistent in `Forza6/Info.plist`,
   `Forza6/TopShelf-Info.plist` and `Forza6/Forza6.entitlements`.
4. Allow Xcode to resolve Swift packages, select your Apple TV, then build/run.
5. Complete Xbox sign-in and move the app to the Home Screen's top row.

Required shared dependencies and their licences are included in `ThirdParty/`;
the optional PyroWave runtime is in `Runtime/`. Account credentials stay in the
device Keychain and are not shared with the Top Shelf extension.

See [behaviour notes](Docs/XboxCloud.md) for details. Source checks:

```sh
ruby Scripts/test-xcloud-launch-routes.rb
ruby Scripts/test-xcloud-sign-in-messages.rb
```

## Credits

CloudNow is copyright Owen Selles, licensed under [MIT](LICENSE). Dependencies
retain their own licences. Xbox and game artwork belong to their respective
owners. This unofficial project is not affiliated with Microsoft or the game
publishers; cloud access and game availability depend on Microsoft's service.
