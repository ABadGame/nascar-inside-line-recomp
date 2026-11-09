# NASCAR The Game: Inside Line — native Windows port (ReXGlue)

A static recompilation of the Xbox 360 game *NASCAR The Game: Inside Line* into a
native Windows executable, built with the [ReXGlue SDK](https://github.com/rexglue/rexglue-sdk).
The game's PowerPC code is translated ahead of time to C++ and compiled with Clang;
graphics, audio and system calls are handled by ReXGlue's Xenia-derived runtime.

> **This repository contains no game code or assets.** You need your own copy of the
> game (an ISO made from your own disc). `setup.ps1` extracts it, recompiles it and
> builds the executable on your PC. Nothing produced from the game — extracted files,
> generated C++ or the built `nascar.exe` — may be shared.
>
> Not affiliated with or endorsed by NASCAR, Activision, Eutechnyx or Microsoft.

## Status

| | |
|---|---|
| Boots, menus, intro videos, races | ✅ |
| Audio, saves | ✅ |
| Xbox and other controllers (SDL database), keyboard | ✅ |
| Steering wheels (via Wheel setup) | ✅ mapping tested; not yet with a real wheel in a race · no force feedback |
| FSR 1 upscaling + sharpening, 16× anisotropic filtering | ✅ |
| 21:9 ultrawide (native wider view, not stretched) | ✅ optional, off by default; menus tested, races not yet checked |
| Internal resolution above 1× | ⚠️ runs, but renders with corruption (see Known issues) |
| 60 FPS | ❌ not yet |

Supported release: **NASCAR The Game: Inside Line (USA)**, title ID `415608D2`, no title
update. Setup checks the executables and stops if your copy is a different version.

## Requirements

- Windows 10/11 x64, a DirectX 12 GPU, 16 GB RAM or more (32 GB recommended for the build)
- About 10 GB of free disk space
- [Visual Studio 2022 or newer](https://visualstudio.microsoft.com/) with
  **Desktop development with C++** and **C++ Clang tools for Windows** (Clang 20+)
- [CMake](https://cmake.org/) 3.25+, [Ninja](https://ninja-build.org/), [Git](https://git-scm.com/),
  [Python](https://www.python.org/) 3.10+

The launcher checks all of these and can install missing ones for you with `winget`.

## Build

### With the launcher (recommended)

1. Download this repository: **Code → Download ZIP** and extract it, or `git clone` it.
2. Double-click **`Launcher.bat`**.
3. Click **Browse…** and choose your game ISO.
4. If anything in the list says **MISSING**, click **Install missing**. Visual Studio Build
   Tools is a large download, and Windows may ask for administrator permission.
5. Click **Build** and leave it running. The log shows each step.
6. Click **Play**.

### From the command line

```powershell
git clone --recursive <this repository>
cd <repository folder>
pwsh .\setup.ps1 -Iso "D:\path\to\NASCAR the Game - Inside Line (USA).iso"
```

Then start the game with **`Play.bat`**.

The first build takes about an hour: roughly 25 minutes to recompile the game code and
30+ minutes to compile it. It downloads AMD FidelityFX (about 260 MB) once, and the
ReXGlue SDK too if you downloaded a ZIP. Options: `-KeepIntros` keeps the startup videos,
and `-Jobs 4` lowers memory use while compiling.

## Controls

Xbox controllers work out of the box; other pads use the bundled SDL controller database.

| Keyboard | Action |
|---|---|
| W / ↑ | Gas |
| S / ↓ | Brake |
| A D / ← → | Steer |
| Space / Enter | Select (A) |
| Backspace / Esc | Back (B) |
| X / P | Start |
| Tab | Back button |
| Q / E | Shoulder buttons |
| I J K L | Camera / look |

**F3** debug overlay (FPS) · **F4** settings · **F7** achievements

### Steering wheels

Open **`Launcher.bat`** and click **Wheel setup**, then follow the steps: turn the wheel
left, press the gas, press the brake, and press the buttons you want for A, B, Start and so
on (each button can be skipped). The wheel then works as a controller in the game:
steering on the left stick, pedals on the triggers. The game sees it as an Xbox 360 wheel
if SDL recognises it as one.

The setup is saved to `nascar\out\build\win-amd64-release\gamecontrollerdb.user.txt`,
which the game loads after the bundled controller database. Run Wheel setup again to
change it. Wheels that already show up as an Xbox controller (many Logitech and
Thrustmaster models in Xbox mode) work without setup. Force feedback is not supported yet.

## Settings

Edit `nascar\out\build\win-amd64-release\nascar.toml` (created on first build from
`nascar\nascar.toml`). Useful entries:

| Setting | Values |
|---|---|
| `present_effect` | `"fsr"` (default), `"cas"`, `"bilinear"` |
| `present_fsr_sharpness_reduction` | `0.0` sharpest … `2.0` softest (default `0.2`) |
| `anisotropic_override` | `5` = 16× (default) … `0` off |
| `mnk_mode` | `false` to turn off keyboard input |
| `left_stick_deadzone_percentage` | default `8.0` |
| `fullscreen` | `true` / `false` |
| `video_mode_width` / `video_mode_height` | `1280`×`720` = original 16:9 (default), `1680`×`720` = 21:9 ultrawide |
| `render_target_path_d3d12` | set to `"rtv"` **only** together with 21:9 (the default path inverts colours or crashes at 21:9; `"rtv"` inverts colours at 16:9) |

Any setting can also be passed on the command line, e.g. `nascar.exe --fullscreen=false`.
The **F4** overlay's *Save to config* rewrites this file with every non-default setting
(comments are not kept); values passed on the command line are not saved.

## Known issues

- **`resolution_scale` 2 or 3:** no longer crashes, but parts of the screen (screen-aligned
  rectangles) render flat cyan, with small white blocks on a grid. Some render-to-texture
  copies are lost when scaled. Keep it at `1` and use FSR.
- **Frame rate:** the game runs at its original frame rate; there is no unlock yet.
- `gpu_allow_invalid_fetch_constants = true` is required (set by default). The game binds
  textures with an "invalid" fetch-constant type that real hardware ignores; without it,
  video and most of the screen are black.

## How it works

1. `tools/extract_iso.py` reads the XGD2 disc image and extracts the game files.
2. `rexglue codegen` decrypts `default.xex` and `extras.xex` (a second module the game
   loads at startup), finds every function and jump table, and writes C++ for each one.
3. `nascar/nascar_fixups.toml` adds about 300 function entries that the analysis misses:
   leaf functions with no unwind data, vtable thunks, callbacks whose addresses are built
   in code, and functions cut short at an early `blr`. It is generated by
   `tools/find_code_ptrs.py` from the hand-checked list in `nascar/nascar_fixups.base.toml`.
4. `patches/rexglue-sdk/` holds this project's SDK fixes:
   - `0001` — treat Xenon `db8cyc`/`db10cyc`/`db12cyc` delay hints as no-ops; tail-call the
     next function when one falls through into another; dump function bounds after codegen.
   - `0002` — size 3D-as-2D wrapper textures with the draw resolution scale (fixes the
     "device removed" crash at 2×); forward D3D12 debug-layer messages to the log.
   - `0003` — the settings overlay's save escapes strings and skips command-line values
     (a saved Windows path made the whole config unreadable, so the game started black).
   - `0004` — `rexglue extract-icon`: writes a XEX's title icon (XDBF image) to a PNG.
   - `0005` — also load `gamecontrollerdb.user.txt` (`hid_user_mappings_file`) after the
     bundled controller database, for mappings made by Wheel setup.
6. `setup.ps1` extracts the title icon from **your** `default.xex` and embeds it in
   `nascar.exe`, so Explorer and the taskbar show the game's real icon. The icon is never
   stored in this repository.
5. CMake builds the recompiled code together with the runtime and the Xenos GPU plugin.

### Project layout

```
Launcher.bat               build/play window, prerequisite installer, wheel setup
setup.ps1, Play.bat        build from an ISO / start the game (command line)
nascar/                    ReXGlue project: manifest, fixups, app code, settings
patches/rexglue-sdk/       changes applied to the pinned SDK submodule
tools/                     launcher, wheel setup, extraction, analysis and test scripts
tools/wheel_probe/         reads joysticks through the game's SDL for Wheel setup
tools/rexglue-sdk/         ReXGlue SDK (git submodule)
```

### Working on the port

`tools/regen_build_run.ps1 -Tag test` re-runs codegen, rebuilds and launches the game for a
timed test, with logs in `work/`. `tools/capture.ps1` takes a screenshot of the game window
only. To regenerate the fixups after changing the base list, run codegen once with only
the base list included; the patched SDK then writes `nascar/generated/default.bounds.txt`
for `find_code_ptrs.py` to read.

## Credits

ReXGlue SDK by Tom Clay and contributors; Xenia by Ben Vanik and the Xenia project;
AMD FidelityFX; SDL_GameControllerDB. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

This project's own files (scripts, function fixups, project configuration and application
code) are under the [BSD 3-Clause License](LICENSE). The game itself is not included, and
neither it nor anything generated from it is covered by that license. Third-party
components are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
