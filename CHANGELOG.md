# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased


## [v1.0.0-rc.1] - 2026-05-06

This is the first release candidate for `1.0.0`. The library has been
rewritten on a new Elixir-native Lua 5.3 virtual machine, and the public
API is intended to be stable. Please report any regressions before final.

### Added
- New Elixir-native Lua 5.3 virtual machine: lexer, parser, compiler, and
  register-based executor, with no Erlang or C dependencies.
- Standard library: `string` (including `string.format` width/precision and
  the full pattern engine for `find`/`match`/`gmatch`/`gsub`), `table`,
  `math`, `debug`, `io` stubs, `os` (sandboxed), `package`/`require`.
- `_G` global table and Lua 5.3 `_ENV` semantics for global access.
- Full metamethod dispatch: `__index`, `__newindex`, `__call`, plus the
  arithmetic, comparison, length, concat, and `tostring` metamethods.
- Varargs (`...`), multiple returns, generic `for`, `goto`/`label`, `break`,
  protected calls (`pcall`, `xpcall`).
- `userdata` support for passing arbitrary Elixir terms across the boundary.
- Beautiful Lua-style stack traces and error messages with source line
  tracking.
- Lua 5.3 official test suite integration (5/29 files passing on this
  release: `simple_test.lua`, `api.lua`, `bitwise.lua`, `code.lua`,
  `vararg.lua`).
- Benchmark harness comparing against Luerl and PUC-Lua.

### Changed
- **VM backend**: Luerl is no longer a runtime dependency. The library now
  runs on its own Elixir-native VM. Luerl is kept only as a `:benchmark`-env
  dependency for performance comparison.
- Encoded value tags now use the new VM's internal representation:
  `{:tref, integer()}` for tables (replacing `:luerl.tref()`), `{:udref,
  integer()}` for userdata (replacing `:luerl.usdref()`), `{:native_func,
  fun}` for Elixir-defined Lua callables (replacing `:luerl.erl_func()`),
  and `{:lua_closure, _, _}` for compiled Lua functions.
- Parser error messages have a new format. The old Luerl-style
  `"Line 1: syntax error before: ';'"` is now produced by the new parser
  (e.g. `"Expected expression"`); user-visible string contents differ.
- Chunks no longer require a separate "load" step — `Lua.Chunk` now holds a
  compiled prototype and is reusable across `Lua.eval!/2` calls.
- 64-bit integer arithmetic and bitwise ops wrap on overflow per Lua 5.3
  §3.4.1, instead of widening to bignums (Luerl's behaviour).

### Removed
- The `{module(), atom(), list()}` MFA encoding form is no longer accepted
  by `Lua.encode!/2`. Use a function literal or a `deflua` callback
  instead.

### Performance
- Right-size register tuple allocations (#153).
- O(N²) → O(N) upvalue collection in the closure handler (#154).
- O(1) upvalue access by storing upvalues as a tuple (#155).
- Fully tail-recursive CPS executor with line tracking moved off the heap
  (#156).

### Fixed
- 64-bit integer overflow wrapping for arithmetic and bitwise ops (#177).
- Empty/missing-key table reads now return `nil` per Lua 5.3 §3.4.11
  (#179, #200).
- Long-string `[[ ... ]]` lexer handles embedded `]` and bracket levels
  like `[==[ ... ]==]`, including `main.lua`-style headers (#180).
- Comment tokens no longer leak past the lexer in expression lists (#182).
- Stdlib modules are pre-populated in `package.loaded` so `require"io"`
  resolves (#184); module sentinel is set before executing required
  modules (#191).
- For-loop variable now binds per statement, fixing register reuse (#195).
- Closure-handler crash on missing upvalue cells in `get_open_upvalue` and
  `set_open_upvalue` (#196).
- `_ENV` semantics for global variable access (#197).
- Hex literal and string coercion in bitwise ops (#198); `math.fmod`
  implemented for `bitwise.lua` verification (#199).
- Function declaration assigned to in-scope local rather than shadowing
  it (#185).
- Multi-return expansion no longer overflows the register tuple (#189).
- Pattern engine threads VM state through `gsub` callbacks and preserves
  capture order (#188, #190).
- Atom values encode to strings (#158).
- Files containing only comments load successfully.
- Unicode characters supported in Lua scripts.

## [v0.4.0] - 2025-12-06

### Changed
- Upgrade to Luerl 1.5.1

### Fixed
- Warnings on Elixir 1.19

## [v0.3.0] - 2025-06-09

### Added
- Guards for encoded Lua values in `deflua` functions
  - `is_table/1`
  - `is_userdata/1`
  - `is_lua_func/1`
  - `is_erl_func/1`
  - `is_mfa/1`

### Fixed
- `deflua` function can now specify guards when using or not using state

## [v0.2.1] - 2025-05-14

### Added
- `Lua.encode_list!/2` and `Lua.decode_list!/2` for encoding and decoding function arguments and return values

### Fixed
- Ensure that list return values are properly encoded

## [v0.2.0] - 2025-05-14

### Changed
- Any data returned from a `deflua` function, or a function set by `Lua.set!/3` is now validated. If the data is not an identity value, or an encoded value, it will raise an exception. In the past, `Lua` and Luerl would happily accept bad values, causing downstream problems in the program. This led to unexpected behavior, where depending on if the data passed was decoded or not, the program would succeed or fail.


## [v0.1.1] - 2025-05-13

### Added
- `Lua.put_private/3`, `Lua.get_private/2`, `Lua.get_private!/2`, and `Lua.delete_private/2` for working with private state

## [v0.1.0] - 2025-05-12

### Fixed

- Errors now correctly propagate state updates
- Fixed version requirements issues, causing references to undefined `luerl_new`
- Allow Unicode characters to be used in Lua scripts
- Files with only comments can be loaded

### Changed

- Upgrade to Luerl 1.4.1
- Tables must now be explicitly decoded when receiving as arguments `deflua` and other Elixir callbacks

[unreleased]: https://github.com/tv-labs/lua/compare/v1.0.0-rc.1...HEAD
[1.0.0-rc.1]: https://github.com/tv-labs/lua/compare/v0.4.0...v1.0.0-rc.1
[0.4.0]: https://github.com/tv-labs/lua/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/tv-labs/lua/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/tv-labs/lua/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/tv-labs/lua/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/tv-labs/lua/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/tv-labs/lua/compare/v0.0.22...v0.1.0
