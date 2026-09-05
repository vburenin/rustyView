# rustyView

rustyView is a native iPhone and iPad client for a rustyDLNA server. It browses
the video catalog, streams original or server-prepared compatible media, and
keeps downloaded movies available offline.

The viewing flow includes flat-library and folder browsing, search and sorting,
authenticated artwork, resume, quality selection, first-class audio-track
selection, server-converted sidecar subtitles, chapters, native seeking and
custom transport controls with double-tap 10-second seeking, a buffered
scrubber, playback speed, fit/fill, Picture in Picture, AirPlay, Now Playing controls,
multi-stage recovery to portable H.264/AAC, and background offline downloads.
Credentials are confined to the configured HTTPS origin and the password is
stored only in Keychain.

Selected downloads enter a system-owned background queue and remain visible in
the Downloads tab with queued, progress, retry, saving, and failure states.
Compatible downloads show exact prepared media time and percentage when the
server reports completed output-fragment timestamps, alongside transferred
bytes when available. The same truthful progress appears on movie details and
in Downloads; unknown output size is never presented as a stuck `0%`.
Transient failures are rescheduled with backoff. Cellular downloads are allowed
by default; choose **Settings → Download Network → Wi-Fi Only** to disable them.
Transfers can continue while the app is suspended, but no app can transfer data
while the device is fully powered off; queued work resumes when iOS can run it.
iOS also cancels background transfers when the user explicitly force-quits the
app, so rustyView must be reopened before downloads can continue.

## Development

The project is generated with XcodeGen:

```sh
xcodegen generate
xcodebuild -project rustyView.xcodeproj -scheme rustyView \
  -destination 'generic/platform=iOS Simulator' build
```

To launch it interactively:

```sh
xcodegen generate
open rustyView.xcodeproj
```

In Xcode, select the `rustyView` scheme and an iPhone or iPad simulator, then
press Run (`Command-R`). On first launch, enter the server's HTTPS address and
HTTP Basic credentials. The password is stored in Keychain and is never written
to preferences. The repository intentionally contains no production endpoint,
account name, signing identity, or media-library metadata.

Before committing, run the repository privacy check:

```sh
scripts/privacy_check.sh
```

This checkout is configured to run the included Git hook against the exact
staged snapshot automatically. After a fresh clone, enable it with
`git config core.hooksPath .githooks`. Local
endpoints, signing values, captures, and other machine-specific files belong
only in the ignored paths documented by `.gitignore`.

The checked-in build configuration uses a generic bundle identifier. Developers
who need a stable signing or installed-app identity can copy private overrides
into the ignored root-level `Local.xcconfig`:

```xcconfig
RUSTYVIEW_BUNDLE_ID = com.example.private.rustyView
RUSTYVIEW_DEVELOPMENT_TEAM = YOUR_PRIVATE_TEAM_ID
```

## Verification

The unit suite exercises actual JSON decoding, authenticated HTTP requests,
origin confinement, exact folder/search/sort requests, stale-response races,
prepared-stream URL construction, resume persistence, WebVTT parsing, and
atomic installation, integrity validation, and deletion of real temporary
files. The UI journey runs against a local authenticated HTTP server and real
synthetic H.264/AAC media; it proves folder navigation, rotation, selected-audio
routing, copied-stream failure and portable fallback, a rendered WebVTT cue, a
real HTTP 503 followed by automatic retry, a transfer completed while the app is
suspended, and local playback after a disconnected process relaunch with no
network request. It also verifies generation-scoped transcode polling and the
rendered timestamp-based preparation percentage. Additional UI checks run Apple's accessibility
audit and exercise core navigation at the largest accessibility text size.
The journey also verifies AVFoundation's Basic-auth challenge flow, real
AVPlayer play/pause and ten-second position changes, a long-range seek against
a growing EVENT playlist, 44-point primary player targets, audio, captions,
speed, chapters, and the buffered scrubber.

```sh
xcodebuild test -project rustyView.xcodeproj -scheme rustyView \
  -destination 'platform=iOS Simulator,name=rustyView Test iPhone'
```

Keep that device dedicated to automation. UI tests terminate the app process and
must not run on a Simulator being used for real-library background downloads.

See `AGENTS.md` for the project contract, architecture, test standards, privacy
rules, server API notes, and required real-device release checklist.

## License

Copyright 2026 rustyView contributors.

Licensed under the [Apache License, Version 2.0](LICENSE).
