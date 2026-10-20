# trkStreamDesc

**A tiny "now playing" bridge between Traktor's broadcast and OBS.**

One small executable (~360 KB) turns Traktor DJ Pro's live broadcast into
animated, OBS-ready "now playing" overlays.

- **Truly thin.** A single native `.exe`. No Python, no Node.js, no .NET, no
  Java, no Icecast server, no installer, no DLLs. Copy it and run it.
- **Zero dependencies.** HTTP, WebSocket (RFC 6455) and Ogg/Vorbis parsing
  are all built in, written from scratch in Free Pascal.
- **Fully OBS compatible.** Every overlay is a plain HTML page made for an
  OBS Browser Source: transparent background, 1920×1080, reconnects by itself.
- **Low footprint.** It never decodes or forwards audio. It only reads the
  track tags, so CPU and memory use are negligible.

> **Disclaimer:** This is an independent project. It is not affiliated with,
> endorsed by, or supported by Native Instruments. "Traktor" is a trademark of
> Native Instruments. trkStreamDesc simply works together with Traktor's
> standard broadcast output.

## Quick start

1. Run `trkstream.exe`.
2. In Traktor: **Preferences → Broadcasting**
   - Address `localhost`, Port `8000`, Format **Ogg Vorbis** (mount and password can be anything).
   - Start broadcasting (the antenna icon).
3. In OBS: add a **Browser Source**
   - URL `http://localhost/neon.html`, size 1920×1080.

The console shows `Traktor (source) connected` and then every track change.

## Command line

    trkstream.exe [-p 80] [-s 8000] [-k password] [--source-any] [page.html ...]

| Option | Meaning |
|---|---|
| `-p`, `--http` | HTTP/WebSocket port for the overlays (default 80) |
| `-s`, `--source` | port Traktor broadcasts to (default 8000) |
| `-k`, `--password` | require this broadcast password (default: none) |
| `--source-any` | accept the broadcast from other machines (default: localhost only) |
| `page.html ...` | serve only these pages; the first one is `/` (default: all `.html`, `/` lists them) |

Console commands: `t Artist - Title` (send a test track), `s` (status), `n` (now playing), `q` (quit).

## Overlays

| File | Style |
|---|---|
| `neon.html` | neon card with a spinning rainbow border, letters drop in |
| `vinyl.html` | record slides out of its sleeve and spins, colors from the track |
| `wave.html` | frosted glass lower third, animated equalizer, previous track |
| `cassette.html` | cassette tape with a hand-written label and running reels |
| `terminal.html` | green phosphor terminal, track data typed out |
| `ledticker.html` | full-width amber LED dot-matrix ticker |
| `retrowave.html` | 80s synthwave: striped sun, moving neon grid, chrome title |
| `minimal.html` | clean Swiss-style lower third |
| `glitch.html` | cyberpunk RGB glitch, CRT power on/off |
| `orbit.html` | round badge, the title orbits the elapsed time |
| `handover.html` | appears only on a track change: previous and new track swap places, then fade out |

Every overlay starts with a "warming up" picture until the first track arrives.
Long titles shrink, get cut with an ellipsis, or scroll. They never overflow.

URL parameters:
- `?demo` cycles sample tracks without a server, which is handy for previews (also works from `file://`).
- `?hide=20` hides the overlay 20 s after a track change. In `handover.html` it sets the hold time (default 7 s).
- `?ws=ws://host/ws` sets the server address when the page is not loaded from trkStreamDesc.

Writing your own overlay takes a few lines. Include `nowplaying.js` and call
`NowPlaying.start({ onTrack, onSource, onMessage })`.

## Protocol

WebSocket `ws://<host>/ws`. Server events: `hello` (on connect), `track` (track change), `status` (Traktor connected or disconnected).

```json
{"type":"track","serverTime":1792313257421,"source":true,
 "track":{"artist":"Justice","title":"D.A.N.C.E.","album":"","genre":"","year":"",
          "started":1792313257421,"tags":{"artist":"Justice","title":"D.A.N.C.E."}}}
```

Requests (JSON or a bare word). An optional `id` is echoed back.
`{"cmd":"get"}` → `now`, `{"cmd":"history","limit":5}` → `history`, `{"cmd":"status"}` → `status`, `{"cmd":"ping"}` → `pong`.

HTTP: `/api/now`, `/api/history`, `/api/status`.

Elapsed time is computed by the client from `started`, synced via `serverTime`.
The track length is not part of the stream.

## Build

Requires Lazarus / Free Pascal 3.2 (`LAZARUS_DIR`, default `D:\lazarus`).

- `build.bat` builds `bin\dev` (debug, runtime checks, heaptrc) and `bin\prod` (optimized), with the overlays.
- `release.bat` builds and packs `dist\trkStreamDesc-win64.zip`.
- `clean.bat` removes the build output.
