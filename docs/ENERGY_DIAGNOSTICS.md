# Download energy investigation

Download preparation runs on rustyDLNA. The phone receives the file, updates
progress, and verifies the completed local media. A useful investigation separates
radio activity, rendering, and file verification instead of treating all download
time as the same workload.

## Changes and evidence

The released build 1.0 (3), commit `45c2746`, decoded the complete task description
on every native byte-progress callback and forwarded each update through
`DownloadManager` and `AppModel` to SwiftUI. Preparation polling also continued
after the server reported `ready`, with a one-second scheduling loop even when
no optional request was due.

The updated implementation:

- Caches each active task's decoded envelope and removes it at completion.
- Coalesces media progress before the MainActor hop, at most four updates per
  second per transfer, with a trailing update when the connection becomes quiet.
- Stops optional status requests when preparation is complete. Unknown final
  lengths retain the existing bounded HEAD discovery behavior.
- Sleeps until the next actual polling deadline, preserving the shared request
  budget, retry deadlines, and server backoff hints.
- Suspends optional polling and UI byte updates in the background. Background
  URLSession delivery, size enforcement, durable completion, and cancellation
  continue. Foreground presentation catches up from retained byte samples.
- Keeps full compressed-sample verification and decoder checks. These are needed
  to reject truncated or unusable offline files and are now marked separately
  in Instruments.

The tests use authenticated loopback HTTP, generated MP4 media with a valid
padding atom, and the actual Downloads screen. The measured burst sends part of
a file over 1.5 seconds, then keeps the response open. Results describe this
controlled workload, not an estimate of battery life during a feature film.

Initial component measurements reduced progress publications from 40 to 7.
With the actual Downloads screen rendered, three Simulator runs reduced the
mean process CPU time from 0.375 to 0.119 seconds over the same 2.5-second window.
On an iPhone 17 Pro Max running iOS 26.6.1, three runs with an isolated profiling
app reduced mean process CPU time from 0.711 to 0.199 seconds, about 72%. Mean
app-wide publications fell from 61.3 to 7. The ordinary installed app and its
download storage were not replaced by this profiling app.
The first regression also observed two unnecessary status requests in seven
seconds after preparation completed; the updated code makes none.

`DOWNLOAD_ENERGY_PROFILE` lines in the test log report CPU time and publication
counts. CPU time includes the in-process synthetic HTTP server and test harness.
Compare repeated runs on the same device; the numbers are not battery percentages.

## Capture the reported problem on a tester's phone

Record the app build, phone model, iOS version, Wi-Fi or cellular connection,
whether the screen stayed on, whether playback ran too, and whether the phone
was charging. Note the phase when the phone became warm: preparation, transfer,
or final verification. An idle sample and a download sample make a useful pair.

On iOS 26 or later, testers can capture the current TestFlight build without a
new app feature: enable Developer Mode, open **Settings → Developer → Performance
Trace**, select **Power Profiler**, and enable rustyView in the monitored apps.
Add **Performance Trace** to Control Center, start a recording, reproduce the
problem, and stop. Share the resulting trace from the Performance Trace settings.
Apple documents this workflow in [Power Profiler](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler)
and demonstrates it in [Profile and optimize power usage in your app](https://developer.apple.com/videos/play/wwdc2025/226/).

For a meaningful background battery comparison, record untethered on battery
power. A charging device reports zero overall system power usage, and pairing
with Xcode keeps Apple silicon awake. Keep brightness, network, rendition, file,
and starting thermal conditions comparable between runs. These constraints are
explained in Apple's [Power Profiler documentation](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler).

## Locate the expensive phase

In Instruments, target rustyView and combine Power Profiler with Time Profiler
and the app's Points of Interest. Compare app CPU, GPU/display, and networking
impact over the same interval. Use Network Connections when radio/networking
dominates, and File Activity when the final verification interval dominates.
For broader field trends, inspect Xcode Organizer's battery and performance
reports; Apple's [battery analysis guide](https://developer.apple.com/documentation/xcode/analyzing-your-app-s-battery-use)
also describes MetricKit metrics for CPU, GPU, disk, and network activity.

The app emits these phase markers without media names, URLs, or credentials:

| Marker | What it isolates |
| --- | --- |
| Download UI Progress | Published byte-progress changes that can cause SwiftUI work |
| Download Preparation Status | Optional server-status request duration |
| Download Final Size Request | Header-only discovery of completed output size |
| Download File Received | End of URLSession file delivery |
| Download File Verification | Whole local-media integrity/playability inspection |
| Verify Compressed Samples | Reading indexed compressed samples for truncation checks |
| Verify Decoded Samples | Decoder checks near the beginning and end |
| Download State Write | Durable JSON encoding and atomic state write |
| Download Storage Inventory | Managed-file size inventory |
| Downloads Background / Foreground | Application lifecycle boundaries |
| Download Pause / Cancel Requested | User action acknowledgement |

Tracing is local; the app does not upload telemetry. Keep real-device captures
in private diagnostic storage. Repository fixtures and shareable regression
captures use invented media and a synthetic server.

## Reproduce the software checks

Use the dedicated test Simulator, never the owner's manually operated preview:

```sh
xcodegen generate
xcodebuild -project rustyView.xcodeproj -scheme rustyView \
  -destination 'platform=iOS Simulator,name=rustyView Test iPhone' \
  -parallel-testing-enabled NO \
  -only-testing:rustyViewTests/DownloadByteTotalsTests \
  -only-testing:rustyViewTests/DownloadPollingTests \
  -only-testing:rustyViewTests/DownloadProgressDeliveryTests test
```

For repeatable rendered CPU samples, select
`DownloadByteTotalsTests/testRenderedDownloadProgressProfile` and use
`-test-iterations 3`. The test displays a real Downloads view backed by an
isolated store and loopback transfer. Setting `RUSTYVIEW_ENERGY_TRACE_HOLD=1`
in the test host's environment adds a twelve-second attachment window before
the measured burst. It changes no production app behavior.

The coverage also checks final-size discovery, quiet-connection trailing bytes,
retired attempts, foreground catch-up, pause/cancel persistence failures,
scheduled retries, and the shared optional-request budget. A Simulator or a
charging-device CPU measurement cannot prove battery-life improvement. Confirm
the original user's symptom with comparable untethered power traces.
