rustyView review and fix plan — 5 September 2026

The app has substantial working foundations, but it does not yet deliver a consistently considerate movie-watching experience. The biggest problems occur when the user's circumstances change: going offline, returning tomorrow, changing audio, losing connectivity, changing a download setting, or recovering from a failure. A polished interface cannot compensate for a choice being ignored or a download disappearing.

The desired product behavior is simple: remember what the person wanted, make the next useful action obvious, explain limitations before they matter, preserve completed work, and recover without asking the person to understand the implementation.

This review combines three specialist reviews covering browsing/UX, playback, and downloads with an integration review of authentication, identity, persistence, project configuration, and tests. It is a review and implementation plan; application behavior was not changed. No production service or production media was accessed. Evidence uses the source at review time; line numbers may move as fixes land.

Evidence labels used below distinguish source-confirmed behavior, missing product capabilities, and risks requiring targeted runtime verification. Source-confirmed findings have not all been independently reproduced in the running app. Design proposals need user testing; they are not claims that a different layout alone will improve satisfaction.

Existing strengths to preserve include authenticated real-media UI tests, request ownership for browsing and captions, isolated connection probes, origin checks, generated synthetic fixtures, local-file playback, safe filenames, manifest validation, serialized cancellation/installation, large-text poster layout work, and immediate download enqueue from the final rendition choice. Extend these foundations.

Verification performed during the review:

- XcodeGen project generation passed and produced no tracked project changes.
- Generic iOS Simulator build passed. The build emitted an AppIntents metadata-extraction warning because the app has no AppIntents dependency.
- All 58 core tests passed.
- The full test command passed on the dedicated `rustyView Test iPhone`, iOS 26.5: 8 UI tests passed and 1 PiP test skipped because the test could not find the PiP control. This is a coverage limitation, not a successful PiP validation.
- Repository privacy check and whitespace checks passed; only this plan was added.
- A harmless Foundation probe confirmed that equivalent URLs with different host case or explicit default port retain different `absoluteString` values.
- A synthetic accessibility-XXXL screen was visually inspected. It supports the current layout's basic integrity, not a claim that all screens or assistive interactions are validated.
- No hardware, iPad split-view, minimum-iOS-runtime, production smoke, or usability study results are claimed. The owner's preview Simulator was not used for automation.

Priority means impact and sequencing, not a release promise. P1 items can break a core promise or undermine trust and should be addressed before broader adoption. P2 items complete essential usability, resilience, and platform behavior. Some P1 entries are explicitly product gaps rather than bugs. Size estimates are relative implementation scope: S is a focused change, M spans a model and its UI, L needs persistence/lifecycle design and end-to-end verification. They are not calendar estimates.

| ID | Priority | Work package | Size |
| --- | --- | --- | --- |
| 01 | P1 | Own and cancel prepared playback sessions | M |
| 02 | P1 | Make player controls and recovery truthful | L |
| 03 | P1 | Preserve the download queue across every relaunch | L |
| 04 | P1 | Verify offline readiness instead of equating it with nonempty bytes | M |
| 05 | P1 | Unify movie details and local/online playback actions | L |
| 06 | P1 | Disclose the actual download before the final choice | M |
| 07 | P1 | Preserve audio, captions, and chapters offline | L |
| 08 | P1 product gap | Make returning to a movie effortless | L |
| 09 | P2 | Preserve transferred bytes and explain network waits | L |
| 10 | P2 | Canonicalize identity and define account ownership | M |
| 11 | P2 | Recover file transactions after process death | M |
| 12 | P2 | Reconnect background sessions without requiring sign-in | M |
| 13 | P2 | Bound downloads and preparation polling | M |
| 14 | P2 | Give playback settings clear commit and persistence behavior | M |
| 15 | P2 | Complete caption feedback, text rendering, and external output | L |
| 16 | P2 | Reconcile audio interruptions and Now Playing | M |
| 17 | P2 | Turn errors, empty states, and offline launch into useful next steps | M |
| 18 | P2 | Preserve browsing location and make navigation feedback immediate | M |
| 19 | P2 | Complete accessibility and iPad operation across all states | L |
| 20 | P2 | Make Downloads a recognizable movie collection | M |
| 21 | P2 verification | Measure performance and close authentication/lifecycle coverage gaps | M |

01. **Own and cancel prepared playback sessions.**

Source-confirmed. Each compatible URL receives a new random `session` and `request`, while playback does not retain its prepared generation or explicitly cancel it on replacement/close. A long seek, audio change, or fallback can leave independent abandoned producers consuming server resources until server cleanup. The server has a stable-session/newer-generation contract precisely to handle this.

Evidence: [URL generation](rustyView/Networking/RustyDLNAClient.swift#L274), [playback creation](rustyView/Playback/PlaybackModel.swift#L284), [stop](rustyView/Playback/PlaybackModel.swift#L529), and the sibling server's `docs/WEB_PLAYER.md`, lines 588–612. Server timeouts provide eventual cleanup; this finding does not imply jobs live forever.

Implementation: give each viewing session immutable connection ownership, a stable server session ID, increasing generation IDs, and a retained prepared request. Cancel the exact superseded generation, including when a delayed media GET has not arrived yet. Maintain a bounded active-generation heartbeat according to the existing server contract. Capture the old connection for cleanup rather than using whichever account/server is current later. Keep downloads independently owned. Debounce repeated long-range scrub restarts without delaying immediate scrub feedback.

Acceptance: the synthetic HTTP server observes one session and increasing generations across seeks; close/replacement sends generation-scoped cancellation; late abandoned requests cannot recreate work; another download or viewer remains unaffected. Long pause/reconnect and buffered reader-free intervals recover correctly. No server protocol change is assumed necessary.

02. **Make player controls and recovery truthful.**

Source-confirmed. During preparation/buffering the app can have playing intent while `isPlaying` is false. The button says Play, but its toggle action pauses. The startup watchdog stops at `readyToPlay`, so it does not bound a ready item that never advances. Exhausted fallback can leave no Retry action. These make the most important control unreliable precisely when the person needs reassurance.

Evidence: [observed status](rustyView/Playback/PlaybackModel.swift#L204), [toggle](rustyView/Playback/PlaybackModel.swift#L364), [watchdog](rustyView/Playback/PlaybackModel.swift#L764), [readiness handling](rustyView/Playback/PlaybackModel.swift#L570), [transport button](rustyView/Views/PlayerScreen.swift#L198), [error actions](rustyView/Views/PlayerScreen.swift#L393).

Implementation: introduce an explicit transport state carrying user intent, current attempt, progress, and recovery. Derive the visible action and accessibility label from the action that will actually occur. Monitor first playback progress and later stalls, while excluding deliberate pause and in-progress seeking from false failure detection. Bound retries and preserve global time, audio, captions, explicit quality, and pause intent. Every terminal state needs Retry Current Playback and Close, plus contextual recovery where available. Explain preparation/fallback in plain language without exposing codec policy in the primary UI.

Acceptance: delay playable media, deliver a playlist with stalled segments, interrupt ongoing delivery, exhaust portable fallback, restore the server, and retry. Assert real time advancement and matching button behavior, including pause during preparation. Explicitly selected quality must not be silently reduced to make a retry succeed.

03. **Preserve the download queue across every relaunch.**

Source-confirmed. Permanent failures and exhausted retries live only in `active`; the manifest contains completed records, and startup reconstructs work from extant system tasks. Once the failed system task disappears, the user's request, failure reason, and Retry Now action disappear with it.

Evidence: [failure handling](rustyView/Downloads/DownloadManager.swift#L429), [task restoration](rustyView/Downloads/DownloadManager.swift#L475), [manifest model](rustyView/Downloads/DownloadModels.swift#L167).

Implementation: persist download intent independently of URLSession tasks. Use a versioned queue journal containing rendition choices, immutable ownership, attempts, scheduled retry time, and explicit queued/waiting/running/paused/installing/failed states. Record intent before creating system work and reconcile journal plus task list after every launch. Preserve failure until the user retries or removes it. Make reconciliation idempotent so interrupted startup cannot duplicate downloads. Preserve existing completed copies during migration.

Acceptance: HTTP 401, 404, exhausted 5xx, low-space installation failure, and termination between enqueue/task creation all survive process relaunch with one accurate row. Retry uses the retained choices and correct credentials; removal stays removed; no duplicate tasks appear.

04. **Verify offline readiness instead of equating it with nonempty bytes.**

Source-confirmed validation gap. A successful binary-looking response and positive file size can become a completed record. Startup compares file size with the size recorded at installation, which cannot detect a consistently recorded but invalid original download. Unsupported originals can be labelled available offline even though the local player has no compatible fallback.

Evidence: [response validator](rustyView/Downloads/DownloadModels.swift#L172), [installation](rustyView/Downloads/DownloadManifestStore.swift#L97), [local playback](rustyView/Playback/PlaybackModel.swift#L479), [ready rows](rustyView/Views/DownloadsView.swift#L36).

Implementation: model stored bytes, integrity validation, and device playability separately. Inspect local AVAsset tracks and duration, compare expected media properties where trustworthy, and reject malformed/empty/truncated compatible output before promoting it to Ready to Watch. A successful asset inspection is advisory, not proof that every frame can decode; retain clear recovery after actual playback failure. Preserve intentionally downloaded unsupported originals as stored files with a truthful compatibility status, not a universal readiness claim. Offer creation of a compatible copy without first destroying the original.

Acceptance: a real valid fixture becomes playable; a 200 response with nonempty garbage and media shortened relative to trustworthy expected content do not become Ready to Watch; unsupported originals have an honest state and useful recovery. Do not reject legitimately short media solely because catalog duration is stale. Reopen the store after each case and verify the same state. Tests must inspect actual playback or media, not just MIME type or extension.

05. **Unify movie details and local/online playback actions.**

Source-confirmed. Details always fetch the server before showing any controls. Watch always selects any existing local record but continues showing editable online audio/quality choices that `playLocal` ignores. Chapter buttons always choose remote playback. An unsupported downloaded original consequently obstructs the normal streaming path unless the user deletes it.

Evidence: [remote detail loading](rustyView/Views/MovieDetailView.swift#L350), [Watch source choice](rustyView/Views/MovieDetailView.swift#L187), [chapter action](rustyView/Views/MovieDetailView.swift#L82), [local state reset](rustyView/Playback/PlaybackModel.swift#L479).

Implementation: introduce stable movie presentation metadata and a source-aware playback request shared by Library, Downloads, details, and Continue Watching. Render cached/local information immediately and refresh remotely only when appropriate. Show the selected source clearly. Prefer a suitable local copy, retain an obvious Watch Online action, and ensure every visible audio/quality control applies to that source. Route Resume, Start Over, and chapters through the same request boundary. Unavailable local selections need an explanation or a streaming option. A local playback failure must not silently spend mobile data by switching online.

Acceptance: download, lose connectivity before opening details, and reach local details/playback from every entry point with zero HTTP requests. With a low-quality/default-audio copy present, request another online quality/audio and verify the actual outgoing stream. Jump to a local chapter. Recover from an unsupported original without deleting it. Retain current scroll/navigation when returning from playback.

06. **Disclose the actual download before the final choice.**

Source-confirmed missing information. The rendition menu gives only Compatible copy / Original file. The nearby size is source-file bytes, not a compatible-output estimate. The decision omits meaningful playability, audio, subtitle, HDR, and channel-preservation information.

Evidence: [menu](rustyView/Views/MovieDetailView.swift#L331), [source size](rustyView/Views/MovieDetailView.swift#L155), [compatible request policy](rustyView/Networking/RustyDLNAClient.swift#L257).

Implementation: put a concise download summary beside the action before the final menu: selected quality and audio, expected retained features, compatibility status, and accurately labelled source size or output estimate. Where an estimate is unavailable say “Size determined during download.” Mark the suitable compatible option as recommended. Explain meaningful losses instead of promising source fidelity. Obtain facts from server capabilities/output and media inspection; do not grow another codec policy in the client. Selecting a rendition must still enqueue immediately, with immediate visible feedback and no second confirmation. Add low-space preflight where estimates are useful and a recovery action when space runs out.

Acceptance: synthetic HDR, multichannel, alternate-language, subtitle, unsupported-original, and unknown-size cases show truthful pre-download information. The selected output agrees with that information. One final selection creates one visible job immediately.

07. **Preserve audio, captions, and chapters offline.**

Source-confirmed missing capability. Local playback clears `item`, audio, and captions, while controls depend on a remote item. There is no local media-selection-group UI. Download records omit caption/chapter metadata. Even an original containing alternate tracks does not expose them through this player.

Evidence: [local player setup](rustyView/Playback/PlaybackModel.swift#L479), [conditional controls](rustyView/Views/PlayerScreen.swift#L258), [offline metadata](rustyView/Downloads/DownloadModels.swift#L15).

Implementation: make playback metadata independent of a remote DTO. Inspect and expose local audio/subtitle selection groups and chapter metadata. Persist chapter metadata and supported subtitle sidecars as part of an owned offline package, with safe local paths and transactional installation. Distinguish included tracks from tracks that require a different download. Preserve preferred language where applicable without assuming track IDs match across renditions. Coordinate the schema migration with items 03–05 and 10–11.

Acceptance: disconnected process relaunch with actual alternate-audio media, local captions, and chapters. Select distinguishable audio, render the expected cue, and jump to the expected time with zero server, artwork, caption, or credential-refresh requests. Cancelled installation cannot publish a partially assembled package.

08. **Make returning to a movie effortless.**

P1 product gap. Resume timestamps exist, but there is no Continue Watching, Favorites, viewing history, consistent card progress, or explicit Start Over. Offline Watch hides the resume label. A person returning tomorrow has to find the movie again and remember their own intention.

Evidence: [progress store](rustyView/Playback/PlaybackProgressStore.swift#L20), [catalog-only grid](rustyView/Views/LibraryView.swift#L128), [watch label](rustyView/Views/MovieDetailView.swift#L429).

Implementation: extend local user-library state with cached display metadata, favorites, recents, and resume status. Put a restrained Continue Watching row above the catalog when it contains relevant titles; expose Favorites without obscuring the primary library. Use consistent Resume and Start Over actions online and offline, including a clear “X minutes left.” Offer removal from Continue Watching. Keep watched/history state distinct from the rule that clears resume near the end. Namespace and migrate all state through item 10.

Acceptance: partially watch a real fixture, terminate, relaunch offline, find it without searching and resume near the saved time. Start Over begins at zero and persists that intent. Completed titles leave Continue Watching. Favorites and history survive relaunch and do not collide across libraries/accounts. Test disappearance of a remote title while its offline copy remains.

09. **Preserve transferred bytes and explain network waits.**

Source-confirmed. Changing cellular policy cancels and creates ordinary new downloads, losing transfer progress. There is no pause/resume state or resume-data handling. Policy replacement also removes an existing scheduled retry delay. The Settings promise that work will resume is stronger than this behavior.

Evidence: [policy changes](rustyView/Downloads/DownloadManager.swift#L366), [task creation](rustyView/Downloads/DownloadManager.swift#L590), [Settings copy](rustyView/Views/SettingsView.swift#L63).

Implementation: preserve valid resume data and use range-aware resumption where the server/system supports it. Keep user pause, waiting for Wi-Fi, scheduled retry, and server preparation distinct. Persist resume data securely with the queue, maintain ownership, and apply the current network policy to replacement requests. Explain an unavoidable restart when resume data is rejected. Preserve backoff when only changing the network setting. Investigate the distinction between resumable completed originals and growing compatible output before promising identical behavior for both.

Acceptance: at high completion percentage, change both policy directions on a range-capable synthetic endpoint and prove already transferred bytes are reused. Relaunch paused/waiting work. Test changed validators, denied range requests, invalid resume data, and growing output. A settings toggle alone must not silently spend the same gigabytes twice where resumption is available.

10. **Canonicalize identity and define account ownership.**

Source-confirmed. Download/resume association uses raw `baseURL.absoluteString`, while auth uses normalized origin. Equivalent host case and default-port variants create separate associations and can duplicate storage. Records omit account ownership, so changing accounts on the same host can reuse associations and retry old work with the current account's credentials. Existing offline access across sign-out can be desirable; accidental catalog/retry reassociation is the problem.

Evidence: [download identity](rustyView/Downloads/DownloadManager.swift#L253), [record lookup](rustyView/Downloads/DownloadManager.swift#L406), [retry request](rustyView/Downloads/DownloadManager.swift#L611), [normalized origin](rustyView/Networking/ServerConnection.swift#L70), [playback identity](rustyView/Playback/PlaybackModel.swift#L227).

Implementation: establish one canonical server identity, including supported deployment-path semantics, and explicit account ownership for network work. Keep retained offline content accessible under a deliberate product policy while avoiding automatic attachment to a different account's current catalog. Migrate old manifests, queues, and progress without deleting files, losing progress, or silently duplicating entries. Define deterministic conflict resolution for equivalent old keys.

Acceptance: host-case, default-port, and trailing-slash edits preserve one download and resume position. Distinct servers remain separate. Two accounts with the same synthetic media ID do not silently share catalog associations or retarget retry authentication. Legacy offline files remain accessible after migration and forgetting credentials. Historical records lacking account ownership stay explicitly unassigned until safely associated; do not assume the current account owns every old same-host copy.

11. **Recover file transactions after process death.**

Source-confirmed crash windows; no process-kill reproduction was performed in this review. Installation moves bytes before manifest save; deletion renames to an unrelated temporary name before commit. Existing exception rollback does not cover termination between those steps. Startup walks manifest records, not orphaned files, so bytes can remain unreachable and uncounted.

Evidence: [installation move and commit](rustyView/Downloads/DownloadManifestStore.swift#L92), [deletion](rustyView/Downloads/DownloadManifestStore.swift#L145), [startup validation](rustyView/Downloads/DownloadManifestStore.swift#L45), [existing rollback test](rustyViewTests/ReviewRegressionTests.swift#L103).

Implementation: add durable transaction metadata or recoverable staging/tombstone names tied to record identity. Reconcile interrupted install/delete operations on launch with a defined commit point. Reclaim abandoned app-owned staging files safely, avoiding active task temporaries. Provide a recoverable damaged-index state instead of only an undismissable error. Move storage operations off the main actor while retaining serialization.

Acceptance: terminate at every move/save boundary and reopen. The result is either the prior valid state or the committed new state, with no unreachable media bytes. Failed precommit deletion preserves the movie; committed deletion stays deleted. Include full-disk, corrupt-index, symlink, and repeated-recovery scenarios.

12. **Reconnect background sessions without requiring sign-in.**

Source-confirmed lifecycle gap with runtime outcome requiring verification. The background session is lazy, and configuration with no connection exits before recreating/reconciling it. The app delegate stores a completion handler but does not independently establish session ownership. Forgetting credentials leaves tasks active; a subsequent background launch may not reconnect them to receive completion events.

Evidence: [lazy session](rustyView/Downloads/DownloadManager.swift#L194), [configuration](rustyView/Downloads/DownloadManager.swift#L225), [saved-connection startup](rustyView/App/AppModel.swift#L86), [delegate callback](rustyView/App/RustyViewAppDelegate.swift#L20).

Implementation: recreate known background sessions and reconcile the durable queue independently of sign-in availability. Do not send new authenticated requests without matching credentials. Process already delivered completion data, or show Reconnect Required for work needing authentication. Own OS completion handlers by session identifier and call them after durable processing completes. Coordinate with queue persistence rather than adding a second restoration mechanism.

Acceptance: start a transfer, forget the connection, and exercise process/background relaunch. Completion either installs correctly or remains visibly actionable; it never silently vanishes. Verify session callback completion on hardware as well as deterministic delegate tests.

13. **Bound downloads and preparation polling.**

Source-confirmed. Each choice immediately resumes a task; compatible downloads with known positive runtime and an available status client also start an independent approximately one-second status loop. There is no application-level transfer bound or shared polling budget, and older-server errors can keep polling indefinitely while work remains active. System/server scheduling may impose limits, but the client does not enforce the repository's bounded-work requirement.

Evidence: [enqueue](rustyView/Downloads/DownloadManager.swift#L315), [polling](rustyView/Downloads/DownloadManager.swift#L532), [waiting presentation](rustyView/Views/DownloadsView.swift#L157).

Implementation: use the durable queue as a bounded scheduler, with an explicit ordering policy and visible waiting reasons. Choose a small measured concurrency default; keep remaining requests durably queued. Share a status-request budget, back off transient failures, respect retry hints, and stop optional progress polling for unsupported status behavior. Maintain any server-required ownership heartbeat separately from optional progress refresh. Show preparation and byte transfer consistently in details and Downloads; do not turn unknown size or missing produced time into a fabricated percentage.

Acceptance: enqueue a realistic batch and assert limits on active work and request cadence, including suspension and relaunch. Verify fair advancement, status-endpoint incompatibility, long server waits, cancellation, and no abandoned pollers. Confirm queued work remains system/background viable under the chosen scheduler design.

14. **Give playback settings clear commit and persistence behavior.**

Source-confirmed. Mode/quality controls mutate the player immediately but also require Apply. Done dismisses without applying while leaving changed model values that later restarts consume. Detail quality resets to Auto; Settings always says Automatic. Explicit Original can conflict with an explicit encoded quality.

Evidence: [live bindings and Apply](rustyView/Views/PlayerScreen.swift#L656), [Done](rustyView/Views/PlayerScreen.swift#L682), [transient defaults](rustyView/Views/MovieDetailView.swift#L13), [Settings](rustyView/Views/SettingsView.swift#L18).

Implementation: choose one consistent model: isolated draft plus Apply/Cancel, or immediate application with no Apply button. Reflect active settings truthfully. Persist preferred quality and validate it against each server's available profiles; explain unavailable preferences instead of silently presenting them as active. Separate preferred language from per-item audio index. Resolve contradictory mode/quality choices explicitly. Use human descriptions of data-saving choices with technical information secondary.

Acceptance: change quality, dismiss, seek, and reopen options; the active setting follows the chosen commit model. Relaunch and open another title; persisted preferences affect actual requests. Remove a profile from server capabilities and verify a visible, sensible recovery.

15. **Complete caption feedback, text rendering, and external output.**

Source-confirmed. Caption errors initiated in the primary menu appear only in the separate options sheet. Text parsing strips tags but leaves character references literal, and playback renders only the first active cue. Sidecar captions are SwiftUI overlay text while PiP is constructed from the bare player layer; those app-rendered cues are not attached to that video output. Exact device/output behavior remains to be tested.

Evidence: [caption selection](rustyView/Playback/PlaybackModel.swift#L445), [first active cue](rustyView/Playback/PlaybackModel.swift#L741), [parser](rustyView/Playback/WebVTT.swift#L32), [primary menu](rustyView/Views/PlayerScreen.swift#L315), [caption overlay](rustyView/Views/PlayerScreen.swift#L374), [PiP layer](rustyView/Playback/PlayerViewController.swift#L52).

Implementation: distinguish requested, loading, active, and failed caption selection. Show feedback and Retry/Off at the initiating control. Correct supported character references and simultaneous-cue presentation. Prefer native legible media/output packaging where it can preserve captions across local, prepared, PiP, and AirPlay playback; investigate any necessary server packaging change under the sibling repository's rules, preserving the web player. Until output support is proven, explain a limitation before the user loses dialogue. Preserve selection and global timing across route/stream changes.

Acceptance: delayed/401/malformed VTT responses have visible recovery; escaped text and overlapping cues render correctly. Real-device caption-selected playback survives PiP and AirPlay with correct prepared-stream offsets, or clearly communicates an unsupported route. No silent subtitle loss.

16. **Reconcile audio interruptions and Now Playing.**

Source-confirmed missing integration. There are no interruption/route-change/media-services-reset handlers. Now Playing has title and sometimes duration, but no elapsed time or rate updates. Remote command registrations are not removed, and stop does not explicitly deactivate the audio session.

Evidence: [subscriptions](rustyView/Playback/PlaybackModel.swift#L198), [audio setup and commands](rustyView/Playback/PlaybackModel.swift#L647), [Now Playing](rustyView/Playback/PlaybackModel.swift#L686), [stop](rustyView/Playback/PlaybackModel.swift#L529).

Implementation: reconcile interruptions with explicit user intent, save progress, honor permission to resume, and avoid surprise playback after headphone disconnection. Recover media services and release the session when appropriate. Publish accurate global elapsed time, duration, rate, and available commands through play/pause/seek/speed/end/local transitions. Support remote position changes where valid and own/remove command targets.

Acceptance: state tests plus device phone/Siri interruption, Bluetooth change, headphone unplug, lock-screen/Control Center transport and seeking, and another audio app resuming after Close. A deliberate pause must survive all transitions.

17. **Turn errors, empty states, and offline launch into useful next steps.**

Source-confirmed. Authentication/offline/schema errors share generic retry presentation. An empty library says new movies will appear but has no refresh control; refresh belongs only to the loaded grid. Forgotten credentials cause setup on every cold launch even with playable downloads. Keychain read failures are swallowed into empty credentials, while disconnect changes live state before credential deletion succeeds.

Evidence: [library failure/empty branches](rustyView/Views/LibraryView.swift#L88), [loaded refresh](rustyView/Views/LibraryView.swift#L143), [setup presentation](rustyView/Views/RootView.swift#L31), [credential reads](rustyView/App/AppSettings.swift#L26), [disconnect](rustyView/App/AppModel.swift#L125).

Implementation: preserve typed error categories through presentation. Offer Edit Connection for authentication, Watch Downloads when offline, Retry for transient failures, compatibility guidance for schema mismatch, and Manage Storage for storage problems. Add Refresh to empty libraries, Parent/All Movies to empty folders, and Clear Search to no results. Launch into Downloads after an intentional disconnect when usable local content exists, with a nonblocking Connect action. Handle Keychain unavailable versus missing credentials distinctly and make Forget Connection failure state honest and recoverable. First-run setup should briefly explain where server details come from, support field-specific validation and keyboard progression, and offer cancellation of a long connection attempt.

Acceptance: realistic 401, offline, TLS, schema, and storage failures lead to useful actions. An empty fixture becomes populated through Refresh. Forgotten-connection relaunch reaches offline playback without cancelling setup. Inject credential read/delete failures and verify the app does not silently forget its own intended state or claim credentials were removed when they remain.

18. **Preserve browsing location and make navigation feedback immediate.**

Source-confirmed missing explicit ownership; exact scroll symptoms require runtime reproduction. Folder/query changes reuse a ScrollView and retain old entries while loading, with no per-location scroll anchors. Loading feedback can be below the visible grid. The user can be unsure whether a folder tap was received or whether the visible items belong to the new request.

Evidence: [folder navigation](rustyView/Library/LibraryModel.swift#L53), [reload](rustyView/Library/LibraryModel.swift#L92), [grid/feedback](rustyView/Views/LibraryView.swift#L123).

Implementation: define browse-location identity and restoration anchors. New folder/search starts at a deliberate position; returning to a parent or from details restores the prior anchor. Show immediate visible feedback while retaining useful existing content, and prevent old entries from appearing to belong to a new location. Preserve current stale-response suppression and server pagination/generation semantics. Persist browse preferences where it helps returning users.

Acceptance: use several pages and nested folders, navigate from below the fold, return, search, sort, rotate, and interrupt requests. Assert visible item anchors and request ownership, not just the navigation title. Newer results must always win.

19. **Complete accessibility and iPad operation across all states.**

Source-confirmed omissions plus layout risks requiring measurement. Chapter and breadcrumb buttons lack explicit minimum hit height. Repeated delete/cancel controls have identical accessibility labels. Player layout has fixed horizontal groups, caption offsets, and a fixed-height local options sheet. Existing audits cover initial Library and collapsed details more thoroughly than expanded controls, failures, downloads, or player accessibility sizes. No explicit player keyboard/focus behavior is implemented.

Evidence: [chapter rows](rustyView/Views/MovieDetailView.swift#L86), [breadcrumbs](rustyView/Views/LibraryView.swift#L185), [download action labels](rustyView/Views/DownloadsView.swift#L56), [player controls](rustyView/Views/PlayerScreen.swift#L147), [local sheet](rustyView/Views/PlayerScreen.swift#L108), [audit coverage](rustyViewUITests/RustyViewJourneyTests.swift#L397).

Implementation: ensure at least 44-point actionable regions, name destructive actions with the movie title, and announce meaningful progress/state changes without continuous chatter. Make player groups and sheets responsive to large text and short landscape height; reserve safe space for captions. Preserve focus during menus/retries/rotation and keep controls available while assistive interaction needs them. Add keyboard transport/navigation on iPad and honor Reduce Motion. Preserve the current larger-text two-column rule; an optional list layout is a user-tested opportunity, not a prerequisite or an excuse to shrink type.

Acceptance: geometry and semantic audits for expanded chapters, deep breadcrumbs, all download phases, setup/errors/settings, and the full player at accessibility XXXL in both appearances. Manually verify VoiceOver and keyboard on iPad narrow split view, with long synthetic titles/captions. A sidebar is optional; operable navigation and stable state are required. Treat any measured inaccessible essential action as P1 within this work package.

20. **Make Downloads a recognizable movie collection.**

Source-confirmed product gap. Installation sets artwork to nil. Completed rows use generic icons and prioritize quality, audio, and bytes, without posters, synopsis, runtime, resume, search, or detail access. Routine copy can expose “Track ID.” This feels like transfer management rather than a collection ready for a trip.

Evidence: [artwork omission](rustyView/Downloads/DownloadManifestStore.swift#L114), [completed rows](rustyView/Views/DownloadsView.swift#L207), [metadata wording](rustyView/Downloads/DownloadModels.swift#L104).

Implementation: use locally cached posters, recognizable titles, runtime, and resume status; keep a clear play affordance and local details. Move rendition/storage detail below the viewing decision. Add search and useful sort when the collection grows. Keep queued/active/attention-needed work distinguishable from Ready to Watch. Offer Browse Movies from the empty state and a storage-management action from storage failures. Keep deletion explicit and safe; do not add automatic deletion of user copies as part of polish.

Acceptance: disconnected cold launch with a sizeable synthetic collection supports finding, inspecting, resuming, and deleting a movie with zero network requests. Audit long titles, duplicate display titles, different libraries, and large text. Storage totals must agree with managed files after transaction recovery, with labels distinguishing video bytes from whole-package storage once artwork/sidecars are included.

21. **Measure performance and close authentication/lifecycle coverage gaps.**

Bounded verification work, not a claim that every risk already manifests. Manifest load/delete run from the main actor. Artwork decoding and cache insertion occur in a main-actor task; the request limiter bounds active requests but does not remove cancelled waiters immediately. AppModel forwards every child publisher, including four-per-second player updates. Multiple scenes are advertised while all scenes share one app-level model/player. Auth tests prove important same-origin paths but do not establish every AVFoundation redirect/segment/output route.

Evidence: [storage init/delete](rustyView/Downloads/DownloadManager.swift#L217), [artwork queue/decode](rustyView/Views/AuthenticatedArtworkView.swift#L3), [publisher forwarding](rustyView/App/AppModel.swift#L54), [time updates](rustyView/Playback/PlaybackModel.swift#L708), [WindowGroup](rustyView/RustyViewApp.swift#L9), [project settings](project.yml), [asset auth boundary](rustyView/Networking/RustyDLNAClient.swift#L129).

Implementation: profile cold launch, rapid scrolling with large posters, hundreds of local records, playback while browsing, and batches of downloads. Move proven blocking I/O/image work off the main actor, downsample artwork, and make queued cancellation prompt. Narrow observation only where measurements show unnecessary work, preserving nested-model updates. Define and test multiwindow playback ownership or stop advertising unsupported multiwindow behavior. Add hostile-origin redirect, nested playlist/segment, auth-change, and cancellation tests at real URL-loading boundaries. No credential leak was demonstrated in this review; resource-loader authentication alone should not be treated as proof that every redirected AVFoundation request is confined. Keep wire DTO validation/domain mapping at boundaries as these models are refactored.

Acceptance: record baseline and post-change main-thread stalls, memory, active requests, queued waiters, and launch responsiveness on representative hardware. No private metadata or secrets enter traces. Tests prove credentials never reach an untrusted origin and requests that must remain confined are rejected. Verify two-scene state, or verify the chosen single-scene configuration. Measure before making broad architecture changes.

Delivery should follow these dependencies, with each milestone ending in a reviewable working journey:

| Milestone | Scope and dependency | Reviewable outcome |
| --- | --- | --- |
| A — Stop breaking trust | 01, 02, 03, 04; design 10 and the persistence migration before landing 03 | Controls do what they say; playback recovers; failed work survives; Ready to Watch is meaningful |
| B — Make offline a complete experience | 05, 06, 07, 09, 10, 11, 12, 13; build on A's state/queue boundaries | Download with informed choices, leave connectivity, relaunch, inspect and watch with preserved selections |
| C — Remember and guide the person | 08, 14, 17, 18, 20; reuse B's local metadata and identity | Find the unfinished movie immediately, resume/start over, keep preferences, recover without diagnosis |
| D — Finish platform quality | 15, 16, 19, 21; integrate focused checks during A–C as well | Captions, external output, interruptions, assistive interaction, and iPad behavior remain dependable |

Useful implementation boundaries are a canonical library/account identity, stable movie metadata, a source-aware playback request, a prepared-session owner, a durable download queue, and an offline package store. Introduce each to solve the corresponding finding; avoid a broad rewrite. Keep server compatibility/transcode policy in rustyDLNA, preserve schema-v2 compatibility and additive decoding, and retain the dependency-light Apple-framework approach. Update AGENTS.md and README as delivered behavior changes; this plan must not be presented as already implemented product documentation.

Verification needs to follow user journeys and faults, not just component helpers:

| Journey | Required proof |
| --- | --- |
| First launch → connect → watch | Field/recovery behavior, real auth, first playback progress, truthful transport controls |
| Watch → interruption → return | Preserved intent/time, correct audio route, Now Playing position, no surprise resume |
| Download → failure → process relaunch → retry | Durable row and choices, bounded retry, no duplicate task, eventual playable install |
| Download → network policy change | Real byte-range reuse or clearly disclosed unavoidable restart; correct waiting state |
| Download → disconnect → relaunch → details → watch | Cached poster/metadata, tracks/chapters, Resume/Start Over, zero remote requests |
| Prepared stream → repeated seeks/audio change → close | Stable session, increasing generations, bounded producers, exact cancellation |
| Empty/large/deep library → refresh/search/back | Useful actions, correct anchors, pagination ownership, immediate feedback |
| Captions → PiP/AirPlay | Actual visible dialogue and correct timing on hardware, not only an enabled button |
| Install/delete → process death at commit boundaries | Recoverable state, no orphaned storage, no cancelled copy reappearing |
| VoiceOver/keyboard/XXXL/iPad split view | Reachable actions, unique labels, preserved focus, measured geometry and actual operation |

The existing long UI journey should remain as an integration smoke test, while new fault cases should be focused and independent so one early failure cannot hide every later scenario. Each regression needs a demonstrated failing test on the pre-fix code, or a concrete explanation of the fault it detects. Use actual Codable/HTTP/media/file transitions rather than string-presence checks or calculations copied from implementation. Keep unique background-session/store namespaces and teardown termination for every UI test.

Run focused checks for each change, then XcodeGen, the generic Simulator build, and the complete test gate on the dedicated `rustyView Test iPhone`. The repository currently restricts UI automation to that dedicated iPhone; do not silently use the owner's preview or switch automation onto an iPad. Cover iPad manually on an isolated synthetic session, or deliberately establish a dedicated iPad test policy before adding automation. Repeat relevant coverage on iOS 17 when available. Real hardware remains required for background completion, airplane-mode playback, interruptions, storage deletion, authenticated remote streaming, unsupported-media fallback, PiP, and AirPlay.

Product acceptance should include observed usability, beyond a passing test suite. With a small formative group representing ordinary viewers, offline travellers, large-text/VoiceOver users, and iPad keyboard users, give tasks without coaching: connect, find something to watch, resume yesterday's movie, download in a chosen language for a trip, recover from a password error, and reclaim space. Record completion, mis-taps, hesitation, unexpected data/quality outcomes, and whether participants can predict what each primary action will do. No claim that users will love the app is warranted until those journeys feel dependable in practice.

Suggested exit criteria are: every accepted action has immediate visible feedback; every wait has a useful state and safe exit; every recoverable failure offers an action that can change the outcome; returning to an unfinished movie does not require remembering its title; local viewing survives a disconnected process relaunch; explicit playback/download choices remain honored; and storage work is never silently lost. Use these criteria to choose polish work after the trust defects are fixed.
