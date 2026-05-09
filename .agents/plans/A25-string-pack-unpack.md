---
id: A25
title: Implement string.pack, string.unpack, string.packsize
issue: null
pr: null
branch: feat/string-pack-unpack
base: main
status: in-progress
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

- [ ] `string.pack`, `string.unpack`, `string.packsize` exist in
      `lib/lua/vm/stdlib/string.ex` and are reachable from Lua.
- [ ] All format options from Lua 5.3 §6.4.2 are supported:
      - [ ] `<` `>` `=` `!` (endian and alignment)
      - [ ] `b` `B` `h` `H` `i` `I` `l` `L` `j` `J` `T` (signed/
            unsigned integers, with sized variants)
      - [ ] `f` `d` `n` (floats)
      - [ ] `s` `s1`-`s8` (string with length prefix)
      - [ ] `z` (zero-terminated string)
      - [ ] `x` (padding byte)
      - [ ] `X<op>` (alignment to op's natural alignment)
      - [ ] `c<n>` (fixed-size string)
      - [ ] ` ` (space, ignored)
- [ ] `tpack.lua` passes.
- [ ] `mix test` count goes up by at least 5 (new unit tests).
- [ ] No regression elsewhere.

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

(populated during implementation)
