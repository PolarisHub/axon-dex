# Axon

A remake of **Dex++** (by Chillz), itself a revival of **Moon's Dex v3** — a full
in-game instance explorer, property editor, script viewer, console, save-instance
tool and 3D viewer for Roblox.

Axon keeps Dex++ feature-for-feature but reorganises the original single ~9k-line
script into a clean, multi-file codebase that still loads from a **single
`loadstring`**, Hydroxide-style: the loader fetches each module from GitHub at
runtime.

## Usage

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/PolarisHub/axon-dex/main/loader.lua"))()
```

That's it. [`loader.lua`](loader.lua) installs a tiny module loader and pulls the
rest of the source (`src/init.lua` + `src/Modules/*.lua`) over HTTP.

## Project structure

```
loader.lua              Public entry point. Sets up the runtime importer
                        (global `Axon.Import`) and runs the bootstrap.
src/
  init.lua              Application core ("Main"): settings, environment
                        detection, dependency wiring, the menu/window system,
                        intro screen, and Main.Init() which boots everything.
  Modules/
    Lib.lua             UI + utility library: Window, ScrollBar, ContextMenu,
                        CodeFrame (syntax-highlighting editor), Checkbox,
                        IconMap, the color/number/colorsequence pickers,
                        Signal, Set, Button, DropDown, ClickSystem, ...
    Explorer.lua        Instance tree, selection, drag/drop, right-click menu,
                        search, nil-instance handling.
    Properties.lua      Property grid with conflict detection, attributes,
                        sub-properties, and the various value editors.
    ScriptViewer.lua    Notepad / decompiler view + function dumper.
    Console.lua         Output console + command line with highlighting.
    ModelViewer.lua     3D viewport preview for parts and models.
    SaveInstance.lua    Front-end for the executor's `saveinstance`.
    SettingsWindow.lua  Live settings editor (persists to `AxonSettings.json`).
```

## How the loader works

Each module is a self-contained file that returns the standard Dex contract:

```lua
return { InitDeps = initDeps, InitAfterMain = initAfterMain, Main = main }
```

`loader.lua` exposes a global `Axon.Import(path)` that downloads
`https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>.lua`, compiles
it once, runs it, and memoises the result. `src/init.lua`'s `Main.LoadModule`
calls `Axon.Import("src/Modules/<Name>")` for each app, then wires dependencies
through `Main.GetInitDeps()` (which injects `Lib`, `service`, `Settings`,
`create`, the Roblox API dump, etc.).

A few values that the original kept in one shared chunk scope are now shared
across files: `game` (a `workspace.Parent` reference), `oldgame`, `cloneref`,
and the `nodes` / `selection` tables. Each module file re-establishes the first
three with a small prelude; `nodes` and `selection` are shared globals owned by
the Explorer.

### Dev vs release

`loader.lua` has a `DevMode` flag (default `true`) that appends a cache-buster to
every request so GitHub's CDN always serves your latest commit while iterating.
Set it to `false` for release so the CDN cache can do its job.

## Adding a module

1. Drop `src/Modules/MyApp.lua` following the `InitDeps / InitAfterMain / Main`
   contract (copy an existing small module like `ModelViewer.lua` as a template).
2. Add `"MyApp"` to `Main.ModuleList` in [`src/init.lua`](src/init.lua) (or load
   it explicitly).
3. Register a menu entry in `Main.CreateMainGui` with `Main.CreateApp{...}`.

## Credits

- **Chillz** — Dex++
- **Moon** — Dex v3
- **Cazan** — 3D preview
- **Toon** — IY Dex & PRs

Axon is maintained under [PolarisHub](https://github.com/PolarisHub).
