---
id: A48
title: VFS sandbox — route os/require file IO through a virtual filesystem
issue: 297
pr: null
branch: feat/vfs-sandbox
base: main
status: in-progress
direction: A
unlocks:
  - safe-by-default filesystem semantics without sandbox refusals
  - a populate/mount API for embedding hosts to seed files
  - pulling Lua dependencies from a virtual /lua/deps tree via require
---

## Goal

Make filesystem-touching `os`/`require` operations safe by default by
running them against a **virtual filesystem** instead of refusing or
reaching the host disk. Integrate
[`ivarvong/vfs`](https://github.com/ivarvong/vfs) — a `VFS.Mountable`
protocol with pluggable backends — defaulting to the in-memory backend
(`VFS.Memory`). Give embedding hosts an API to seed files and mount
other backends, and use a special directory (`/lua/deps`) as the
mechanism for resolving Lua `require` dependencies.

This is a large feature. This plan ships the **smallest coherent green
slice**:

1. Add `vfs` as a pinned git dependency.
2. Carry a `VFS` value on `Lua.VM.State`, seeded with an empty in-memory
   filesystem in `State.new/0`.
3. Expose a public `Lua` API to write files into the VFS and to mount a
   backend.
4. Reroute the filesystem-touching `os` functions (`os.tmpname`,
   `os.remove`, `os.rename`) through the VFS instead of the host /
   stubs.
5. Reroute the `require` module searcher so `find_module_file/2` reads
   from the VFS (under `package.path`, anchored at `/lua/deps`) instead
   of `File.read/1` on the host disk.

The full `io.*` library rewire (currently a deliberate stub per
ROADMAP) is **out of scope** and deferred — see `## Discoveries`.

## Out of scope

- Rewiring the `io.*` library (`io.open`, `io.read`, `io.write`,
  `io.lines`, `io.tmpfile`, etc.). `io.*` is a stub by design today;
  pointing it at the VFS is a follow-up plan, not this one.
- Removing or rewriting the existing `@default_sandbox` deny-list in
  `lib/lua.ex`. The sandbox stays as-is; this plan adds a safe backing
  store, it does not change which functions are exposed.
- Persistent / disk-backed VFS backends beyond what `vfs` already
  ships. We only wire the in-memory default and the generic mount path.
- Changing the official Lua 5.3 suite deferrals (`files.lua`,
  `attrib.lua`, `verybig.lua`, `main.lua`). Those remain deferred; this
  plan does not attempt to flip them green.
- Publishing `vfs` to hex or vendoring it. We consume it as a git dep
  pinned to a commit.

## Success criteria

- [ ] `vfs` is added to `mix.exs` as a git dep pinned to a specific
      `ref:` (commit `32d2ab618ec12c16fe4f675b5ee8b563c660dd69`), with a
      matching `mix.lock` entry, and `mix deps.get` succeeds.
- [ ] `Lua.VM.State` has a `vfs` field defaulting to an in-memory
      `VFS` (`VFS.new/0` + `VFS.mount/3` with `VFS.Memory.new(%{})`),
      with `@type t` updated. `State.new/0` seeds it.
- [ ] A public `Lua` API exists to (a) write a file into the VFS and
      (b) mount a backend at a path; both return an updated `%Lua{}`.
- [ ] `os.tmpname`, `os.remove`, and `os.rename` operate against the VFS
      on `state.vfs` and thread the updated struct back into `state`;
      none of them touch the host filesystem.
- [ ] `require` resolves modules by reading from the VFS (searcher
      anchored at `/lua/deps`, honoring `package.path` patterns) instead
      of `File.read/1`; a module seeded into `/lua/deps` via the new API
      is loadable with `require`.
- [ ] No source file or test references the plan id (per repo
      convention).
- [ ] `mix format` is clean.
- [ ] `mix compile --warnings-as-errors` passes.
- [ ] `mix test` passes with no regressions (baseline 1,705 passing, 0
      failing, 30 skipped) plus the new VFS tests.
- [ ] `mix test --only lua53` shows no suite regression (6/29 baseline).

## Implementation notes

Exact files:

- **`mix.exs`** — add `{:vfs, github: "ivarvong/vfs", ref:
  "32d2ab618ec12c16fe4f675b5ee8b563c660dd69"}` to `deps/0` (no `only:`
  — it is a runtime dependency). Run `mix deps.get` so `mix.lock` picks
  up the pinned commit.
- **`lib/lua/vm/state.ex`** — add a `vfs` field to `defstruct` and to
  `@type t` (type `VFS.t()`). Seed it in `State.new/0` with an empty
  in-memory filesystem:
  `VFS.new() |> VFS.mount("/", VFS.Memory.new(%{}))`. Add small
  threaded helpers (`State.vfs_read/2`, `State.vfs_write/3`,
  `State.vfs_rm/2`, `State.vfs_exists?/2`) that wrap the VFS calls and
  fold the returned backend struct back onto `state.vfs`.
- **`lib/lua/vm/stdlib/os.ex`** — `os_tmpname/2` returns a virtual path;
  add `os.remove(filename)` and `os.rename(from, to)` against
  `state.vfs`.
- **`lib/lua/vm/stdlib.ex`** — reroute the `require` searcher to read
  from the VFS anchored at `/lua/deps`.
- **`lib/lua.ex`** — add `Lua.write_file/3` and `Lua.mount/3`.
- **`test/lua/vm/stdlib/os_test.exs`** — os.tmpname / os.remove /
  os.rename cases.
- **`test/lua/vfs_test.exs`** (new) — write_file + require, mount +
  require, default VFS empty.

Threading discipline: every `VFS`/`VFS.Mountable` call returns the
(possibly updated) backend struct; always fold it back onto
`state.vfs`. Centralized in the `State.vfs_*` helpers.

## Verification

```bash
mix deps.get
mix format
mix compile --warnings-as-errors
mix test
mix test test/lua/vm/stdlib/os_test.exs
mix test test/lua/vfs_test.exs
mix test --only lua53
```

## Risks

- **vfs requires `elixir ~> 1.18`; this repo declares `~> 1.16`.**
  Pulling vfs as a runtime dep effectively raises the floor to 1.18.
- **Git dep, not hex.** Pinning to a commit `ref:` is mandatory.
- **Threading regressions.** Forgetting to fold a returned VFS struct
  back onto `state.vfs` is a silent correctness bug.
- **require behavior change.** Moving the searcher off the host disk
  means existing host-path require workflows break.
- **Scope creep into io.*.** Resist wiring `io.open` here.

## Discoveries

- `vfs` is not published to hex, so it must be consumed as a git dep
  pinned to commit `32d2ab618ec12c16fe4f675b5ee8b563c660dd69`.
- `vfs` declares `elixir: "~> 1.18"`; this repo declares `~> 1.16`.
- The `%VFS{}` struct itself implements `VFS.Mountable`, so
  `VFS.read_file/2`, `VFS.write_file/4`, `VFS.rm/3`, `VFS.exists?/2`
  accept the `%VFS{}` value and route to the mounted backend, returning
  an updated `%VFS{}` as the threaded value (`{:ok, content, vfs}` /
  `{:ok, vfs}`). Errors are `{:error, %VFS.Error{}}`.
- **Deferred: `io.*` library rewire.** Routing `io.open`, `io.read`,
  `io.write`, `io.lines`, `io.tmpfile`, etc. through the VFS is a
  coherent follow-up plan once this slice is green.
- **Deferred: flipping suite files green.** `files.lua` / `attrib.lua`
  / `verybig.lua` need the `io.*` rewire and suite-harness changes; out
  of scope here.
