# rustyView contributor guide

This file applies to the entire `rustyView` repository.

## Product mission

rustyView is a native SwiftUI client for the owner's rustyDLNA video library. It
must feel at home on both iPhone and iPad, stream movies over the network, and
download movies for reliable playback when the device has no connectivity.
Treat browsing, playback, downloads, resume position, and authentication as one
cohesive product rather than independent demos.

## Current implementation snapshot

- The deployment target is iOS 17. The app is SwiftUI with a custom,
  accessibility-labeled control overlay on an `AVPlayerLayer`; AVFoundation
  still owns decoding, external playback, AirPlay, and Picture in Picture. The
  player supports tap-to-show controls, three-second auto-hide while playing,
  double-tap left/right and explicit buttons for 10-second seeking, a buffered
  scrubber, speed, fit/fill, audio, captions, chapters, and stream quality. It
  exposes buffering and error states and restarts cleanly after reaching the
  end. It has no third-party runtime dependencies.
- `project.yml` is the source of truth for the generated Xcode project. Run
  `xcodegen generate` after changing targets, resources, or build settings.
- `AppModel` owns connection settings, the API client, library state, playback,
  and downloads. It deliberately forwards each child model's change publisher
  because SwiftUI does not observe nested `ObservableObject` instances by
  itself.
- Streaming first attempts an authenticated original where appropriate, then
  recovers through server-prepared HLS and, if a copied stream still fails, a
  forced portable H.264/AAC rendition. A non-Auto quality choice always uses
  the prepared route so the explicit choice is not ignored. A non-default
  audio selection also enters the prepared route, ensuring the chosen server
  track is honored instead of silently playing the source default. AVFoundation
  authentication is supplied through the asset resource loader and is confined
  to the configured server origin. Prepared EVENT playlists are treated as
  moving seek windows: a scrub outside the advertised window starts a fresh
  prepared stream at the requested global time. A bounded startup watchdog
  retries or falls back instead of leaving the player stuck on Preparing.
- Browsing supports the flat movie library and navigable server folders, with
  breadcrumbs, debounced search, server sorting, paging, and stale-response
  suppression.
- Compatible offline downloads use a background `URLSession`, install a
  self-contained MP4 into Application Support, update an atomic manifest, and
  play from a local file URL without recontacting the server. Manifest records
  are validated against their files at launch; missing, empty, truncated, and
  path-escaping entries never become playable. Background task metadata also
  preserves the server path and retry attempt. Transient transport, rate-limit,
  timeout, and server failures create a new system-owned background task with
  bounded exponential backoff, so retry scheduling survives app suspension.
  Downloads exposes queued, live progress, retrying, saving, failed, and
  completed states. While compatible output is being produced, the client
  polls its generation-scoped status and shows exact prepared media time
  against the known runtime on both movie details and Downloads; it falls back
  to byte progress against older servers and never labels unknown-size work as
  zero percent. Cellular downloads are allowed by default; the persisted
  Settings choice can restrict current and future movie downloads to Wi-Fi.
  The rendition menu is the final download decision: selecting Compatible copy
  or Original file must enqueue immediately, without a second confirmation.
  Active rows navigate to movie details; nested cancel controls must use an
  isolated button style so a row tap can never cancel a download.
- The UI-test target contains only generated H.264/AAC MP4 and MPEG-TS media.
  Each UI test must use a unique background-session and offline-store namespace,
  and must terminate the test-launched app during teardown. Tests must never
  restore synthetic tasks into the developer's normal Simulator session.
  Its in-process HTTP server requires Basic authentication and serves real JSON,
  byte responses, WebVTT, and a growing EVENT HLS playlist. It proves folder
  navigation, rotation, selected-audio routing, multi-stage codec fallback,
  AVFoundation's unauthenticated challenge followed by authenticated segment
  access, long-range scrub restarts at the requested global time, rendered
  subtitle cues, download installation, zero-request playback after a
  disconnected process relaunch, and real AVPlayer position changes from
  double-tap seeking. Separate audits cover accessibility semantics, contrast,
  hit regions, clipping, and the accessibility-XXXL layout. Keep these checks
  semantic and end-to-end.
- Simulator coverage is a development gate, not a substitute for the real-device
  checklist at the end of this file.

The app is a client of rustyDLNA. Do not duplicate the server's scanner,
catalog, compatibility, or transcode policy in this repository. If a protocol
change is truly required, make it in the sibling `../rustyDLNA` repository under
that repository's `AGENTS.md` rules and preserve compatibility with the web
player.

## Environments and server access

- Production endpoints, host addresses, and account names are private and are
  provided to authorized developers out of band. Never place them in source,
  fixtures, logs, screenshots, defaults, or checked-in configuration.
- The production service is protected by HTTP Basic authentication at its
  reverse proxy. Never place its password in source, fixtures, logs,
  screenshots, defaults, or checked-in configuration.
- Store credentials only in the Apple Keychain. Allow the user to enter or
  update them in the app. Local developer overrides must be ignored by Git.
- Production host access details and deployed paths must remain in private,
  ignored developer configuration rather than repository documentation.
- The authoritative local server source is the sibling directory
  `../rustyDLNA`. Inspect it before guessing at routes or response fields.
- The production media library is user data. All investigation of it is
  read-only. Never rename, modify, delete, or reorganize media or sidecars.
- Never put real movie names or other identifiable production-library metadata
  in source code, tests, fixtures, snapshots, screenshots, documentation, issue
  text, sample data, logs, or generated previews. Use clearly invented titles
  and synthetic metadata everywhere in the repository.
- Do not restart, rebuild, redeploy, or alter the production server unless the
  user explicitly asks for that operation.

## Current rustyDLNA client contract

The embedded web API currently uses JSON schema version `2`. Reject an unknown
schema version with a useful compatibility message; decode additive unknown
fields without failing.

Important endpoints include:

- `GET /api/web/library` for paginated library, folder, search, sort, and
  capabilities data. IDs are decimal strings and must not be coerced through a
  lossy numeric representation.
- `GET /api/web/item/{id}` for full item and playback metadata.
- `GET /web/download/{id}` for the original indexed video file.
- `GET /web/media/{id}.mp4?...` for original or server-prepared compatible
  playback.
- `GET /web/media/{id}.m3u8?...` and its advertised fragment URLs for prepared
  HLS delivery where appropriate.
- `GET /api/web/transcode/{id}` plus its POST/DELETE lifecycle operations for
  prepared-stream status and cancellation. Schema v2 exposes state, an
  optional retry delay, and additive optional `produced_seconds`, measured from
  complete output-fragment timestamps. Combine `produced_seconds` with the
  catalog runtime for truthful prepared-time progress; never substitute elapsed
  wall time or bytes when the server omits it.
- Caption, artwork, and preview URLs are server-provided. Consume the URL from
  the response rather than synthesizing one when a field is available.

Consult `../rustyDLNA/crates/server/web/api.js`,
`../rustyDLNA/crates/server/src/web_ui.rs`, and
`../rustyDLNA/docs/WEB_PLAYER.md` for the exact current query parameters,
payloads, and prepared-stream behavior. The production host may run a newer
compatible build than the local checkout, so also validate response shapes
against read-only production requests when needed.

Every request, including artwork, captions, byte ranges, redirects, HLS
playlists/segments, and background downloads, must preserve authentication
without leaking credentials to a different origin. Only send credentials when
the normalized URL has the configured server's HTTPS origin. Reject redirects
to an untrusted origin.

## Apple platform and project conventions

- Build a native SwiftUI application with shared behavior for iPhone and iPad.
- Use Swift concurrency and make UI-owned observable state main-actor isolated.
- Keep networking, persistence, playback, downloads, and views in separate
  components with small testable interfaces.
- Prefer Apple frameworks (`URLSession`, `AVFoundation`, `MediaPlayer`,
  `BackgroundTasks`, `Network`, `Security`) before adding dependencies.
- Use `Codable` DTOs only at the wire boundary. Map them into stable domain
  models so server additions do not spread optional/stringly typed state
  through views.
- Use `Decimal String`/`String` media identifiers end to end.
- Support Dynamic Type, VoiceOver labels, keyboard navigation on iPad, light
  and dark appearance, safe areas, and touch targets of at least 44 points.
- Do not hard-code the production URL or account into ordinary app behavior.
  Ship it only as an editable initial suggestion if the product owner requests
  that convenience.

## Browsing and presentation

- Optimize for a person who wants to find and watch a movie, not for someone
  who understands DLNA or codecs. The primary path from launch to playback must
  be obvious, forgiving, and require as few decisions as practical.
- Preserve server pagination, generation checks, folder breadcrumbs, search,
  and sorting semantics. A stale page from an older request must never replace
  the result of newer navigation.
- Use poster artwork where available and a deliberate placeholder otherwise.
  Load and cache images with bounded concurrency and cancellation.
- On compact-width phones, keep the three-column poster grid only through the
  default Dynamic Type size. Larger text categories must use wider two-column
  portrait cards with unconstrained vertical title space so titles cannot draw
  over runtime or resolution metadata. Accessibility-size tests must use the
  real UIKit content-size category raw values and assert layout geometry.
- Keep selected item, browse position, and playback state stable across iPhone
  rotation and iPad split-view changes.
- Display human-readable titles first, with technical stream information as
  secondary detail. Do not expose server filesystem paths.
- Prefer familiar labels such as Watch, Download, Audio, Subtitles, and Quality;
  keep terms such as remux, MIME, and transcode inside optional technical detail.
- Every long-running action needs immediate feedback, useful progress where it
  exists, safe cancellation, and a plain-language recovery action. Never leave
  a tap looking ignored.
- Empty, offline, first-launch, authentication-failure, no-search-result,
  low-storage, and no-download states each need purposeful UI rather than a
  blank list or generic alert.
- Persist favorites, recents, resume positions, and download state locally.
  Namespace them by normalized server identity plus media ID so another server
  cannot collide.

## Streaming and codec strategy

Support the broadest practical codec set through two complementary paths:

1. Prefer direct `AVPlayer` playback when the original container and selected
   streams are supported by the OS. This preserves quality and avoids server
   work.
2. Fall back to rustyDLNA's prepared streaming for unsupported containers,
   video codecs, audio codecs, malformed timestamps, or an explicit quality
   choice. Let the server copy compatible streams and transcode only what is
   required. Do not maintain a second hand-written codec policy that can drift
   from the server.

Prepared H.264/AAC MP4 or HLS is the portable baseline. HEVC/HDR should remain
available when both the device and the exact server output support it. Use
`AVAsset`/`AVFoundation` capability results as advisory and retain a portable
fallback after real playback failure.

For offline playback, downloading the original alone is not sufficient for
"as many codecs as possible" because AVFoundation cannot decode every MKV,
audio, or subtitle combination. The durable design must support one or both of:

- an offline-compatible rendition prepared by rustyDLNA and stored as a
  self-contained local asset; and
- a carefully licensed embedded playback engine for original files.

Before adding VLC/FFmpeg-based binaries, document the exact license, App Store
implications, supported architectures, binary size, privacy manifest, and how
updates are pinned. Never silently trade away HDR, surround audio, subtitles,
or resolution; show the chosen offline format and estimated size to the user.

## Offline downloads

- Use background-capable `URLSession` downloads so transfers can continue when
  the app is suspended. Reconcile task identifiers after relaunch.
- Keep all selected downloads visible as queued or active work. Persist enough
  task metadata for the system-owned queue and retry state to be reconstructed
  after relaunch.
- For compatible downloads, poll the generation-scoped transcode status while
  the task is active and show prepared media time plus percentage whenever
  `produced_seconds` and total duration are available. Treat this as an optional
  enhancement so downloads remain functional with an older server.
- Retry transient network failures, HTTP 408/429 responses, and server 5xx
  responses with bounded exponential backoff. Do not endlessly retry permanent
  authentication, missing-media, validation, or storage failures; keep those
  visible with explicit Retry Now and Remove from Queue actions.
- Allow cellular downloads by default and provide an obvious persisted
  Wi-Fi-only setting. Apply a changed policy to already queued transfers as well
  as new ones.
- Store completed media under Application Support, excluded from iCloud backup,
  with an atomic manifest containing server identity, media ID, display title,
  source URL kind, byte count, media metadata, completion time, and integrity
  state.
- Move a finished temporary download into its final location atomically before
  marking it playable. A cancelled, failed, partial, or unverified file must
  never appear as complete.
- Support pause/resume where the server and `URLSession` provide valid resume
  data, retry, cancellation, deletion, storage usage, and low-space errors.
- Downloads must be playable in airplane mode without contacting the server,
  refreshing artwork, or revalidating credentials.
- Cache the metadata and artwork needed by the offline library locally. Keep
  remote deletion independent from local deletion.
- Respect HTTP range and content-length behavior. Treat filenames and response
  headers as untrusted; derive safe local names from app-owned identifiers.
- Protect against duplicate concurrent downloads of the same rendition and
  reconcile orphaned files/tasks at startup.
- Deleting a download is destructive user data behavior: require an explicit
  user action, cancel active work first, and update the manifest consistently.

## Authentication and transport security

- Require HTTPS outside explicit debug-only localhost development.
- Keep Basic-auth material in Keychain with an appropriate accessible class;
  do not copy it into `UserDefaults` or SwiftData.
- Prefer an authentication challenge handler over embedding credentials in a
  URL. Redact `Authorization`, passwords, query tokens, and private media
  metadata from diagnostics.
- Apply a finite timeout and bounded retry policy. Authentication failures,
  offline state, TLS failures, server incompatibility, and missing media need
  distinct user-facing recovery paths.
- Never weaken App Transport Security globally.

## Playback experience

- Provide play/pause, seeking, skip, scrubber time, audio/caption selection,
  playback speed, aspect fit/fill, AirPlay, Picture in Picture, and external
  playback where supported.
- Audio-track selection is a first-class control. Show language, descriptive
  title, codec, channel count, and the server default; preserve the user's
  choice across compatible-stream restarts when that track still exists.
- Subtitle selection must include Off, clearly identify language/forced tracks,
  and support server-converted sidecars as well as embedded tracks when the
  playback engine exposes them.
- Expose chapters as named jump targets and make the active chapter apparent.
- Default to an automatic quality choice, explain data-saving choices in human
  terms, remember the preference, and never silently reduce an explicitly
  selected quality.
- Detail screens should show download size, runtime, resolution/HDR, download
  state, and whether an offline copy is device-compatible before committing
  storage.
- Integrate Now Playing and remote transport commands. Resume positions should
  be updated periodically and on pause/background/end, using media duration to
  avoid saving near-start or near-end noise.
- Preserve playback intent and global time when switching from original to a
  prepared stream. Cancel superseded network/transcode work.
- Surface buffering and errors without obscuring navigation or trapping the
  user in a dead player screen.

## Data and concurrency invariants

- A monotonically increasing request/session identity owns each asynchronous
  browse and playback operation. Late callbacks from older operations are
  harmless.
- Persist state transactionally. Decode network data and perform file I/O away
  from the main actor.
- Bound caches, image work, retries, polling, and parallel downloads.
- Model download and playback states as enums with explicit transitions rather
  than independent booleans.
- Do not force unwrap data originating from the network, filesystem, Keychain,
  media tracks, or restored state.

## Testing and verification

Use deterministic fixtures and protocol stubs for normal tests; production is
only for read-only smoke checks. Do not make tests depend on the owner's live
library or credentials.

Tests must prove real behavior. Do not add string-presence assertions,
tautological mocks, snapshots with no semantic assertions, tests that duplicate
the implementation's calculation, or cases that can pass when the feature is
broken. Exercise public boundaries with realistic synthetic HTTP responses,
temporary directories, actual Codable decoding, URL loading behavior, Keychain
abstractions, file moves, cancellation/race ordering, and app state transitions.
For every regression test, first establish that it fails for the broken behavior
or otherwise explain the concrete fault it detects. A test double may replace a
remote system, but it must preserve the relevant HTTP, concurrency, or failure
semantics instead of returning a prearranged value directly to the assertion.

Every material change should run the narrowest relevant checks and then the
project-level gate. At minimum:

```sh
xcodegen generate
xcodebuild -project rustyView.xcodeproj -scheme rustyView \
  -destination 'generic/platform=iOS Simulator' build
xcodebuild -project rustyView.xcodeproj -scheme rustyView \
  -destination 'platform=iOS Simulator,name=rustyView Test iPhone' test
```

Run UI tests only on the dedicated `rustyView Test iPhone` Simulator. Never use
the manually operated Simulator that may contain real-library background tasks;
test-runner termination can cancel every background session for the app bundle.
Treat the manually operated `iPhone 17` Simulator as the owner's current-build
preview: after a verified app change, install and launch the new build there
when doing so will not interrupt an active download. Preserve its app data
across installs. It is not an automation destination.

If that exact simulator is unavailable, select an installed recent iPhone
runtime and record the destination used. Add focused tests for DTO decoding,
URL origin confinement, auth challenges, pagination races, download state
restoration, manifest atomicity, resume math, and original-to-compatible
playback fallback. UI tests should cover iPhone and iPad layouts plus an
airplane-mode launch into a completed download.

Before considering the product complete, verify on real hardware: authenticated
remote browsing, original playback, prepared fallback for an unsupported MKV or
audio codec, background download/relaunch, offline playback in airplane mode,
captions/audio selection, interruption recovery, Picture in Picture/AirPlay,
and storage deletion.

## Repository hygiene

- Inspect `git status` before edits and preserve unrelated user changes.
- Do not commit build products, DerivedData, credentials, downloaded media,
  xcuserdata, local server settings, or generated secrets.
- Before adding a fixture or snapshot, check that every media title and metadata
  value is synthetic and cannot be traced back to the production library.
- Do not commit or push unless explicitly requested.
- Use `apply_patch` for hand-authored file changes. Generated Xcode project
  changes may come from the checked-in XcodeGen specification.
- Prefer a small dependency surface. Pin any dependency and record why it is
  necessary.
- Update this guide and user-facing documentation when architecture or the
  server contract materially changes.
