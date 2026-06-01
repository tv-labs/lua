# Error messages

When a Lua program fails at runtime, `Lua` raises an Elixir exception whose
message is rendered for humans. The renderer leads with the source location,
states what went wrong, and — for the common type errors — offers a
category-specific suggestion. Color is applied only when the output is going
to a real terminal (`IO.ANSI.enabled?/0`); piping to a file or capturing the
message in a log never embeds raw escape codes.

The rendered message begins with the location and then the body. Because
`Lua.RuntimeException` prefixes `Lua runtime error: `, the first line reads
`Lua runtime error: at <source>:<line>:`; the remaining sections follow:

```
at <source>:<line>:

  <what went wrong>

  <source context, when available>

Stack trace:
  ...

Suggestion:
  ...
```

There is no separate "Runtime Type Error" banner. The public
`Lua.RuntimeException` already prefixes `Lua runtime error: `, and the body
itself ("attempt to ...", "assertion failed: ...") names the category, so a
second header would only be noise.

## Before / after

These examples were captured with ANSI disabled (the same output you get
piping to a file). The "before" column is the output prior to the error
message quality pass.

### Arithmetic on a non-number — `print(x + 1)` with `x = nil`

Before:

```
Lua runtime error: <ESC>[31m<ESC>[1mRuntime Type Error<ESC>[0m

  at gallery.lua:2:

  attempt to perform arithmetic on a nil value (local 'x')
```

After:

```
Lua runtime error: at gallery.lua:2:

  attempt to perform arithmetic on a nil value (local 'x')

Suggestion:
  Arithmetic requires numbers. Make sure both operands are numbers (or strings that can be coerced to numbers).
```

The double label is gone, the location leads, raw ANSI no longer leaks into
piped output, and arithmetic now gets a suggestion (previously the suggestion
clause was dead because it matched an error kind the VM never emits).

### Indexing nil — `print(t.field)` with `t = nil`

After:

```
Lua runtime error: at gallery.lua:2:

  attempt to index a nil value (local 't')

Suggestion:
  You can only index tables. Make sure the value you're indexing is a table, not a nil.
```

### Calling nil — `f()` with `f = nil`

After:

```
Lua runtime error: at gallery.lua:2:

  attempt to call a nil value (local 'f')

Suggestion:
  The value you're trying to call as a function is nil. Check that the function exists and is defined before this point.
```

### Concatenating a non-string/number — `t .. "x"` with `t = {}`

After:

```
Lua runtime error: at gallery.lua:2:

  attempt to concatenate a table value

Suggestion:
  Concatenation (..) requires strings or numbers. Convert other values with tostring() first.
```

### Comparing incompatible types — `1 < "x"`

After:

```
Lua runtime error: at gallery.lua:1:

  attempt to compare number with string

Suggestion:
  Relational operators (< <= > >=) only compare two numbers or two strings. Convert one operand so both sides share a type.
```

This category previously rendered with no suggestion at all.

### Standard library bad argument — `string.upper(nil)`

After:

```
Lua runtime error: at gallery.lua:1:

  bad argument #1 to 'string.upper' (string expected, got nil)
```

### Assertions — `assert(false, "boom")` and `assert(false)`

After:

```
Lua runtime error: at gallery.lua:1:

  assertion failed: boom
```

```
Lua runtime error: at gallery.lua:1:

  assertion failed: assertion failed!
```

The generic "the assertion condition evaluated to false or nil; check your
logic" suggestion has been removed — it was filler that told the reader
nothing the body did not already say.

### Explicit error — `error("something broke")` and `error({code = 1})`

After:

```
Lua runtime error: at gallery.lua:1:

  runtime error: something broke
```

```
Lua runtime error: at gallery.lua:1:

  runtime error: (error object is a table value)
```

Non-string error objects now render PUC-Lua's `(error object is a TYPE
value)` phrasing instead of leaking an internal term such as `{:tref, 12}`.

### Stack overflow — runaway recursion (with a finite `:max_call_depth`)

After:

```
Lua runtime error: runtime error: stack overflow

Stack trace:
  gallery.lua:0: in function 'f'
  gallery.lua:0: in function 'f'
  ... 20 more frames ...
  gallery.lua:0: in function 'f'
  gallery.lua:2: in function 'f'
```

The stack trace collapses the repetitive middle frames into a single count so
the failure does not bury the reader under hundreds of identical lines.

## Pinning the gallery output

The rendered output for each category is pinned inline in
`test/lua/error_gallery_test.exs`: every case carries its Lua source and the
exact expected message, so the assertion lives next to the snippet that
produces it. When the format changes intentionally, update the `expected`
string for the affected case; accidental format drift fails the test loudly.

## Known gaps

A few categories do not yet render ideally because the *data* feeding the
renderer is incomplete — these are data-layer issues, not rendering ones, and
they fall outside the rendering pass that produced this gallery:

- The length operator on a non-string/table (`#5`) and assigning a `nil`/NaN
  table key (`t[nil] = 1`) do not currently raise, so they have no rendered
  message to show.
- The stack-overflow runtime error carries no originating line, so it renders
  without an `at <source>:<line>:` header and its frames show line `0`.

These are noted so the gallery's "world-class" claim is honest about where the
renderer is currently starved of input. They are data-layer follow-ups under
the error-quality umbrella ([#263](https://github.com/tv-labs/lua/issues/263)),
not rendering bugs in this guide.
