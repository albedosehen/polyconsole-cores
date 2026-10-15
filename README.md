# polyconsole-cores

The emulators [PolyConsole](https://poly-console.com) runs in a web browser,
built from their own source and served at **https://cores.poly-console.com**.

Each libretro core here becomes a WebAssembly module (`<core>_libretro.js` +
`<core>_libretro.wasm`) built with Emscripten from that core's own project at
a pinned commit. Nothing of PolyConsole's is linked into a module: it exports
the standard libretro API, and the page that loads it hands it its callbacks,
the way a desktop frontend opens a core library and calls into it.

## What is here

| Path | What it is |
| --- | --- |
| `cores.json` | Every core: its name, the systems it plays, its license and license file, the upstream source and the commit it is built from, and how it builds. |
| `build.sh` | The build: clone each core at its commit, apply its patches, compile it with its own makefile, and link the module. |
| `patches/<core>/` | Fixes a core needs to build for the browser, applied on top of the pinned upstream source. |
| `tools/site.py` | Assembles the published site and the release notes. |
| `.github/workflows/build.yml` | Builds every core (one job each), then publishes them together. |

## Where the source is

Every published build is a release of this repository. Attached to it is
`<core>-<commit>.tar.gz` for every core: its source tree at the pinned commit,
with its submodules, exactly as the build cloned it and before any patch. With
the patches in `patches/` and `build.sh`, that is everything needed to rebuild
the module. https://cores.poly-console.com lists each core with its license,
its upstream source, and its archive in the current release.

## Using the cores

`https://cores.poly-console.com/cores.json` lists what is served, and each core
is at `https://cores.poly-console.com/<core>_libretro.js` (an ES module whose
default export is the Emscripten factory) and `<core>_libretro.wasm`. Pages
serves them with `Access-Control-Allow-Origin: *`, so a page on another origin
can import a core, as long as its Content-Security-Policy allows this origin in
`script-src` and `connect-src`.

A core that draws with OpenGL ES (ParaLLEl N64, Flycast) is built with WebGL 2
and renders through `RETRO_ENVIRONMENT_SET_HW_RENDER`, as on a phone. `build.sh`
sees it in the core's code (it calls `gl*` functions), and its module also
exports what the page needs to give it a context: `GL` (Emscripten's, to create
a WebGL 2 context and make it current), `emscripten_webgl_get_proc_address`
(to answer the core's `get_proc_address`) and `wasmTable` (to call the
`context_reset` and `context_destroy` the core hands over). The page reads each
frame back from that context.

## Building locally

On Linux (WSL works) with git, make, python3 and Emscripten 4.0.10:

```shell
git clone https://github.com/emscripten-core/emsdk.git && ./emsdk/emsdk install 4.0.10 && ./emsdk/emsdk activate 4.0.10
source emsdk/emsdk_env.sh
./build.sh out                      # every core
./build.sh out snes9x fceumm        # just these
SOURCES=1 ./build.sh out snes9x     # and its source archive
```

Sources are cloned into `./src` (or `$CORES_SRC`). `CORES_RELINK=1` links from
the archive a previous build left, without compiling again.

## Licenses

Every core keeps its own license, listed in `cores.json` and on the site with
a link to the license file at the pinned commit. Several are non-commercial
only (Genesis Plus GX, PicoDrive, Snes9x, Opera, MAME 2003-Plus, FinalBurn Neo);
they are built and served here free of charge, for PolyConsole, which is free.
The Emscripten runtime and system libraries inside every module are MIT or NCSA
(musl libc MIT; libc++, libc++abi and compiler-rt Apache-2.0 with the LLVM
exception), and two cores link zlib (Zlib license).

This repository's own files (the build script, the tools, the workflow and the
patches as changes) are under the MIT license in `LICENSE`.
