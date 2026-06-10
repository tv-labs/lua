---
id: A25
title: Implement string.pack, string.unpack, string.packsize
issue: null
pr: 217
branch: feat/string-pack-unpack
base: main
status: merged
direction: A
unlocks:
  - tpack.lua
  - parts of strings.lua
---

## Goal

Implement `string.pack/2`, `string.unpack/2,3`, and `string.packsize/1`
per Lua 5.3 §6.4.2. These are the only stdlib functions that currently
raise `string.pack not yet implemented`, blocking `tpack.lua` and
parts of `strings.lua`.

The format string mini-language is well-specified: a series of option
characters with optional sizes, controlling endianness, alignment,
signed/unsigned integers, floats, and strings of various length
encodings.

## Out of scope

- `string.format` improvements.
- `string.pack` extensions beyond Lua 5.3 §6.4.2 (no custom format
  options).
- Performance optimization beyond "passes the suite without
  timing out".

## Success criteria

- [x] `string.pack`, `string.unpack`, `string.packsize` exist in
      `lib/lua/vm/stdlib/string.ex` and are reachable from Lua
      (delegating to `Lua.VM.Stdlib.String.Pack`).
- [x] All format options from Lua 5.3 §6.4.2 are supported:
      - [x] `<` `>` `=` `!` (endian and alignment)
      - [x] `b` `B` `h` `H` `i` `I` `l` `L` `j` `J` `T` (signed/
            unsigned integers, with sized variants)
      - [x] `f` `d` `n` (floats)
      - [x] `s` `s1`-`s8` (string with length prefix)
      - [x] `z` (zero-terminated string)
      - [x] `x` (padding byte)
      - [x] `X<op>` (alignment to op's natural alignment)
      - [x] `c<n>` (fixed-size string)
      - [x] ` ` (space, ignored)
- [x] `tpack.lua` passes (promoted to `@ready_tests` in the suite).
- [x] `mix test` count goes up by at least 5 (added 41 unit tests
      covering each option, alignment edge cases, packsize errors).
- [x] No regression elsewhere (1585 → 1626 passing, 0 failures).

## Implementation notes

Use Erlang's binary syntax — most of these formats map directly:

```elixir
# pack i4 little-endian:  <<value::little-signed-32>>
# unpack: <<value::little-signed-32, rest::binary>> = bin
```

The trickiest parts:

- **Alignment** (`!n`, `Xop`): the buffer position must be aligned to
  `n` bytes (or to the natural alignment of the next op). Insert
  zero-padding bytes during pack; advance position during unpack.
- **`s` length prefix**: by default, the length prefix is the same
  size as `size_t` on the platform — for us, that's 8 bytes (we run
  on the 64-bit BEAM). Allow `s1`-`s8` to override.
- **`c<n>` fixed string**: pack pads with zeros, unpack returns
  exactly `n` bytes (no zero-stripping).
- **`packsize` semantics**: returns the size of the packed result if
  the format has no variable-length items (`s`, `z`); raises
  `"variable-size format in packsize"` if it does.

### Suggested module layout

```
lib/lua/vm/stdlib/string/pack.ex   # the parser + packer
```

Keep the format-string parser as a small state machine that walks
the format string once and emits a list of operations (similar to
how `string.format` is structured).

### Files

- `lib/lua/vm/stdlib/string.ex` — register functions.
- `lib/lua/vm/stdlib/string/pack.ex` (new) — format parser, pack,
  unpack, packsize.
- `test/lua/vm/stdlib/string_pack_test.exs` (new) — unit tests
  covering each option, alignment edge cases, packsize errors.

## Verification

```bash
mix format
mix compile --warnings-as-errors
mix test
mix test --include skip
```

Manual:

```elixir
iex> Lua.eval!(Lua.new(), ~S{return string.pack(">i4", 1)})
{[<<0, 0, 0, 1>>], _state}

iex> Lua.eval!(Lua.new(), ~S{return string.unpack(">i4", "\0\0\0\x05")})
{[5, 5], _state}  # value, next position
```

## Risks

- Lua 5.3 size assumptions: integer ops default to `size_t` size,
  which we treat as 8 bytes. If tests assume 4 (32-bit Lua), the
  defaults may need adjusting. Match PUC-Lua's behavior for what we
  build against.
- Alignment is fiddly. Write tests that exercise each `Xop`
  combination explicitly.
- `string.unpack` returns the value(s) plus the next position
  (1-based) as a separate return. Multiple returns through the
  native-function boundary must be preserved.

## Discoveries

- **`string.reverse` was UTF-8-oriented, not byte-oriented.** PUC-Lua's
  `string.reverse` works on bytes; ours called `String.reverse/1`, which
  reverses codepoints and silently mangles non-UTF-8 binaries (including
  any string containing a NUL byte mid-stream). `tpack.lua` exercises
  byte reversal via `s2:reverse()` on packed integer bytes, so the bug
  was on the critical path for this plan. Fixed in scope by switching
  to `:binary.bin_to_list/1` + `Enum.reverse/1` + `:binary.list_to_bin/1`.

- **`string.rep` rejected float counts.** Lua 5.3 always returns float
  from `^`, so `string.rep("c268435456", 2^3)` (from `tpack.lua`'s
  `if packsize("i") == 4 then` branch) was rejected as "number expected,
  got number". Fixed in scope by adding a float-with-integer-value
  coercion clause; consistent with PUC-Lua's `lua_tointegerx`.

- **Alignment must be computed at runtime, not parse time.** The first
  pass of the parser folded alignment padding into the op stream using
  a parser-side running position. That works for fixed-size formats but
  breaks for variable-length ones (`s`, `z`): `pack(">!4 c3 c4 c2 z i4 …")`
  has an `i4` whose alignment depends on the actual length of the `z`
  payload, which the parser cannot know. The parser now emits explicit
  `{:align, n}` ops; pack/unpack/packsize each track their own running
  byte position and compute padding when they hit `:align`. PUC-Lua does
  the same (alignment is computed against `totalsize` in `getdetails`).

- **`unpack` cast semantics for size > SZINT and size == SZINT.**
  PUC-Lua's `unpackint` always casts the read `lua_Unsigned` to
  `lua_Integer` at the end (bit-pattern reinterpretation in C). This
  matters for two cases:
  1. `size > 8`: the low 8 bytes are read *as signed* regardless of the
     `signed?` flag; the flag only changes the expected sign-extension
     byte for the high bytes.
  2. `size == 8` with `I`/`J`/`L`/`T`/`s8`: an unsigned read whose value
     exceeds `2^63-1` wraps to its signed-64-bit equivalent. The suite
     exercises this with `unpack("<J", pack("<j", -1)) == -1`.
  Encoded in `decode_int_with_overflow_check/4` and
  `wrap_to_lua_integer/1`.

- **BEAM has no IEEE ±Infinity, but the suite round-trips `1/0` through
  `pack("f", …)`.** The Lua VM's `safe_divide/4` returns the finite
  stand-ins `±1.0e308` for `±1/0` (see `Lua.VM.Executor.safe_divide/4`).
  When packed as 32-bit float, `1.0e308` overflows to `0x7F800000` (the
  IEEE +Inf bit pattern); decoding those bytes back through Erlang's
  binary syntax raises `MatchError` because the BEAM has no float value
  for inf. `decode_float/3` now recognises the four ±Inf bit patterns
  (32-bit and 64-bit, both endians) and returns the matching stand-in,
  so the round-trip closes.

  Limitations: this only handles ±Inf bit patterns. NaN bit patterns
  still raise from Erlang's binary decode. The suite doesn't exercise
  NaN through `pack`/`unpack`, so this is an accepted gap consistent
  with the existing `safe_divide/4` accepted-divergence note.

## What changed

Files touched:

- `lib/lua/vm/stdlib/string/pack.ex` (new, 619 lines) — format-string
  parser and pack/unpack/packsize evaluators.
- `lib/lua/vm/stdlib/string.ex` — wired the three native functions
  through to the new module; replaced `string.reverse` with a
  byte-oriented implementation; added a float-count clause to
  `string.rep`.
- `test/lua/vm/stdlib/string_pack_test.exs` (new, 312 lines) — 41
  unit tests covering each option, alignment edge cases, and packsize
  errors.
- `test/lua53_suite_test.exs` — promoted `tpack.lua` from
  `@skipped_tests` (computed) to `@ready_tests`.
- `.agents/plans/A25-string-pack-unpack.md` — this file.

Suite delta: 5/24 ready → 6/24 ready. New ready file: `tpack.lua`.

Test count delta: 1585 → 1626 (+41 unit tests). All passing.

PR: tv-labs/lua#217.
