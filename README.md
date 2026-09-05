# rustyView

Your movie library. At home or on the go.

rustyView brings your [rustyDLNA](https://github.com/vburenin/rustyDLNA) video
library to iPhone and iPad. Browse your collection, pick up where you left off,
and take movies with you for the flight, the commute, or anywhere without a
connection.

## Made for movie night

- **Find something to watch.** Explore poster artwork, browse folders, search
  your collection, and sort movies the way you like.
- **Press play.** Stream originals when your device supports them, with
  automatic server-assisted conversion for media that needs it.
- **Watch your way.** Choose audio tracks and subtitles, jump between chapters,
  adjust playback speed, and select a streaming quality that suits your connection.
- **Keep your place.** Resume unfinished movies and skip forward or back with
  a double tap.
- **Take it with you.** Download a compatible copy for offline viewing and
  manage your collection from the Downloads tab.
- **Feel at home on Apple devices.** Enjoy layouts for iPhone and iPad,
  Dynamic Type, VoiceOver, and AirPlay and Picture in Picture where supported.

## Connect your library

rustyView works with your own rustyDLNA server. You'll need an iPhone or iPad
running iOS 17 or later and access to the server's HTTPS address and sign-in
credentials.

1. **Set up rustyDLNA.** Follow the
   [rustyDLNA setup guide](https://github.com/vburenin/rustyDLNA) to serve your
   library. Enable its web player and use an HTTPS endpoint protected by HTTP
   Basic authentication. Enable server transcoding for compatible streaming
   and downloads.
2. **Connect in rustyView.** Enter the server address, user name, and password,
   then tap **Connect**. Your password is stored in the device's Keychain.
3. **Choose a movie.** Open **Library**, browse or search, and tap a title to
   see its details. Tap **Watch** to start, or resume from your saved position.

You can update your server address or credentials in
**Settings → Edit Connection**.

## Watch your way

Tap the video to show playback controls. Double-tap the left or right side to
skip ten seconds, or use the timeline to find a moment. Audio, subtitles,
playback speed, and fit or fill controls are available in the player; open
playback options for chapters and streaming quality.

Leave **Quality** on **Auto** for everyday viewing, or choose a specific
quality before you play. Available audio tracks, subtitles, chapters, and
quality choices depend on the movie and your server.

## Download now, watch later

Open a movie, tap **Download**, and choose **Compatible copy** for a version
prepared for playback on your device. Choose **Original file** when you want
the source file and know your device can play it. Selecting either option
starts the download immediately.

Follow preparation and transfer progress in **Downloads**. Once the movie is
available offline, play it from that tab or tap **Watch Offline** on its detail
page—even in airplane mode.

Downloads can continue in the background. If you force-quit rustyView, reopen
it to let transfers continue. To save mobile data, select **Wi-Fi Only** under
**Settings → Download Network**. Use the delete control in Downloads to free
space on your device; your server's original stays in your library.

## Build and run

Build rustyView from source with Xcode and XcodeGen on a Mac:

```sh
xcodegen generate
open rustyView.xcodeproj
```

Select the `rustyView` scheme, choose an iPhone or iPad simulator, and press
Run. For a physical device, configure your signing team and a unique bundle
identifier in an ignored root-level `Local.xcconfig`:

```xcconfig
RUSTYVIEW_BUNDLE_ID = com.example.private.rustyView
RUSTYVIEW_DEVELOPMENT_TEAM = YOUR_PRIVATE_TEAM_ID
```

Contributing? See [the contributor guide](AGENTS.md) for architecture, build
and test commands, and privacy requirements. Enable the commit hook with
`git config core.hooksPath .githooks`, and run `scripts/privacy_check.sh` before
sharing changes. Keep local configuration and captures in ignored paths.

## License

Copyright 2026 rustyView contributors.

Licensed under the [Apache License, Version 2.0](LICENSE).
