# Synthetic journey media

All media here is generated H.264/AAC. It contains test graphics and tones,
with no production library content or identifiable metadata.

`synthetic-native-caption.mp4` is a byte-for-byte copy of the reviewed unit
fixture `rustyViewTests/Fixtures/synthetic-native-tracks.mp4`: six seconds of
generated H.264 video, English/French AAC tones, and a generated native mov_text
cue reading “Native paper lantern cue” from 0 to 5.5 seconds. Its source and
generation details are documented in the unit fixture README. The UI test
recognizes the actual decoded dialogue in a screenshot, then selects Off and
checks that those pixels disappear; it does not substitute an accessibility
label for native subtitle rendering.

The existing `synthetic-playback.mp4` and `synthetic-playback.ts` support the
original authenticated browsing/playback/download journey. The three
`synthetic-stall-0.ts`, `synthetic-stall-1.ts`, and `synthetic-stall-2.ts` files
split the first six seconds of that generated MP4 into two-second HLS segments.
The fault server advertises these as a growing EVENT playlist so tests can
decode real frames, stop delivery, observe recovery, and resume delivery.

The short segments were generated with FFmpeg using H.264, yuv420p, AAC, fixed
48-frame keyframes, a two-second HLS segment target and no playlist size limit:

```sh
ffmpeg -i synthetic-playback.mp4 -t 6 -c:v libx264 -preset veryfast -crf 28 \
  -pix_fmt yuv420p -g 48 -keyint_min 48 -sc_threshold 0 -c:a aac -b:a 96k \
  -hls_time 2 -hls_list_size 0 -hls_segment_filename synthetic-stall-%d.ts \
  synthetic-stall.m3u8
```

Only the three reviewed media segments are included; the test server generates
its own playlist. FFmpeg is not an application dependency.

`synthetic-multiaudio.mp4` retains the generated 25-second H.264 video and adds
two distinguishable AAC tones, tagged English and French. It has no embedded
subtitle codec; the test server supplies generated WebVTT separately.

```sh
ffmpeg -i synthetic-playback.mp4 -f lavfi \
  -i 'sine=frequency=880:sample_rate=44100:duration=25' \
  -map 0:v:0 -map 0:a:0 -map 1:a:0 -c:v copy -c:a aac -b:a 64k \
  -metadata:s:a:0 language=eng -metadata:s:a:0 title='English tone' \
  -metadata:s:a:1 language=fra -metadata:s:a:1 title='French tone' \
  -disposition:a:0 default -disposition:a:1 0 -t 25 -movflags +faststart \
  synthetic-multiaudio.mp4
```
