# Current Xbox Cloud app

Open `Forza6.xcodeproj` and choose scheme `Forza6`. The installed app is named
Xbox Cloud, with bundle ID `com.josephhewes.Forza6AppTV`. Keeping the original
bundle and app group preserves login and saved data when upgrading the app.

The native full-screen Top Shelf carousel displays eight Xbox Cloud recently
played games. Cards use branded Xbox Store splash artwork with the game's logo
when available, plus description, genre, release date/year, developer and publisher.
Play and More Info both launch the selected game directly.

An app-icon launch resumes the retained game session if one exists. Otherwise
it launches the first saved recent-game card. tvOS does not pass the carousel's
currently visible card when the app icon is selected.

Remote Back returns to Apple TV Home. Returning to the app verifies fresh video
and reconnects retained sessions when needed. Selecting another game's card
explicitly ends the previous session before starting the selected game.

The app has no game browser or settings menu: it displays only loading, sign-in,
friendly errors and the actual streamed game. Remote navigation and controllers
are both supported. Favourites are not implemented; the carousel follows Xbox's
account cloud history and refreshes when the app loads/resumes.

Recent-game metadata and loading artwork are cached in tvOS-writable cache
folders. The Top Shelf extension reads a small shared snapshot; it does not
receive account credentials. Credentials remain in the device Keychain.

Shared source retains other provider components because the current Xcode target
still compiles them. They are not exposed by this app's entry point. Older app
targets, per-game configurations, artwork and variant generators are excluded.
