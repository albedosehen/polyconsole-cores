#!/usr/bin/env python3
"""Assemble the cores.poly-console.com site from a build.

    tools/site.py <built-dir> <site-dir> <release-tag>

<built-dir> holds what build.sh wrote for every core (merged from the CI
jobs): the modules and sources/<core>-<commit>.tar.gz. The site gets the
modules, a cores.json the browser app reads, and an index.html that lists
every core with its license and where its source is: upstream at the pinned
commit, and the copy attached to this repository's release <release-tag>.
RELEASE.md, the release notes, is written beside the site directory.
"""

import html
import json
import os
import shutil
import sys

REPO = "https://github.com/albedosehen/polyconsole-cores"
KEYS = ("core", "name", "systems", "license", "license_file", "note", "source", "commit")


def main() -> None:
    built, site, tag = sys.argv[1], sys.argv[2], sys.argv[3]
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    catalog = json.load(open(os.path.join(root, "cores.json")))

    os.makedirs(site, exist_ok=True)
    missing = []
    manifest = []
    for c in catalog:
        files = [f"{c['core']}_libretro.js", f"{c['core']}_libretro.wasm"]
        if not all(os.path.exists(os.path.join(built, f)) for f in files):
            missing.append(c["core"])
            continue
        for f in files:
            shutil.copy2(os.path.join(built, f), os.path.join(site, f))
        source_archive = f"{c['core']}-{c['commit']}.tar.gz"
        if not os.path.exists(os.path.join(built, "sources", source_archive)):
            missing.append(f"{c['core']} (source archive)")
            continue
        entry = {k: c[k] for k in KEYS}
        entry["source_archive"] = f"{REPO}/releases/download/{tag}/{source_archive}"
        patches = sorted(os.listdir(os.path.join(root, "patches", c["core"]))) \
            if os.path.isdir(os.path.join(root, "patches", c["core"])) else []
        entry["patches"] = [f"{REPO}/blob/main/patches/{c['core']}/{p}" for p in patches]
        manifest.append(entry)
    if missing:
        sys.exit("missing from the build: " + ", ".join(missing))

    json.dump(manifest, open(os.path.join(site, "cores.json"), "w"), indent=1)
    open(os.path.join(site, "index.html"), "w").write(page(manifest, tag))
    notes = os.path.join(os.path.dirname(os.path.abspath(site)), "RELEASE.md")
    open(notes, "w").write(release_notes(manifest, tag))
    print(f"{len(manifest)} cores in {site}, release notes in {notes}")


def page(manifest: list, tag: str) -> str:
    esc = html.escape
    rows = []
    for c in manifest:
        tree = f"{c['source']}/tree/{c['commit']}"
        license_url = f"{c['source']}/blob/{c['commit']}/{c['license_file']}"
        patches = "".join(
            f'<br><a href="{esc(p)}">patch: {esc(p.rsplit("/", 1)[1])}</a>' for p in c["patches"]
        )
        note = f'<span class="note">{esc(c["note"])}</span>' if c["note"] else ""
        rows.append(
            f'<tr id="{esc(c["core"])}"><th scope="row">{esc(c["name"])}'
            f'<span class="core">{esc(c["core"])}</span></th>'
            f'<td>{esc(c["systems"])}</td>'
            f'<td><a href="{esc(license_url)}">{esc(c["license"])}</a>{note}</td>'
            f'<td><a href="{esc(tree)}"><code>{esc(c["commit"][:7])}</code></a>'
            f'<br><a href="{esc(c["source_archive"])}">source archive</a>{patches}</td></tr>'
        )
    return f"""<!DOCTYPE html>
<html lang="en-US">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light">
<title>PolyConsole cores</title>
<style>
  :root {{ color-scheme: dark light; --ink: #ececec; --muted: #a0a0a4; --line: #2a2a2d; --ground: #0b0b0c; }}
  @media (prefers-color-scheme: light) {{ :root {{ --ink: #161617; --muted: #5a5a5f; --line: #dcdcdf; --ground: #fafafa; }} }}
  body {{ margin: 0; padding: 32px 16px 64px; background: var(--ground); color: var(--ink);
         font: 16px/1.55 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }}
  main {{ max-width: 1100px; margin: 0 auto; }}
  h1 {{ font-size: 1.75rem; margin: 0 0 8px; }}
  p {{ color: var(--muted); max-width: 46em; }}
  a {{ color: inherit; }}
  .wrap {{ overflow-x: auto; margin-top: 24px; border-top: 1px solid var(--line); }}
  table {{ width: 100%; min-width: 720px; border-collapse: collapse; font-size: 0.9375rem; }}
  th, td {{ text-align: left; vertical-align: top; padding: 12px 16px 12px 0; border-bottom: 1px solid var(--line); }}
  thead th {{ font-size: 0.75rem; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); }}
  .core, .note {{ display: block; font-size: 0.8125rem; color: var(--muted); font-weight: normal; }}
  code {{ font-size: 0.875rem; }}
</style>
</head>
<body>
<main>
<h1>PolyConsole cores</h1>
<p>The emulators <a href="https://poly-console.com">PolyConsole</a> runs in a web browser. Each is a
WebAssembly module built with Emscripten from its own project's source at the commit listed, with
nothing of PolyConsole's linked in; the page that loads one talks to it through the standard libretro
interface. Every emulator keeps its own license. The source each module was built from is linked
upstream and attached to this build's release, <a href="{REPO}/releases/tag/{esc(tag)}">{esc(tag)}</a>,
and the build script and patches are in <a href="{REPO}">the repository</a>.</p>
<p>Several of these emulators allow only non-commercial use. PolyConsole is free, carries no ads, and
takes no payment, and they are offered here on those terms.</p>
<div class="wrap">
<table>
<thead><tr><th scope="col">Emulator</th><th scope="col">Plays</th><th scope="col">License</th><th scope="col">Source</th></tr></thead>
<tbody>
{chr(10).join(rows)}
</tbody>
</table>
</div>
<p>Also inside every module: the Emscripten runtime and system libraries (MIT or NCSA; its musl libc is
MIT, and libc++, libc++abi and compiler-rt are Apache-2.0 with the LLVM exception). PCSX ReARMed and
FinalBurn Neo also link zlib (Zlib license).</p>
</main>
</body>
</html>
"""


def release_notes(manifest: list, tag: str) -> str:
    lines = [
        f"Browser builds of {len(manifest)} libretro cores, served at https://cores.poly-console.com.",
        "",
        "Each `<core>-<commit>.tar.gz` attached here is that core's source tree at the pinned commit,",
        "with its submodules, as the build cloned it and before any patch. Patches are in `patches/`,",
        "and `build.sh` is the build. Every core keeps its own license (see `cores.json`).",
        "",
        "| Core | License | Commit |",
        "| --- | --- | --- |",
    ]
    for c in manifest:
        lines.append(f"| {c['name']} (`{c['core']}`) | {c['license']} | [`{c['commit'][:7]}`]({c['source']}/tree/{c['commit']}) |")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    main()
