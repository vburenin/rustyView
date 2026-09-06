# Review implementation evidence

This tracks implementation of [REVIEW_FIX_PLAN.md](REVIEW_FIX_PLAN.md). An item
is complete only after its behavior and relevant tests are verified. The review
plan remains the scope, subject to the owner's subsequent narrowing recorded
below; this file does not replace its acceptance criteria.

## Delivery status

| Milestone | Packages | Current status |
| --- | --- | --- |
| A | 01–04, identity/migration design for 10 | Simulator gate passed; hardware checks remain |
| B | 05–07, 09–13 | Simulator gate passed; hardware/Linux checks remain |
| C | 08, 14, 17, 18, 20 | Simulator gate passed; hardware/usability checks remain |
| D | 15, 16, 19, 21 | Simulator checks verified across full run and focused corrections; device/platform limits remain |

The final implementation passed XcodeGen generation, the generic Simulator
build, final privacy/whitespace checks, and 249 component tests. Across the full run and focused corrections,
41 distinct UI tests passed; two platform-dependent cases were skipped.
Default and Extra Large are the retained screen-review sizes, alongside the
original accessibility smoke checks. This does not certify every font size or
real-device behavior.

The full run, `/tmp/rustyView-D-project-gate-20260906.xcresult`, finished with
38 UI passes, three failures and two skips. The three failures were corrected
in tests only: expand the native half-height Playback Options sheet before
inspecting Apply, reveal the entire landscape caption row, and measure the
padded About header's ink support against non-background pixels. Independent
header pixels measured 7.567:1 contrast; the narrow label allowlist and 4.5:1
threshold remain unchanged. All three corrected cases passed on unchanged
production code in `/tmp/rustyView-D-ui-navigation-followups.xcresult`
(138.390, 75.141 and 84.203 seconds). This is verification across those runs,
not a claim that the full run had no failures. Native Escape injection and
unavailable Picture in Picture controls remain documented platform skips.

An earlier interrupted full run,
`/tmp/rustyView-D-project-final-corrected.xcresult`, found a batched-callback
assumption in the native resume test. Its prerequisite now waits for positive
native bytes, while retaining actual nonzero Range resumption and correct
whole-file totals. The other 248 component cases passed in that run. The
corrected case passed three consecutive runs (4.394, 4.163 and 4.130 seconds)
in `/tmp/rustyView-D-native-range-timing.xcresult` before the final full run.

## Identity and persistence design (before the durable queue)

- Server identity lowercases scheme/host, removes default ports and trailing
  slashes, and retains the deployment path. Different deployment paths and
  nondefault ports stay distinct. This does not change advertised API routes.
- Network ownership additionally requires the exact trimmed account name.
  Credentials remain exclusively in Keychain and live request authentication;
  queue and manifest records contain no password or Authorization header.
- Old records without an account remain explicitly unassigned. They remain
  accessible from Downloads, but a connection does not automatically claim
  their catalog associations or authorize retry. Equivalent legacy server keys
  may be canonicalized without changing record/file IDs or assigning an account.
- A completed original and compatible rendition may coexist. Reconciliation
  must not delete an original as a prerequisite for obtaining a playable copy.
  Conflicting legacy entries are retained; UI selection prefers a suitable
  inspected copy, then newest completion, with a deterministic ID tie-break.
- Queue intent is independent of system tasks. Versioned atomic journal writes
  precede task creation. Stable record IDs reconcile a task created before its
  identifier was saved. Failure and removal are durable; removal tombstones
  prevent a late task from resurrecting the user's cancelled request.
- Completed manifests migrate additively. Stored-byte integrity and inspected
  device playability are separate; legacy bytes are unverified until inspected.
  Failed compatible validation cannot publish Ready to Watch. Unsupported
  originals remain stored with an honest state.
- Progress migration preserves unassigned legacy history and resolves equivalent
  old keys by most recent update, without merging different accounts. No migration
  deletes user media or retargets authentication.

## Verification log

- Initial inspection: only the user-provided untracked REVIEW_FIX_PLAN.md was
  present as a worktree change. Implementation started from commit ff9403c.
- Available dedicated automation destination: `rustyView Test iPhone`, iOS 26.5.
  iOS 17 is not installed. No tests run on the owner's `iPhone 17` preview.
- New identity regression exercises real connection parsing and URL resolution:
  prior host-case/default-port variants produced different storage keys; account
  ownership must reject unassigned and other-account work.
- Milestone A test build passed. The first unit run found that AVFoundation
  rejected valid media with URLSession's temporary filename extension. A focused
  same-bytes test established that `.mp4` worked while `.tmp` and extensionless
  files failed. The fix supplies a public MIME parser hint and still requires
  real sample inspection; external asset references are forbidden.
- After that fix, all 88 unit tests passed on the dedicated iPhone, including
  real Basic-auth HTTP failure/relaunch/retry/installation and a real injected
  out-of-space move failure. Result:
  `/tmp/rustyView-review-gate/Logs/Test/Test-rustyView-2026.09.05_13-38-16--0700.xcresult`.
  Newer follow-up changes still require the final gate.
- The first focused pause/stall UI run exposed paused-intent recovery and
  duplicate accessible Retry controls. The player now defers recovery while
  deliberately paused and removes normal controls from the terminal-error
  hierarchy. A short, growing multi-segment EVENT fixture exercises actual
  advancement, stalled delivery, bounded failure, and successful user retry.
- Final milestone A gate passed: XcodeGen generation, generic Simulator build,
  and the complete dedicated iPhone suite: 98 unit tests and 11 UI tests passed;
  one PiP UI test skipped because the control was unavailable in Simulator.
  This is not a PiP verification. Result:
  `/tmp/rustyView-review-gate/Logs/Test/Test-rustyView-2026.09.05_13-51-59--0700.xcresult`.
- The full journey proved authenticated browsing, original/prepared/portable
  fallback, stable prepared-session generations, long-range seeking, captions,
  download installation, disconnected process relaunch, local playback without
  requests, and explicit deletion. Focused UI faults proved paused preparation,
  retry after a real delivery stall, and compatible recovery retaining an
  unreadable original.
- Privacy and whitespace checks passed during A development. Final checks will
  run again after implementation settles.

## Milestone A regression evidence

| Package | Verified evidence | Remaining device verification |
| --- | --- | --- |
| 01 | URL-loading tombstones, independent viewers, frozen credentials and heartbeat; real HLS seeks/close use one session and newer generations | Remote streaming and long pause/reconnect |
| 02 | Intent state, nonfinite-time watchdog, actual local repair/retry; real paused-preparation and stalled-stream UI preserve quality/audio/global time | Interruptions and network changes on hardware |
| 03 | Real HTTP401/expired generation/relaunch/retry; wrong-account refusal; actual out-of-space failure/recovery; journal/task reconciliation; four move-barrier cancellation races | System-owned background completion and suspension |
| 04 | Actual valid, garbage, truncated, unsupported and changed media; safe temp filenames/symlinks; UI retains original and installs ready compatible copy | Device codec availability and airplane-mode playback |

Known follow-ups retain their original milestone scope: resume data and network
waiting (09), source-aware offline details and local failure recovery (05), file
transaction recovery and storage I/O off the main actor (11), OS background
callback ownership (12), and scheduler/polling bounds (13). These are not claimed
complete by the A queue or asset-inspection tests.

In particular, B11 must replace the queue's shared `removed` terminal state with
distinct completion and cancellation/deletion intent. A process ending after a
cancellation journal write but before installation rollback can leave a manifest
record; recovery needs a defined commit point across both files. Live installation
lock tests do not prove process-death recovery. Old ambiguous terminal entries
must never cause blind deletion of completed user copies during migration.

## Integration boundaries for B

These are implementation constraints for the next milestone, not shipped claims:

- Stable, locally persisted movie metadata must contain the display information,
  chapters, and included track descriptions needed without a server DTO or request.
  Download records retain owned local artwork/caption paths with safe names.
- A single source-aware playback request must route Watch, Resume, Start Over,
  and chapters to the selected local or online source. Local errors do not spend
  network data; online quality/audio controls must create an online request.
- Package installation and deletion need recoverable transactions, including
  supplemental files and logical queue ownership. Cancellation/deletion intent
  and successful completion have different recovery precedence. Storage work
  moves off the main actor while serialization is retained.
- The durable scheduler must preserve resume data, validators, retry deadlines,
  attempt identity and credentials confinement. Resumed HTTP206 validation uses
  the whole-file Content-Range total when available, not the remaining response
  body's Content-Length as the size of the assembled file.
- Session reconnection and OS completion handlers must be keyed by background
  session identity independently of sign-in. Pending work requiring credentials
  stays actionable; already delivered data can be processed durably.
- Transfer bounds and optional preparation-status polling use shared budgets.
  Queued jobs stay durable and can advance from background completion callbacks.
  Optional progress does not replace the server's ownership heartbeat contract.
- Native local audio/legible selection groups determine included choices;
  per-server track indices are not assumed to survive into a rendition. Sidecars
  and chapters must work after disconnected relaunch with zero remote requests.

## Milestone B work and focused evidence

- A metadata cache stores stable presentation models under canonical library,
  account, and decimal-string movie identity. Reads, writes, and local poster
  downsampling run away from the main actor. The original verified A app binary
  was preserved outside the repository for later performance comparison.
- A real delayed HTTP401 reproduced an account-switch defect in the original
  client: the pending request authenticated as the replacement account. The same
  test passes with an immutable delegate per request. Additional real listeners
  verify that a foreign-port redirect and a caller-supplied foreign request receive
  no request, old queued credentials are not reused after an account change, and
  repeated authentication failure retains an actionable error category.
- Those four HTTP tests and three disk-cache tests passed in a temporary macOS
  Swift package using copied application sources. The failing original-client
  result is `/tmp/rustyView-request-ownership-prefix.log`; the seven-test fixed
  result is `/tmp/rustyView-request-ownership-postfix.log`. These focused host
  checks do not replace the upcoming iOS Simulator gate.
- New local-detail navigation, package posters/captions, source-aware playback,
  native audio/subtitle options, pause/resume/waiting controls, encrypted resume
  storage, atomic file transactions, and a bounded background scheduler are being
  integrated and are not yet verified as a complete B journey.
- Background URLSession does not invoke the ordinary redirect or connectivity-
  wait callbacks used by foreground sessions. B verification must exercise its
  actual behavior; an implemented delegate method alone is not confinement proof.
  Resume support also requires actual validators/range behavior, and growing
  prepared output must never be mistaken for a complete resumed file.
- The first complete B run passed XcodeGen, the generic Simulator build, and
  all 143 unit tests, including both real TLS-origin cases. Of 13 UI tests,
  nine passed, three failed, and PiP skipped. Result:
  `/tmp/rustyView-review-gate/Logs/Test/Test-rustyView-2026.09.05_14-25-27--0700.xcresult`.
  Two failures were obsolete audio/chapter selectors; the third detected a real
  transition that replaced live media-byte progress when an auxiliary caption
  finished. Fixes retain real timeline advancement and zero-request assertions.
  This failed run does not close B; focused verification and a new full gate follow.
- Additional storage review exercises removal before a rejected receipt reaches
  the index, readable-index startup errors, and missing-resource recovery. An
  explicit Remove must reclaim owned incoming bytes immediately, and rebuilding
  a corrupt index must never be offered for an ordinary write failure.
- Native background resumption passed real byte-range checks in both network
  policy directions, relaunch, changed validators, denied ranges, invalid opaque
  resume data, and unknown-total growing HTTP206 output. The sibling server now
  supplies stable ETag/If-Range behavior for original and completed compatible
  files; growing output remains intentionally unvalidated. Older servers still
  work but may require a fresh transfer. No server was deployed or restarted.
  The sibling HTTP crate's 36 tests, its Clippy check, 46 web tests, and 86 Python
  tests passed. The complete workspace Rust gate is blocked on this Mac by its
  Linux-only inotify/kcmp dependencies; Linux verification remains required.
- Final B gate passed: XcodeGen generation, generic Simulator build, all 150
  unit tests, and 12 UI tests. The PiP UI test remained explicitly skipped on
  Simulator. Result:
  `/tmp/rustyView-review-gate/Logs/Test/Test-rustyView-2026.09.05_14-47-55--0700.xcresult`.
  The full disconnected journey proves local details, actual chapter advancement,
  native alternate-audio selection, rendered saved captions, and zero HTTP requests.
  The main journey includes real retry/background installation, process relaunch,
  sign-out, local playback and deletion into an actionable empty state.
- The final B faults also established that HTTP error-body bytes cannot become
  movie progress, an online resume beyond an inspected local duration is not
  offered offline, and a chapter's full 44-point row responds to a center tap.
  A larger existing real fixture is used for held-response progress checks so
  native URLSession buffering does not hide the test's intended byte transition.

## Milestone C work and focused evidence

- The central user-library store now owns favorites, actual viewing history,
  and resume positions. Atomic file mutations preserve unknown-account legacy
  data, keep completed history separate from resume eligibility, and roll back
  only a failed required Start Over mutation. Fourteen focused storage tests
  passed, including real file reopening, full-disk barriers, read recovery,
  migration, and concurrent favorite changes.
- Ten playback activity/preference tests passed with actual AVPlayer media:
  preparing does not create history, real advancement does, a failed durable
  Start Over preserves the paused asset, and Resume waits for store restoration.
  Explicit quality preferences and language matching are independent of an
  isolated Apply/Cancel draft. The real streaming UI also proved Cancel keeps
  the current producer generation, Apply retains paused intent, and removal of
  a saved server quality profile produces a visible Auto fallback notice.
- Connection recovery tests exercise real URL loading and injected Keychain
  failures. Both setup UI journeys passed: field validation with Next/Next/Go,
  and cancellation of a held HTTP probe before reconnecting and restoring the
  saved account on relaunch. A further native pause regression proved that a
  failed secure resume-data write must become actionable paused/failed intent,
  rather than leaving a cancelled task permanently marked as pausing.
- Four new browse tests passed for complete cached pages, parent anchors and
  pagination generations, delayed old requests, search/sort separation, and
  account/deployment preferences. Existing tests caught and verified a fix for
  initial folder/query choices being cleared when an already configured client
  first loaded. The UI check additionally found that search-result recreation
  discarded a visible scroll anchor; its correction is undergoing verification.
- Six app-level collection tests passed using installed real media and an
  authenticated HTTP listener: an empty remote library plus forgotten account
  still resumes locally after recreation, two accounts with one movie ID select
  different local assets, and an out-of-file online bookmark never becomes an
  offline Resume action. Additional real HTTP checks prove saved online actions
  resolve missing capabilities with frozen account ownership, preserve an explicit
  quality in actual prepared requests, and visibly recover a removed profile.
  An earlier focused result is
  `/tmp/rustyView-review-gate/Logs/Test/Test-rustyView-2026.09.05_15-16-54--0700.xcresult`.
  Its two UI failures remain open at this checkpoint; it is not the C gate.
- Continue Watching UI checks exposed shared List-row navigation and inherited
  accessibility identifiers hiding nested action identifiers. Separate rows and
  explicit accessibility containment corrected those faults. A Start Over check
  also needed to distinguish the durable zero-start intent from a legitimate
  new partial viewing while test interactions take place on a short fixture.
- C20 passed with eight real saved copies, including duplicate display titles,
  disconnected search, actual sort order, source-specific deletion that preserves
  the other rendition, and advancing playback with zero network requests.
- The full offline Continue Watching journey passed after correcting circular
  button hit shapes that discarded corner taps inside the advertised frame. A
  deterministic corner tap now seeks the actual player before completed history
  is checked. Relaunch, Resume, Start Over, Favorites and history remain local.
  The browse journey now also passes details/rotation/search restoration,
  held navigation, complete paginated parent restoration, and empty-folder
  refresh into newly available media.
- The first complete C run passed all 191 unit tests and 16 UI tests, with
  the existing Simulator PiP skip. Two older UI interactions failed: a saved
  bookmark correctly changed Play to Resume, and added preferences moved the
  download-network row below the initial viewport. Updated tests locate the
  exact rendition action and scroll to the setting; both full journeys then
  passed, retaining actual playback, policy changes, deletion and zero-request
  checks. The complete C gate is being repeated. Focused result:
  `/tmp/rustyView-review-gate/Logs/Test/Test-rustyView-2026.09.05_15-55-11--0700.xcresult`.

The final C gate passed XcodeGen, the generic Simulator build, all 191 unit
tests and 18 UI tests, with the existing PiP Simulator skip. Result:
`/tmp/rustyView-review-gate/Logs/Test/Test-rustyView-2026.09.05_15-58-16--0700.xcresult`.
Privacy and whitespace checks passed. The verified app is preserved outside
the repository as `/tmp/rustyView-milestone-c-baseline.app` before D changes.

## Milestone D work and focused evidence

D implementation is integrated, with measured artwork baselines retained below.
The current focused evidence does not close D or establish an all-font UI pass:

- All 42 transport, playback-system, history and download-grouping unit tests
  passed in `/tmp/rustyView-D-font-transport-focused.log`.
- The eight-file offline collection journey passed actual installation, search,
  sorting and deletion in `/tmp/rustyView-D-font-sixth-focused.log`.
- Native-caption OCR verified rendered cue pixels and their removal after Off
  in `/tmp/rustyView-D-keyboard-ocr-diagnostic.log`.

The owner subsequently narrowed the UI review: maximum-font optimization is
overkill. The exhaustive twelve-category expansion has been removed. Routine
screen journeys now use default and Extra Large text, alongside the existing
baseline accessibility audits. The fifteenth extreme-size run was stopped at
that request (exit 73); its partial log is not a completed gate. Before interruption,
Core AX XXXL passed in 187.171 seconds, Core XS in 130.939 seconds, and Empty AX
XXXL in 132.531 seconds. The collection case failed at an obsolete native-search
Close selector; the selector was corrected but has not yet passed a rerun.
The earlier extreme-size
observations below are historical evidence, not outstanding optimization work.
The remaining priorities are concise screens, usable normal-size layouts, and
one visible entry per movie. Default/Extra Large review and the project gate are
still in progress; no all-font or all-orientation coverage is claimed.

The narrowed suite now contains 42 UI tests. The newly added exhaustive
`testPlayerAndExpandedOptionsRemainOperableAtAccessibilityXXXL` was removed
after its landscape seek-control reachability failure because that optimization
is outside the owner's revised scope. Removal is not a fix or a passing result.
The two original basic accessibility checks and normal/Extra Large player
orientation coverage remain.

All 239 unit tests passed with zero failures in
`/tmp/rustyView-D-practical-final.log`. That run finished with 26 UI passes,
15 failed UI cases and 2 platform skips (43 cases, 52 failed assertions).
It used the earlier build and is not a passing gate.
Its eight-copy offline search/sort/deletion journey passed in 149.234 seconds,
and offline Resume/Start Over/Favorites/History with relaunch passed in
78.651 seconds. The updated generic build passed in
`/tmp/rustyView-D-verified-generic.log`, and the updated test build passed in
`/tmp/rustyView-D-verified-test-build.log`. The subsequent focused run executed
the three polling tests and download batch profile: the batch and two polling
cases passed, while the unsupported-status fixture assertion failed. The
corrected polling fixture then passed all three cases in
`/tmp/rustyView-D-practical-corrections.log`. That run also passed the full
default-size collection journey (402.386 seconds), including both orientations,
saved formats, Continue Watching, Favorites, History and deletion. It still
failed on native search/label audit reporting; measured-pixel contrast and a
real native-clear action check are compiled for the next verification run.
This checkpoint is not a passing project gate.

The updated build includes Settings light-appearance contrast, chapter-time
contrast, Pause sizing, and a 44-point Browse Movies action. Two earlier dark
checks captured light screens because UIKit ignored the launch appearance
argument; a DEBUG-only Simulator hook restricted to a valid test UUID now applies
the requested appearance, while normal launches retain the system setting.
Test corrections preserve one focus operation during secure entry, target Copy
details correctly, verify actual native-picker padded-row actions, and exclude
only contrast samples in real scroll cells covered by native bars. Routine font
checks inspect the selected size rather than predicting a future text size.
The focused rerun passed the main browse/watch/download/offline journey
(140.971 seconds), Core Extra Large (117.615 seconds), and default-size
folders/chapters (47.394 seconds). It exposed additional Saved Copies label
semantics, a partially scrolled test target, and Clear Search tap padding.
These are corrected in source; remaining focused checks and the final project
gate are still required. The latest generic build and privacy check passed.

Visual inspection covered all 14 named `Synthetic-font` screenshots from
`/tmp/rustyView-D-font-sixth-attachments/manifest.json` (AX XXXL). The failed
download's status had a measured sRGB text color of (255, 141, 40) on white,
only 2.31:1 contrast. Failure and unsupported-copy text now uses the system
primary label color. Single-state Downloads lists omit redundant section
headings, and wrapped Settings preference labels align left. The eighth run's
AX XXXL portrait screenshots verify one movie row and complete titles/actions in
Downloading, Paused, Failed and Ready states. Failed-message interior pixels are
now black on white (21:1 contrast). That run did not reach saved collections or
Manage Copies; it does not establish other sizes or dark appearance. The blank server values in
the Settings screenshot came from the DEBUG connection bootstrap. The later
fifteenth Core cases verified actual saved address/account layout.

Native popup menus retain the user's text size and system presentation. At XS,
the measured adjacent UIKit Sort rows are 250×35.7 points. Apple's current
accessibility guidance lists 44×44 points as the iOS default and 28×28 as its
minimum; these rows therefore remain below this repository's stricter 44-point
goal. Menu/control-size overrides did not change them and were removed. Tests
apply the 28-point platform minimum only to explicitly inspected native
popup rows, retaining real selection, clipping checks, and 44-point requirements
for app-owned controls. This is a documented platform scope, not an all-controls
44-point pass. [Apple accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility).

The unchanged C artwork source was preserved before measurement (SHA-256
`7318313aa19e3fe3cdd6aec8f3a11d4935bd5ec43641dc3d8d793c0b3b68d9b1`). The new
pipeline cancels queued permits promptly, freezes request ownership before
waiting, decodes at most 1024-pixel thumbnails off the main actor, and charges
the bounded cache for decoded bytes. All five focused artwork tests passed.
The original two benchmark bodies are unchanged; three additional real-HTTP
regressions cover captured-client release, account changes while queued, and
late failures arriving after a newer rendered image.

With four authenticated responses held, cancelled queued models fell from 20
retained after 0.254 seconds to zero; cancellation started no extra requests.
Six actual rendered posters retained 16,809,984 bytes of logical raster capacity
instead of 150,994,944 bytes, with maximum edge 1024 instead of 3072. The sampled
main-actor maximum gap was 7.4 ms versus 166.8 ms, and raster drawing took 7.3 ms
versus 32.9 ms. Eager decoding moved work before publication: loading took
115.3 ms versus 21.1 ms. The unit host's physical-footprint peak was 64.9 MB
versus 44.7 MB, with different starting footprints; logical raster capacity
must not be described as process memory.

Both real app performance journeys passed before and after the change. Each
used three measured iterations plus XCTest warmup, generated 2048×3072 posters,
distinct authenticated URLs, and the same Debug Simulator workload. The scroll
journey reached all 36 titles and all three server pages, loaded all 36 posters,
and returned to the first title. Measured swipes were 7/7/8 before and 8/7/8 after.

| Public XCTest measurement | C baseline | Artwork change |
| --- | ---: | ---: |
| Launch to responsive first frame | 1.793 s | 1.643 s |
| Scroll app peak physical memory | 1,227,055.549 kB | 84,352.709 kB |
| Scroll app CPU time | 10.573 s | 9.778 s |
| Dragging/deceleration duration | 2.577 s | 2.589 s |

These are Simulator observations, not device guarantees. The launch metric
does not wait for all posters. XCTest emitted no requested hitch metric series
in either result, so hitch performance remains unmeasured. Raw metrics and
workload observations are preserved in `/tmp/rustyView-artwork-baseline/`.
UI results are
`/tmp/rustyView-review-gate/Logs/Test/Test-rustyView-2026.09.05_16-12-51--0700.xcresult`
and
`/tmp/rustyView-review-gate/Logs/Test/Test-rustyView-2026.09.05_16-42-00--0700.xcresult`;
the post-change unit log is `/tmp/rustyView-D-focused-corrected.log`.

The 500-record storage check also passed in the current 239-test unit run.
[`testFiveHundredStoredMoviesRestoreWithoutBlockingTheMainActor`](rustyViewTests/DownloadStorageTransactionTests.swift#L647)
uses distinct synthetic records and safe hardlinks to inspected real media,
then holds actual index I/O while confirming the main actor can continue.
All 500 records restore as ready. The `STORAGE_BENCHMARK` entry in
`/tmp/rustyView-D-practical-final.log` records legacy manifest encoding at
3.515 ms, decoding at 3.946 ms, atomic snapshot save at 5.275 ms, and remaining
actor restoration at 105.030 ms after releasing the read barrier. These are
component measurements; the restoration timer excludes the deliberate hold,
and the legacy serialization is not a measured pre-change application baseline.
They establish off-main storage progress, not a full-app frame-rate or hardware
performance claim. The ongoing UI run still leaves the project gate open.

The six-download component profile passed in 1.007 seconds in
`/tmp/rustyView-D-practical-fixes-focused.log`. The public DownloadManager received
authenticated URLProtocol HTTP responses containing real media prefixes, with
the tails held. All six requests advanced in FIFO order through two active
slots, Pause and Cancel admitted waiting jobs, incomplete movies stayed unsaved,
and all six removals were durable. Source:
[`DownloadBatchPerformanceTests`](rustyViewTests/DownloadBatchPerformanceTests.swift).

| Same-build component window | Elapsed | Process CPU | Maximum sampled main-actor gap |
| --- | ---: | ---: | ---: |
| Idle | 156.003 ms | 26.051 ms | 6.376 ms |
| One held media response | 168.981 ms | 17.248 ms | 6.360 ms |
| Six-job queue actions | 448.315 ms | 341.835 ms | 185.235 ms |

The batch delivered 4,197,810 media bytes across six authenticated requests;
the observed active-response peak was two. Sampled process footprint increased
from 36,571,368 to a peak of 42,502,424 bytes. Cancel-to-next-request took
74.213 ms and Pause-to-next-request 11.464 ms. These are single unit-host
observations, including URLSession, test endpoint and test-host activity, not
SwiftUI frame rate, a UI response-time guarantee, or hardware suspension behavior.
The 185.235 ms gap is retained as an adverse observation; the sampler cannot
attribute it to a specific operation or distinguish executor delay from a
blocked main thread.

Source inspection found no explicit main-actor filesystem call in admission:
journal updates and resume storage use actors, and the capacity query is detached.
Task-envelope JSON encoding, task-description decoding during cancellation, and
native URLSession task creation still execute synchronously on the main actor.
The measurement does not identify any of those sites as the cause of the gap,
so it does not justify an additional production refactor. Playback while browsing
is not a reachable current UI workload: the full-screen player's Close action
stops playback. PiP/output and representative-device profiling remain separate
verification limits.

Keyboard diagnostics now reach actual playback: Space and arrow keys change
transport, and a temporary `q` binding invoked the options-dismissal action.
Injected Escape still failed to dismiss UIKit's own Sort menu on the dedicated
iPhone Simulator, iOS 26.5 (`/tmp/rustyView-D-font-eighth-focused.log`). The Escape
test now checks that native control first and skips app-specific Escape assertions
when this runtime cannot deliver the key; transport assertions run independently.
This is not an Escape pass. Physical-keyboard Escape and iPad behavior remain
unverified. The positive action diagnostic is recorded in
`/tmp/rustyView-D-keyboard-q-diagnostic-second.log`.

The production keyboard implementation subsequently passed its positive UI
journey in `/tmp/rustyView-D-font-tenth-focused.log` (21.429 seconds): Space,
real arrow-key seeks, opening options with O, dismissal, restored focus and
resumed playback. Temporary diagnostic commands were removed. The separate
native Escape control still skipped on this runtime. Both real connection
validation/cancellation/relaunch journeys passed in the eleventh focused run.

The eleventh screen review identified actual truncation of the online Mode
value at AX XXXL. Mode and Quality now retain native choices with multiline
menu labels. Local Audio/Subtitles headings are shorter. Setup placeholder
pixels improved from 1.70:1 to 9.96:1 contrast, although the native UITextField
audit still reported a contrast issue; explicit input text styling is being
checked by the retained setup journeys. This historical run did not establish
all-font coverage; exhaustive font optimization is no longer in scope.

The thirteenth focused gate passed Core XS (137.609 seconds), Folders/Chapters
AX XXXL (74.420 seconds), and Storage Recovery AX XXXL (73.346 seconds).
Visual review found no clipping in the XS download choices or expanded AX
chapters. Remaining setup contrast crops included text occluded by the keyboard
or navigation bars; directly visible heading and validation pixels measured
21:1 and 18.16:1. No unidentified clipping exemption was introduced.
The fourteenth focused run reached the full large-text options sheet and actual
connection editing but reported clipping in Settings and the native Video Size
label. The isolated comparison below subsequently identified and corrected the
Settings issue. No native Video Size defect was reproduced in the isolated
control, and the extreme-size investigation stopped with the owner's scope
change. The fifteenth collection journey exercised the native collapsed Downloads
search proof but stopped at an obsolete Close selector. Its correction still
needs the retained practical collection journey; the former "not run" status
is superseded. The default/Extra Large project gate remains open, not an
exhaustive font matrix.

An isolated native Form probe checked intrinsic multiline text, real button
actions, scrolling through a partial row, and expansion/collapse at AX XXXL.
The visible control and both traversal cases passed; all seven captured clipping
audit results were empty. Simple viewport crossing therefore did not reproduce
the main app's unattributed clipping report, and no general nil-element audit
exemption was added. Probe results remain outside the repository at
`/tmp/rustyView-form-audit-probe-results.xcresult` and
`/tmp/rustyView-form-audit-probe-second-results.xcresult`.

A second isolated comparison reproduced the Settings clipping reports: switching
between separate horizontal and vertical view trees produced four unattributed
issues, both with clipping alone and with the combined audit. Keeping the same
Text children in `AnyLayout` produced zero issues with the same labels, values,
font category and combined audit. Settings now uses that stable layout; playback
preference and chapter rows use the same approach. The fifteenth run's Core AX
XXXL case passed in 187.171 seconds and Core XS in 130.939 seconds, including the
real saved connection and all three Settings captures. The interrupted run was
not a full project gate. Evidence:
`/tmp/rustyView-conditional-control-probe-second-results.xcresult`.
The native Video Size picker, including its real Fit/Fill action and Cancel
toolbar, produced zero issues in the isolated combined audit; no picker-specific
exemption or replacement was introduced.

Source review found that persistent storage explanations and multiple recovery
buttons occupied the bottom inset of Library, Saved and Downloads, potentially
leaving little content space at accessibility sizes. These now use short,
44-point recovery buttons opening scrollable detail sheets. Saving progress
prevents repeated Retry taps; a failed retry retains its existing explanation
without a duplicate alert. Source parsing passed. Existing tests cover actual
file-write failure and recovery. A new Simulator-only, UUID-namespaced fixture
uses real shared files for damaged indexes and denied reads. Its first AX XXXL
run proved the app could create its legitimate index in the fixture directory,
then found the recovery banner's accessible background extending behind the
tab bar. The material background now respects safe areas. The AX XXXL case
then passed (73.346 seconds): corrupt-index recovery, preserved video and backup,
failed and successful file-read retries, Manage Storage navigation, and real
offline playback without additional catalog requests. The eleven additional font
categories were not verified and have been removed from the requested scope;
VoiceOver still requires hands-on verification. Evidence is retained in
`/tmp/rustyView-D-font-thirteenth-focused.log` and
`/tmp/rustyView-D-font-thirteenth-attachments/manifest.json`.
Populated-library refresh errors also use the compact banner, while an empty
library retains its primary recovery actions. Settings address/account values
now stack at accessibility sizes, and long subtitle loading/delivery labels
explicitly wrap. These latest presentation changes have passed source parsing;
the retained default/Extra Large journeys and baseline accessibility audits
provide their current verification scope.

The retained practical checks visit active movie details with real downloading, paused,
and failed transfers. Status and action pairs now wrap as complete rows, and
their determinate progress bar is decorative because the visible percentage
already exposes the value. Continue Watching is a navigation shortcut in both
Library and Downloads, avoiding duplicate movie rows on the same screen.
Repeated setup placeholders were removed while the saved-password hint remains.

The twelfth run also separated navigation errors from layout defects: a native
Save Password sheet blocked Search, and a short test drag hid the paused player
after seeking. Tests dismiss only the identified synthetic password offer and
inspect read-only text geometry without requiring it to accept taps. Plain
movie-detail labels with native contrast warnings now require measured sRGB
pixel contrast of at least 4.5:1 before the report can be excluded. The observed
AX title was 18.82:1. Native single-line connection inputs retain real typing
and selected-font line-height checks; XCTest's prediction about a future text
size is recorded separately. Unattributed clipping reports remain failures.

## Download transfer progress

The owner also reported completed preparation being shown as a 100% download
while network transfer continued. Both screens now keep received bytes visible
and switch from preparation to transfer progress when the producer finishes.
The existing server supports a header-only size lookup for a ready generation;
the client makes at most three attempts on its shared poll cadence, retaining
the exact media URL, account and active GET. An unavailable total leaves honest
received-byte progress. No server change is required.
Three real chunked-HTTP component regressions and an end-to-end held-transfer
journey cover this boundary. Generic and test builds passed in
`/tmp/rustyView-D-download-progress-generic.log` and
`/tmp/rustyView-D-download-progress-test-build.log`. All three component tests
passed in `/tmp/rustyView-D-transfer-progress-focused.log`: size discovery,
later byte callbacks and inspected installation (4.451 seconds); bounded invalid
metadata without transfer failure (10.476 seconds); late cancellation (1.594
seconds). Both UI journeys passed: existing timestamp-based preparation
(30.004 seconds) and completed preparation with a held byte transfer (24.307
seconds). The latter verified both screens showing 33% and the actual received
and total bytes, exactly one media GET and one HEAD, no playable partial file,
and real local playback only after the remaining chunks arrived. All five
focused cases passed.

A fourth real-HTTP regression passed for a ready response that omits the
optional preparation timestamp (4.351 seconds). It proves cached partial
preparation ends while the original media GET continues. The held-transfer UI
journey also passed with visible-content geometry assertions and screenshots
(25.346 seconds). Both screenshots were visually inspected: each shows
Downloading, 33%, and 1.2 MB of 3.7 MB with readable actions. Evidence:
`/tmp/rustyView-D-final-transfer-edge.xcresult` and
`/tmp/rustyView-D-final-transfer-screens/manifest.json`.

The latest generic and test builds passed. The final layout correction run also
passed all three polling tests and four UI cases: dark folders/chapters,
dark setup/settings/recovery, default-size empty states, and default-size
setup/settings/recovery. Evidence:
`/tmp/rustyView-D-layout-corrections-final.xcresult`.
The first final project run, `/tmp/rustyView-D-project-final.xcresult`, was
interrupted during component tests after review found a late-size-response
race: a HEAD completing during local media inspection could replace Saving
with zero-byte downloading. The correction must retain the live transfer
before accepting size metadata. This interrupted run is not a passing gate.
The correction now checks the same live URLSession task before and after
metadata requests, and late byte callbacks retain Saving. Review also found
that an unknown-total HTTP 206 response could incorrectly use its segment size
as the movie total. Both native progress and size-lookup eligibility now use
the full Content-Range total, leaving received-only progress when it is absent.
All six byte-total tests and three polling tests passed in
`/tmp/rustyView-D-final-size-races.xcresult`, including the held-inspection race
(2.649 seconds) and actual native pause/resume with a nonzero Range, unknown
total, and subsequent HEAD discovery (4.144 seconds).
The same run exposed an overly strict UI fixture assumption about background
callback timing: iOS reported 16 KB while the server had sent a larger prefix.
The UI assertion now accepts a positive reported amount no greater than that
prefix, still requires the exact final total and a transfer percentage at most
33%, and retains the single-GET, no-partial-playback and real installation/play
checks. The corrected journey passed in 26.768 seconds:
`/tmp/rustyView-D-final-transfer-ui.xcresult`.

Failed movie details now show the specific error without an additional generic
failure heading. The unavailable-movie recovery explanation is one sentence.

All 32 default-size collection captures were reviewed. Complete portrait
captures show one movie per collection, readable actions and concise saved-copy
choices. Two player captures became fully readable after stripping image
orientation metadata without changing compressed pixel data. Six landscape
captures contain an incomplete raster; they cannot establish a visual defect
or certify the full landscape screen. Landscape geometry and actual controls
are covered by the passing collection journey. Offline image evidence:
`/tmp/rustyView-D-practical-collection-decoded-qa/README.md`.

Final visual review used the completed project run's full-screen captures:
all 32 Extra Large collection images and the six replacement default-size
landscape images were inspected. All 12 landscape rasters are complete. Rows
show each movie once, with readable actions and distinct formats inside Saved
Copies. No visible overlap or clipped content was found; the player toolbar
uses its normal title ellipsis. Two image-viewer label omissions were resolved
using metadata-only copies with unchanged compressed pixels. Evidence:
`/tmp/rustyView-D-final-xl-collection-screens/manifest.json`,
`/tmp/rustyView-D-final-default-collection-screens/manifest.json`, and
`/tmp/rustyView-D-final-xl-player-qa`.
Both final byte-progress screenshots were also inspected and show the held
transfer at 33%, with 1.2 MB of 3.7 MB and reachable controls:
`/tmp/rustyView-D-final-completed-progress-screens/manifest.json`.
The reported production 20 GB transfer was not reproduced. Regression tests
use smaller real HTTP/media transfers; byte-count handling uses Int64 and the
ready-size lookup reads headers without buffering the movie.

## D21 transport evidence

The original macOS probe reproduced foreign MP4 redirects and HLS references
despite the native cross-site restriction. The unchanged C app then reproduced
the defect on the dedicated iOS Simulator with two trusted HTTPS ports: foreign
master/media/audio/key/map references, segment redirects, MP4 redirects and a
warmed foreign origin received HTTP requests. Credentials did not leak in these
cases. Actual same-origin MP4 seeking, HLS, encrypted keys, initialization maps,
owned redirects and frozen-account controls established working TLS and decoding.
That native baseline passed 4 of 14 cases; cancelled held requests also remained
open. Evidence: `/tmp/rustyView-D-native-origin-prefix.log`.

The replacement uses an immutable playback-attempt relay bound to `127.0.0.1`,
normal TLS validation, bounded same-origin redirects, strict HLS URI rewriting
and body inspection. Progressive assets retain `forbidAll` references. The
listener's separate local-link filter initially rejected iOS connections before
the application received them; removing it while preserving the exact loopback
bind restored all positive controls. Evidence:
`/tmp/rustyView-D-native-positive-listener.log`.

All 14 native HTTPS cases and 6 relay robustness cases now pass, with no skips,
in `/tmp/rustyView-D-font-transport-focused.log` (42 focused unit tests passed).
Native hostile cases preserve zero-foreign-request and zero-foreign-credential
assertions, require one typed asset-wrapper trust rejection, and independently
exercise the actual `PlaybackModel` terminal error with output stopped and no
automatic retry or format fallback. AVFoundation can retain an unknown HLS item
after local segment cancellation; the app's typed failure, rather than every raw
item reaching `.failed`, is the verified product boundary.

The six robustness cases additionally prove actual playback before an EVENT
refresh introduces a foreign segment; rejection of unknown, duplicate and
malformed URI attributes; a bounded redirect loop; exact SHA-256 and byte count
for a completely forwarded 32 MiB asset; bounded slow-reader work with real
upstream cancellation; and a growing 6,000-to-7,200-fragment EVENT playlist whose
old local URLs retain range access and remote generation identity. Native output
and memory limits on hardware remain separate gates. Online AirPlay video is
explicitly unavailable under this relay; saved files retain native output policy.

## Verification that needs people or hardware

The verified build was installed and launched on the owner's `iPhone 17`
preview without uninstalling or resetting it. A read-only preflight confirmed
it was shut down with no stored background download tasks. Existing Application
Support files were unchanged across installation, and existing media/support
files were unchanged after launch; JSON indexes were allowed to migrate.
No UI automation or screenshots used that preview. The separate dedicated test
iPhone's synthetic Settings probe and test keychain trust were removed after
verification. The owned HTTPS fixture stopped cleanly and its temporary keys
and certificates were deleted. Result bundles and logs remain available.

These remain required even after simulator gates pass: authenticated remote
browsing and original/unsupported-media playback; background completion and
relaunch; airplane-mode local playback; audio/caption selection; phone/Siri
interruptions, Bluetooth/headphone route changes and lock-screen controls;
Picture in Picture/AirPlay with captions; storage deletion; VoiceOver and iPad
keyboard/narrow split view; representative-device performance measurements.
Minimum-iOS testing awaits an installed iOS 17 runtime/device. Formative usability
sessions described in the plan require participants and have not been performed.
Automated verification used synthetic media. No production service changes or
manual production-library investigation were performed. The normal preview
launch retains its existing connection and may refresh that library.
