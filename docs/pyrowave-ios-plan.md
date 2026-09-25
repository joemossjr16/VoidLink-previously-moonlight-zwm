# PyroWave for VoidLink (iOS/tvOS): status and next steps

Branch: `pyrowave` (this repo and the `moonlight-common-c` submodule, forked to
`joemossjr16/voidlink-c`). Written without Mac/Xcode access, but a GitHub
Actions macOS runner (`.github/workflows/build-pyrowave.yml`) now confirms
every new PyroWave file **syntax-checks cleanly** with real clang/Metal
compiler invocations (see "Build and iterate" below) -- still, nothing has
been linked, run, or looked at on a real device or in the Simulator, and
integration into `VoidLink.xcodeproj`'s own build hasn't been proven (it's
blocked by a pre-existing, unrelated SVGKit issue in this fork). Treat
"compiles" as confirmed, "actually works" as not yet checked.

## What upstream PyroWave provides for Apple platforms

`Themaister/pyrowave`'s `metal/` directory is a complete, separate native Metal
implementation (encoder + decoder, own Xcode project, own MSL shaders) --
"targeting Apple Silicon (Apple7 GPU family and up) on macOS and iOS." This is
almost certainly what backs the macOS beta in Steam's own PyroWave Remote Play
rollout. We only need the decoder half: `pyrowave_metal.h`, `pyrowave_common.mm`,
`pyrowave_decoder.mm`, `pyrowave_bitstream.{cpp,hpp}`, `shaders/pyrowave_msl.h`.

API shape (`pyrowave_metal.h`) mirrors the Vulkan C API we already used for
Android/Windows: `pyrowave_device_create` (from an `id<MTLDevice>`) ->
`pyrowave_decoder_create` (width/height/chroma) -> repeated
`pyrowave_decoder_push_packet` -> `pyrowave_decoder_decode_is_ready` ->
`pyrowave_decoder_decode_gpu_buffer` (writes three single-channel `r16Unorm`
plane textures via compute shaders into a caller-supplied `id<MTLCommandBuffer>`).
`pyrowave_device_is_supported(mtl_device)` gives the capability check.

## Done and pushed

- **Protocol** (`joemossjr16/voidlink-c`, branch `pyrowave`): `Limelight.h` gets
  `VIDEO_FORMAT_PYROWAVE`/`_444`, `SCM_PYROWAVE`/`_444`, and the matching masks
  (folded into the existing `VIDEO_FORMAT_MASK_YUV444`/`SCM_MASK_YUV444`, so
  `chromaSamplingType` negotiation needed no separate code change).
  `RtspConnection.c` matches `PYROWAVE/90000` in the DESCRIBE response (highest
  priority, before the AV1 check). `SdpGenerator.c` sends
  `x-nv-vqos[0].bitStreamFormat = 3` for PyroWave. This mirrors exactly what the
  Windows/Qt and Android Moonlight forks already do against the same Vibepollo
  host, and needs no Vibepollo-side changes.
- **VoidLink's submodule** (`.gitmodules` + pinned commit) points at that fork's
  `pyrowave` branch.
- **`VoidLink/Stream/PyroWaveDecoderRenderer.h`/`.m`**: a self-contained decode +
  present path, independent of `VideoDecoderRenderer`'s VideoToolbox pipeline
  (PyroWave has no relationship to VideoToolbox at all -- it's GPU compute).
  Parses the `PYRW` v1 frame container Vibepollo's host emits (same format the
  Android/Qt clients already parse: `"PYRW"`, u8 version, be_u16 packet count,
  reserved byte, then `{be_u32 length, bytes}` per packet), pushes packets into
  the decoder, and on `pyrowave_decoder_decode_is_ready`, decodes into three
  `r16Unorm` planes and runs a small compute pass to convert BT.709 limited-range
  YCbCr to the `CAMetalLayer`'s drawable and present it.
- **`VoidLink/Metal/PresentPyroWavePlanes.metal`**: the BT.709 conversion kernel
  the renderer above calls by name (`presentPyroWavePlanes`). Straightforward,
  matches the same math the Android/Qt PyroWave clients already use.

## Not done -- concrete next steps, roughly in order

1. **Xcode project wiring.** `VoidLink.xcodeproj` uses classic explicit file
   references for the main source tree (not the newer file-system-synchronized
   groups -- confirmed by checking `project.pbxproj`), so the three new files
   above need real `PBXFileReference`/`PBXBuildFile`/group entries added by hand
   or via Xcode itself, plus:
   - Vendor `pyrowave-metal` (build it as a static/dynamic library from
     upstream's `metal/` directory, or add its sources directly to the target)
     and link `Metal.framework`/`IOSurface.framework` (`metal/CMakeLists.txt`
     already lists exactly these two).
   - Add `PresentPyroWavePlanes.metal` to the target's "Compile Sources" so it
     lands in `-newDefaultLibrary`.
2. **`Connection.m` routing.** `DrSubmitDecodeUnit` (~line 163) already
   reassembles the whole decode unit into one contiguous buffer before calling
   `submitDecodeBuffer` once -- convenient, `PyroWaveDecoderRenderer` needs no
   buffer-chain handling of its own. What's missing: `DrSubmitDecodeUnit`,
   `DrSetup`, and wherever `activeVideoFormat` drives renderer setup all need a
   branch for `VIDEO_FORMAT_MASK_PYROWAVE`, dispatching to a
   `PyroWaveDecoderRenderer` instance instead of the existing
   `VideoDecoderRenderer`. `getActiveCodecName` (~line 114) should also grow a
   case for it, matching its existing pattern for AV1/HEVC.
3. **Offering the format.** Wherever `StreamConfig.supportedVideoFormats` gets
   built (client settings -> `StreamConfiguration`), add a user-facing toggle
   (mirroring `checkbox_enable_pyrowave` in the Android/Qt clients: gated on
   `[PyroWaveDecoderRenderer isSupported]`, SDR-only, off by default, with a
   bitrate/bandwidth warning) that OR's in `VIDEO_FORMAT_PYROWAVE` /
   `VIDEO_FORMAT_PYROWAVE_444`.
4. **Build and iterate -- DONE, green.** `.github/workflows/build-pyrowave.yml`
   on a macOS GitHub Actions runner now confirms every new PyroWave file
   (`third_party/pyrowave-metal/{pyrowave_common.mm,pyrowave_decoder.mm,
   pyrowave_bitstream.cpp}`, `PyroWaveDecoderRenderer.m`,
   `PresentPyroWavePlanes.metal`) syntax-checks cleanly with real
   clang/`xcrun metal` invocations -- the `__bridge` casts and
   `pyrowave_metal.h` struct usage in `PyroWaveDecoderRenderer.m` are correct.
   Getting here took working around several environment issues in this fork
   unrelated to PyroWave: the `VoidLink` scheme has no Simulator destination
   (only a physical-device one, and this runner doesn't have the iOS 18.0
   device platform installed either), and `VoidLink`'s own sources (ours
   included) sit behind a pre-existing broken `SVGKit`/`CocoaLumberjack` SPM
   dependency in the target graph, so a full `xcodebuild` of the whole
   project has never actually reached any of VoidLink's own files on this
   runner. The workflow keeps a best-effort full build as
   `continue-on-error: true` for visibility, and gates on a direct
   `clang -fsyntax-only` pass instead, which is what actually answers "does
   our code compile."
   **Not yet exercised: linking and running.** Syntax-only checks catch type
   errors and API misuse but not link errors (missing symbols, wrong
   architecture) or runtime behavior -- those still need either a real device
   build (next step) or the whole-project SVGKit issue fixed so the app
   target itself builds.
5. **Xcode project pbxproj wiring -- done alongside the syntax-check work.**
   `PBXFileReference`/`PBXBuildFile`/group/Sources entries for all new files
   were added against the `VoidLink` (iOS) target, matching this project's
   existing hand-added-file convention (custom `A701...` IDs), plus
   `$(PROJECT_DIR)/third_party/pyrowave-metal` in `HEADER_SEARCH_PATHS`. This
   is what the CI workflow's own project-level build step exercises (even
   though it can't get past SVGKit on this runner) -- it hasn't been
   validated by a successful whole-project build yet, so treat it as likely
   correct but not proven.
6. **Fix (or route around) the pre-existing SVGKit/CocoaLumberjack SPM
   issue**, if a real device build is wanted without waiting on upstream:
   this blocks the *whole* VoidLink target, not anything PyroWave-specific,
   and was already broken before this branch existed.
   Ruled out on CI: it is **not** a build-parallelism race (`-jobs 1`, fully
   serial, failed *faster* than parallel runs, not slower). `-target`
   manual-order building genuinely processes `SVGKit` before its own
   `CocoaLumberjack` dependency in the target graph -- one run got much
   further (100+ SVGKit files compiled) purely by scheduling luck from an
   already-warm package-resolution cache, not because of anything
   reproducible. A real fix needs one of:
   - **A committed, working `.xcscheme`** (this project has none checked
     in; schemes correctly respect target dependency order, `-target`
     builds don't) with a Simulator destination actually configured -- do
     this from Xcode's GUI on a real Mac, not by hand-authoring the XML.
   - **Xcode's own package-cache reset** (`File > Packages > Reset Package
     Caches`, or `rm -rf ~/Library/Developer/Xcode/DerivedData` plus a
     fresh `xcodebuild -resolvePackageDependencies`), which a local Xcode
     session can do interactively in ways a blind CI loop can't.
   - **Pinning SVGKit/CocoaLumberjack to different versions** if this is a
     known upstream SPM bug (worth a quick search before spending more time
     on it).
7. **Code signing**, once the whole app builds: the user has an Apple
   Developer account already; needs a certificate + provisioning profile
   added as repo secrets to produce an installable IPA rather than a
   simulator/device-generic-only build.
6. **Visual verification on the iPad (M5 -- comfortably above the Apple7 GPU
   minimum)** once an IPA installs: confirm color is right (the BT.709 math in
   `PresentPyroWavePlanes.metal` is unverified against real output) and that
   frame pacing/latency feel reasonable end to end against the Vibepollo host.
