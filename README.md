# LocalLoom

A macOS menu bar screen recorder. Pick a display or window, optionally a webcam and a
microphone, hit Record, and get a single MP4 in `~/Movies/LocalLoom`. The webcam bubble is
composited straight into the video, so there is nothing to edit afterwards.

**Nothing leaves your Mac.** No account, no upload, no telemetry, no network code at all.

Requires macOS 15 or later.

## Install

1. Download `LocalLoom-1.0.dmg`, open it, and drag **LocalLoom** to **Applications**.
2. Run this once in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/LocalLoom.app
   ```

   LocalLoom is signed but not notarized (that needs a paid Apple Developer account).
   Without this line macOS shows an "app is damaged" dialog whose only options are *Done*
   and *Move to Trash* — the right-click → Open bypass was removed in macOS 26.

3. Open LocalLoom. It lives in the menu bar; there is no Dock icon or window.

Alternatively, from a clone of this repo: `scripts/build.sh && dist/Install.command`.

## Permissions

Click the menu bar icon and press **Record**. The first run asks for:

- **Screen Recording** — required. macOS reads this grant **only when the app launches**, so
  after switching it on you must **quit LocalLoom and open it again**. This is a macOS
  behaviour, not a bug in the app.
- **Camera** and **Microphone** — only if you pick one in the popover. Deny either and
  LocalLoom records the screen without it.

macOS periodically re-asks for screen recording approval. Proper code signing does not
exempt an app from that; only a paid Developer ID with a special entitlement does.

## Using it

| | |
|---|---|
| Start | Menu bar icon → **Entire Screen** or **Window** → camera/mic → **Start Recording** |
| Stop | **⌘⇧8** from anywhere, the floating bar's stop button, or **Stop & Save** |
| Output | `~/Movies/LocalLoom/LocalLoom <date>.mp4`, revealed in Finder when it finishes |

The icon turns into a red dot while recording. Your last-used source, camera, microphone
and quality are remembered.

### Quality

The **Quality** row sets two things:

- **Resolution** — **1080p** (default), **Native** or **720p**. The cap is a bounding box:
  the frame keeps its aspect ratio, is never letterboxed and is never upscaled, so a small
  window records at its own size. A Retina display hands ScreenCaptureKit four times the
  pixels of what it shows in points — a 3008×1692 screen is a 6016×3384 frame — and capping
  that at 1080p is by far the biggest thing you can do to the file size. The downscale
  happens inside `SCStreamConfiguration`, on the GPU, during capture.
- **Format** — **H.264** (default) or **HEVC**. HEVC files are roughly a third smaller for
  the same picture and Apple Silicon encodes them in hardware, but H.264 is the format
  everything accepts, which matters more for a recording you are about to upload.

Bitrates are tuned for screen content, not camera footage: 4.5 Mbps at 1080p30 for H.264
and 2.5 Mbps for HEVC, scaled by pixel count. Keyframes are five seconds apart.

### Choosing a window

**Window** does not open a list. It dims every display and highlights whatever window is
under the pointer, with the app's icon and the window's title, the way the system's own
screenshot tool does. Click to choose it; **esc**, a right click, a click on empty desktop
or switching apps all cancel and leave the previous choice alone.

The window under the pointer is found with `CGWindowListCopyWindowInfo`, which returns
windows front to back — `SCShareableContent` has no defined z-order, so it cannot answer
"which one is on top here". LocalLoom's own windows are filtered out by process id, so the
picker can never target the picker.

### The floating controls

Opening the menu bar popover — and recording — puts two small draggable windows on screen:

- **A control bar** with start/stop, pause/resume, restart and delete, plus the elapsed
  timer. Restart and delete throw footage away, so each one asks for a second click before
  it does anything, and forgets it was asked after a few seconds.
- **A camera circle** showing the live webcam, when a camera is selected. **Where you drag
  the circle is where the bubble lands in the MP4** — the position is normalized against
  the recorded display and read by the compositor for every frame. It is remembered between
  recordings.

Neither window is recorded, and neither are the picker overlays. All of them are excluded
from capture twice over: `sharingType = .none` on the panel itself, and an app-excluding
`SCContentFilter` built after the overlays are on screen.

Recording with no camera is a first-class mode — set Camera to **Off**, and no circle
appears at all.

## Build from source

Only the Xcode Command Line Tools are needed; Xcode itself is not.

```sh
scripts/make-identity.sh   # once: self-signed code-signing identity (no Apple account)
scripts/build.sh           # → dist/LocalLoom.app
scripts/package.sh         # → dist/LocalLoom-<version>.dmg
```

`make-identity.sh` matters more than it looks. An ad-hoc signature's designated requirement
is the binary's hash, so macOS treats every rebuild as a different app and resets the Screen
Recording grant each time. A self-signed certificate gives a stable designated requirement
and the grant survives rebuilds. The first `codesign` run shows a keychain dialog — choose
**Always Allow**.

`scripts/build.sh --universal` produces a universal binary (two builds plus `lipo`;
`swift build --arch` needs XCBuild and does not work here). Plain builds are arm64-only.

## How it works

ScreenCaptureKit delivers BGRA screen frames and — on the *same clock* — microphone PCM.
Each screen frame is composited with the newest available webcam frame by a Metal-backed
`CIContext` and appended to a single `AVAssetWriter` (H.264 or HEVC, plus AAC, one MP4).

Three details do most of the work:

- **Camera frames are never timestamped.** Whatever webcam frame is newest gets drawn onto
  whatever screen frame is being encoded, so audio/video drift between the two capture
  clocks is structurally impossible.
- **A stall watchdog.** ScreenCaptureKit stops emitting frames when the screen does not
  change. Without re-appending the last frame after half a second, long recordings of a
  static screen silently lose their tail.
- **One coordinate conversion, in one place.** `kCGWindowBounds` and `SCWindow.frame` put
  the origin at the top-left of the *primary* display with y going down; `NSWindow` and
  `NSScreen` put it at the bottom-left with y going up. `ScreenGeometry` flips between them
  against the height of the screen whose origin is `(0, 0)` — never `NSScreen.main`, which
  is merely the screen with keyboard focus and is only the same screen when there is one
  monitor. That is why the highlight lands on the right window on a second display.
- **Pause is faked, carefully.** `AVAssetWriter` has no pause API. LocalLoom stops
  appending, suspends the watchdog (which would otherwise pack the pause with duplicated
  frames), and subtracts the accumulated paused time from every later presentation
  timestamp — video and audio alike, so the two stay in sync. A ten-second wall-clock take
  with a four-second pause writes a six-second movie with no frozen gap.

## Limitations

- Mic only; system audio is not recorded yet.
- No editor, no trimming, no zoom effects.
- Self-signed, so the quarantine step above is required.
