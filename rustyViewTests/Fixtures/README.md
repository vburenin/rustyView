# Synthetic offline validation media

These files contain only generated test patterns and sine waves. No library
media, artwork, titles, or other user metadata was used. FFmpeg is a developer
fixture generator, not an application dependency.

- `synthetic-offline-valid.mp4`: two seconds of a 96×64 test pattern at 12 fps,
  H.264 video and a 440 Hz AAC tone, with an MP4 index at the beginning.
- `synthetic-offline-unsupported.webm`: the same generated dimensions and
  duration, VP9 video and a 220 Hz Opus tone. This exercises retaining an
  original that this AVFoundation file-playback route cannot inspect/play.

Regression tests truncate or corrupt temporary copies of these files. They
verify actual asset loading/sample reading and persistence across store
recreation. Fixture duration is intentionally different from some catalog
metadata to prove that a stale catalog runtime alone cannot reject valid media.
The UI-test target continues to contain only its generated H.264/AAC MP4 and
MPEG-TS fixtures.

`synthetic-hdr10.mp4` is three seconds of a generated 320×180, 12 fps test
pattern and a 440 Hz AAC tone. FFmpeg/libx265 encoded HEVC Main 10, tagged
`hvc1`, with explicit x265 `colorprim=9:transfer=16:colormatrix=9`, BT.2020
primaries, PQ transfer signaling, a 1,000-nit mastering display and 1,000/400-nit
content-light metadata. It contains no source
library media or metadata. Unit tests inspect HDR signaling and decode this
asset with AVFoundation; screen luminance still requires an HDR device.

`synthetic-server-hdr10.mp4` was produced by the native rustyDLNA HTTP route in
an isolated GPU container from the same generated pattern plus English AAC and
a French 5.1 silent AC-3 track. The request selected a 1080p cap, HEVC HDR10 and
all audio tracks. FFprobe and full FFmpeg decoding verified retained 320×180
dimensions, PQ signaling, both languages and default French 5.1. AVFoundation
tests inspect the stored asset, select the actual French option, and play it.
No production media was used.

`synthetic-native-tracks.mp4` uses the first six seconds of the UI target's
generated `synthetic-multiaudio.mp4` (H.264 and two AAC tones), plus one generated
MP4 text subtitle reading “Native paper lantern cue” from 0 to 5.5 seconds.
FFmpeg copied video/audio and encoded the generated SRT as `mov_text`, tagged
English. This asset proves native legible selection and switching between
embedded and owned sidecar captions against AVFoundation. The UI fixture
`synthetic-native-caption.mp4` copies these same bytes to verify that native
dialogue is visibly rendered by the player and disappears when switched Off.
