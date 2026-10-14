#!/usr/bin/env bash
# Builds the libretro cores PolyConsole runs in a web browser.
#
# Each core becomes a pair of files, <core>_libretro.js and
# <core>_libretro.wasm: an Emscripten module holding that core's own code
# and Emscripten's runtime, nothing else. It exports the libretro API
# (retro_*); the page that loads it hands it its callbacks, the way a
# desktop frontend opens a core library and calls into it.
#
#   ./build.sh <out-dir> [core ...]
#
# With no cores named, every core in cores.json is built. Needs Linux, git,
# make, python3 and an active Emscripten SDK (`source emsdk/emsdk_env.sh`;
# the published builds use Emscripten 4.0.10).
#
# Sources are cloned at the commits pinned in cores.json into $CORES_SRC
# (default ./src) and built there. Patches in patches/<core>/ are applied on
# top of the pinned source before it is compiled. The output directory gets
# the modules and a cores.json describing them.
#
#   SOURCES=1       also write <out-dir>/sources/<core>-<commit>.tar.gz: the
#                   source tree at that commit with its submodules, as cloned
#                   and before any patch (patches/ holds the patches)
#   CORES_RELINK=1  link from the archive a previous build left
#                   (<clone>/<makefile dir>/pc-web.a) instead of compiling
set -euo pipefail

repo_root="$(cd "$(dirname "$0")" && pwd)"
out="$(realpath -m "${1:?usage: ./build.sh <out-dir> [core ...]}")"
shift
src_root="$(realpath -m "${CORES_SRC:-$repo_root/src}")"
command -v emcc >/dev/null || { echo "emcc not found: source emsdk_env.sh first" >&2; exit 1; }
mkdir -p "$out" "$src_root"
jobs="$(nproc 2>/dev/null || echo 4)"

# The libretro API every core exports, plus the allocator the page uses to
# hand the core strings and buffers.
exports_base=_malloc,_free
for fn in retro_set_environment retro_set_video_refresh retro_set_audio_sample \
  retro_set_audio_sample_batch retro_set_input_poll retro_set_input_state \
  retro_init retro_deinit retro_api_version retro_get_system_info \
  retro_get_system_av_info retro_set_controller_port_device retro_reset retro_run \
  retro_serialize_size retro_serialize retro_unserialize retro_load_game \
  retro_unload_game; do
  exports_base+=",_$fn"
done

# core|source|commit|makefile|link flags, for the cores asked for.
mapfile -t recipes < <(python3 - "$repo_root/cores.json" "$@" <<'PY'
import json, sys
cores = json.load(open(sys.argv[1]))
wanted = set(sys.argv[2:])
unknown = wanted - {c["core"] for c in cores}
if unknown:
    sys.exit(f"unknown core(s): {', '.join(sorted(unknown))}")
for c in cores:
    if not wanted or c["core"] in wanted:
        print("|".join([c["core"], c["source"], c["commit"], c["makefile"], c["link_flags"]]))
PY
)

built=()
for recipe in "${recipes[@]}"; do
  IFS='|' read -r core url commit makefile extra <<<"$recipe"
  dir="$src_root/$(basename "$url")"
  echo "== $core ($url @ ${commit:0:7})"
  if [[ ! -d "$dir/.git" ]]; then
    git init -q "$dir"
    git -C "$dir" remote add origin "$url"
  fi
  if [[ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$commit" ]]; then
    git -C "$dir" fetch -q --depth 1 origin "$commit"
    git -C "$dir" checkout -q --force FETCH_HEAD
  fi
  git -C "$dir" submodule update -q --init --recursive --depth 1

  build_dir="$(dirname "$dir/$makefile")"
  archive="$build_dir/pc-web.a"
  if [[ "${CORES_RELINK:-}" == 1 && -f "$archive" ]]; then
    echo "   relinking $archive"
  else
    git -C "$dir" clean -fdxq
    git -C "$dir" reset -q --hard
    git -C "$dir" submodule foreach -q --recursive 'git clean -fdxq; git reset -q --hard'

    if [[ "${SOURCES:-}" == 1 ]]; then
      # The pristine tree at the pinned commit, submodules included.
      mkdir -p "$out/sources"
      tar -C "$(dirname "$dir")" --exclude=.git -czf "$out/sources/$core-$commit.tar.gz" "$(basename "$dir")"
      echo "   source: sources/$core-$commit.tar.gz"
    fi

    for patch in "$repo_root/patches/$core"/*.patch; do
      [[ -f "$patch" ]] || continue
      echo "   patching: $(basename "$patch")"
      git -C "$dir" apply --whitespace=nowarn "$patch"
    done

    # The core's own makefile and its emscripten platform settings, with
    # STATIC_LINKING off: a static build leaves libretro-common (file
    # streams, VFS, string helpers) for RetroArch to supply at its final
    # link, and the link below plays that part here. A wrapper target
    # archives the objects rather than letting the makefile's
    # shared-library link run.
    objects=OBJECTS
    grep -qE '^OBJECTS\s*[:+]?=' "$dir/$makefile" || objects=OBJS
    printf 'include %s\npc-web.a: $(%s)\n\t$(AR) rcs $@ $(%s)\n' "$(basename "$makefile")" "$objects" "$objects" >"$build_dir/pc-web.mk"
    (cd "$build_dir" && emmake make -f pc-web.mk platform=emscripten STATIC_LINKING=0 -j"$jobs" pc-web.a \
      >"$dir/pc-web-build.log" 2>&1) || {
      tail -40 "$dir/pc-web-build.log" >&2
      echo "$core: build failed (log: $dir/pc-web-build.log)" >&2
      exit 1
    }
  fi

  # Link the core alone into a module a page instantiates on demand. No
  # main: the page calls the libretro API exported here and hands the core
  # its callbacks with addFunction, so the function table may grow; a
  # callback that returns a 64-bit time takes a BigInt. A few minimal cores
  # leave out the memory map, so those two exports are only asked of cores
  # that have them. The filesystem is in-memory; the page writes the game
  # and BIOS files in. (Symbols are read once: `emnm | grep -q` under
  # pipefail fails whenever grep stops early and emnm gets SIGPIPE.)
  exports="$exports_base"
  symbols="$(emnm "$archive" 2>/dev/null || true)"
  for fn in retro_get_memory_data retro_get_memory_size; do
    if grep -qE " [TW] $fn\$" <<<"$symbols"; then
      exports+=",_$fn"
    fi
  done
  keep=()
  IFS=',' read -ra wanted_exports <<<"$exports"
  for sym in "${wanted_exports[@]}"; do
    keep+=("-Wl,-u,${sym#_}")
  done
  # shellcheck disable=SC2086 # link flags from cores.json are word lists
  emcc -O3 "$archive" -o "$out/${core}_libretro.js" "${keep[@]}" \
    -sMODULARIZE=1 -sEXPORT_ES6=1 -sEXPORT_NAME=createCore \
    -sENVIRONMENT=web -sINVOKE_RUN=0 -sEXIT_RUNTIME=0 \
    -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=33554432 -sSTACK_SIZE=2097152 \
    -sFORCE_FILESYSTEM=1 -sALLOW_TABLE_GROWTH=1 -sWASM_BIGINT=1 \
    -sEXPORTED_FUNCTIONS="$exports" \
    -sEXPORTED_RUNTIME_METHODS=FS,HEAPU8,HEAP16,UTF8ToString,stringToNewUTF8,addFunction \
    -lm $extra

  built+=("$core")
  ls -l "$out/${core}_libretro.js" "$out/${core}_libretro.wasm" | awk '{print "   " $5 "\t" $9}'
done

# What is in the output directory, and where each module came from. Cores
# built by an earlier run into the same directory stay listed.
python3 - "$repo_root/cores.json" "$out" "${built[@]}" <<'PY'
import json, os, sys
catalog, out, built = sys.argv[1], sys.argv[2], set(sys.argv[3:])
present = {c["core"]: c for c in json.load(open(catalog))
           if c["core"] in built or os.path.exists(os.path.join(out, c["core"] + "_libretro.wasm"))}
keys = ("core", "name", "systems", "license", "license_file", "note", "source", "commit")
manifest = [{k: c[k] for k in keys} for c in present.values()]
json.dump(manifest, open(os.path.join(out, "cores.json"), "w"), indent=1)
print(f"{len(manifest)} cores in {out}")
PY
