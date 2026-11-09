# Third-party notices

This repository contains no game code or assets. It builds on the following
projects; their licenses apply to the parts named here.

| Component | Where | License |
|---|---|---|
| [ReXGlue SDK](https://github.com/rexglue/rexglue-sdk) | `tools/rexglue-sdk` (git submodule, pinned) and the patches in `patches/rexglue-sdk/` | BSD 3-Clause, © 2026 Tom Clay |
| [Xenia](https://github.com/xenia-project/xenia) (via ReXGlue) | kernel, GPU and audio code inside the SDK | BSD 3-Clause, © 2022 Ben Vanik and Xenia contributors |
| [AMD FidelityFX SDK](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK) (ReXGlue fork) | downloaded by CMake at build time for FSR/CAS | MIT, © Advanced Micro Devices, Inc. |
| [SDL_GameControllerDB](https://github.com/mdqinc/SDL_GameControllerDB) | `nascar/gamecontrollerdb.txt` | zlib |

The patches in `patches/rexglue-sdk/` are modifications of BSD-licensed ReXGlue
source and are provided under the same BSD 3-Clause terms.
