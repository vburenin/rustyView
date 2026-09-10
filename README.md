# rustyView

The iPhone and iPad companion app for rustyDLNA.

rustyView connects to your [rustyDLNA](https://github.com/vburenin/rustyDLNA) video
library. Browse your collection, pick up where you left off,
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
  a double tap. Keep favorites and a history of movies you have watched.
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
Leaving the password blank keeps the saved password only for the same server
and user name. Connection edits are verified before replacing your current library.
If a connection fails, the app offers actions for the cause: edit rejected
sign-in details, retry an interrupted connection, or open downloaded movies
while offline. An unavailable Keychain password is kept distinct from a missing
password. Cancelling a connection attempt leaves your previous connection intact.

## Pick up where you left off

**Continue Watching** brings unfinished movies back within reach. Tap **Resume**
to continue or choose **Start Over** from the row's actions menu. Start Over first saves that choice;
if saving fails, your current player and previous saved position remain available.
Removing a movie from Continue Watching hides the row while keeping its position
for the next time you open its details.

Use a movie's actions menu to add it to **Favorites**. **History** shows each movie
once, with its latest viewing. Movies appear only after playback starts; finishing
one marks it watched. Favorites and history remain after a local copy is deleted
or the movie disappears from the server.

Saved entries belong to their original server and account. When a ready local
copy exists, Resume uses that copy even after you forget the connection. A movie
from another account never silently opens through the current login. Local
resume and remaining time use the inspected file's duration, so an old online
bookmark cannot seek past the end of a shorter saved copy.

Library remembers your browsing mode and sort for each account. Returning from
details, search, or a folder can restore the visible movie within that browsing
session. Loading feedback identifies a new folder or search while its results
arrive. Empty libraries offer **Refresh**, and an empty search offers a way back
to your collection.

Search editing is isolated from movie-grid updates, so typing can continue while
results load. New searches cancel superseded requests, and clearing the field
restores the previously browsed pages and position.

## Watch your way

Tap the video to show playback controls. Double-tap the left or right side to
skip ten seconds, or use the timeline to find a moment. Audio, subtitles,
playback speed, and fit or fill controls are available in the player; open
playback options for chapters and streaming quality.

Audio choices show the language code alongside the track title, codec, and
channel layout. Audio, subtitle, speed, and quality selectors scroll, with
wrapping labels so long lists remain usable in portrait and landscape.

With a keyboard, Space plays or pauses, arrow keys skip ten seconds, and O opens
playback options. Accessibility text sizes keep controls visible until you
dismiss them.

Play and Pause reflect what will happen even while a movie is preparing. If
playback stops advancing, rustyView makes a bounded recovery attempt while
preserving your time and choices. **Retry Current Playback** lets you try again
after a connection problem; **Close** always leaves the player.

Leave **Quality** on **Auto** for everyday viewing, or choose a specific
quality before you play. Your preferred quality and audio language are saved
for later movies. If a server does not offer your preferred quality, the player
explains that it is using Auto for this movie and keeps your saved preference.
Available audio tracks, subtitles, chapters, and quality choices depend on the
movie and your server.

Streaming changes inside the player stay in a draft until you tap
**Apply Streaming Changes**. **Cancel** leaves playback unchanged. The draft
keeps Original and encoded-quality choices consistent before you apply them.

AirPlay video output is unavailable for online streams because rustyView keeps
their media requests under the app's control. The player explains this before
output selection. Use Screen Mirroring to show the device's screen elsewhere.
Saved movies retain native output options where supported.

If a stream points outside your connected server, playback stops with an error.
rustyView does not follow that reference or automatically try another format.
Check the connection before retrying; saved movies remain available offline.

Subtitles show a loading state until usable text arrives. If a subtitle cannot
load, **Retry Subtitles** tries that choice again and **Turn Subtitles Off**
clears it. The menu includes embedded subtitles exposed by the device and
separately saved or server-provided text. Separate text is drawn inside
rustyView; it does not appear in Picture in Picture or AirPlay video. The player
explains that limitation before you start those output modes.

Playback pauses for audio interruptions and when an audio device disconnects.
After an interruption, it resumes only when iOS permits it and you have not
changed the playback intent. A movie opened during the interruption stays
paused until you choose Play. If iOS restarts its audio services, rustyView prepares the current movie
at its retained position and waits for **Play**. Now Playing and remote
controls follow the current movie's position, speed, and play/pause state;
closing the player releases those controls.

## Download now, watch later

Open a movie, tap **Download**, and choose **Compatible copy** for a version
prepared for playback on your device. Choose **Original file** when you want
the source file and know your device can play it. Selecting either option
starts the download immediately. The choice shows the selected audio, quality,
and what the copy preserves. Source-file size and estimated output size are
labelled separately; some copies have no reliable size until downloading.

**Downloads** and movie details show preparation progress and bytes received.
Once the final size is available, they also show transfer percentage and bytes
remaining. Pause and cancel acknowledge the tap immediately while saving progress
or removing the transfer. Once the movie is
marked **Ready to Watch**, play it from that tab or tap **Watch Offline** on its detail
page—even in airplane mode.
Progress updates are coalesced to reduce rendering work, and optional preparation
polling stops when it is finished or the app is in the background. For battery
reports and measurement instructions, see [Energy diagnostics](docs/ENERGY_DIAGNOSTICS.md).
Each movie appears once. If you keep both original and compatible versions,
open its actions menu and choose **Manage Copies** to play or delete a specific copy.
Your offline movies remain accessible after forgetting the server connection.
Open a saved movie to see its local details, included audio and subtitles, and
chapters. **Watch Online** remains available when connected, with its own audio
and quality choices. A local playback failure never silently switches online.
Transient download failures retry automatically up to six times; after that,
choose **Retry Now** when your connection is available.
Failed requests and their selected format remain in the queue across relaunches
until you retry or remove them. Retry requires the account that requested the
download.

rustyView inspects downloaded video before marking it ready. An original that
the device cannot play remains stored with that limitation shown. You can
download a compatible copy while keeping the original. Inspection checks the
media structure and sample decoding; an actual playback failure still offers
recovery. Older copies are checked again locally, and older copies without
account information stay accessible in Downloads without being attached to a
new account's library.

Downloads can continue in the background. If you force-quit rustyView, reopen
it to let transfers continue. Pause a transfer and resume it later; rustyView
preserves transferred bytes when the server and system support resumption.
An older server or a changing prepared file may require a fresh transfer, which
the queue explains. To save mobile data, select **Wi-Fi Only** under
**Settings → Download Network**. Waiting for Wi-Fi, a paused download, and a
scheduled retry have distinct states. A small number of transfers run at once;
the rest remain queued. Choose **Delete Download** from a copy's actions menu to free space on
your device; your server's original stays in your library. Saved-file storage
includes local posters and subtitles as well as video.

Search Downloads by title or saved description, and sort by recently saved,
title, or time remaining. Each row shows a concise status and one playback or
transfer action; other choices stay in its actions menu. Deleting
a copy requires an explicit confirmation and does not remove its favorite or
viewing history. If saved-library storage cannot be read or updated, the app
shows a recovery action and preserves the existing files.

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

## TestFlight builds

TestFlight distribution requires an Apple Developer Program membership and an
App Store Connect app record matching the bundle identifier in `Local.xcconfig`.
Keep the signing team in that ignored file so regenerating the project preserves
it without checking private deployment identity into source control.

Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, incrementing
the build number for each upload, then run `xcodegen generate`. Select the
`rustyView` scheme and **Any iOS Device (arm64)** in Xcode, choose **Product →
Archive**, and use Organizer's **Distribute App → App Store Connect** flow.
After processing, add the build to a TestFlight group in App Store Connect.

The app bundles `PrivacyInfo.xcprivacy` for app preferences, owned-file metadata,
download space checks, and playback timers. Its encryption declaration covers
Apple-provided HTTPS, Keychain, and CryptoKit; review both declarations when adding
new APIs, data collection, or dependencies. Before inviting external testers,
provide Apple with a reachable demo server, synthetic media, and dedicated review
credentials through the private TestFlight review information.

See [Apple's TestFlight guide](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/).

## License

Copyright 2026 rustyView contributors.

Licensed under the [Apache License, Version 2.0](LICENSE).
