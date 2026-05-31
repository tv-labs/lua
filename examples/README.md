# Examples

Runnable, end-to-end examples of embedding Lua in Elixir. Each file is a
self-contained script you can run with:

```bash
mix run examples/01_quickstart.exs
```

Every example prints its output with the expected result in a trailing
comment, so you can compare what you see against what's documented.

| Example | What it shows |
| --- | --- |
| [`01_quickstart.exs`](01_quickstart.exs) | Evaluate Lua and read the result back in Elixir. |
| [`02_userdata.exs`](02_userdata.exs) | Pass an Elixir struct to Lua as userdata and call Elixir methods on it. |
| [`03_custom_stdlib.exs`](03_custom_stdlib.exs) | Expose Elixir functions to Lua, including extending `math`. |
| [`04_sandboxing.exs`](04_sandboxing.exs) | The default sandbox and how to allow specific `os.*` operations. |
| [`05_chunks.exs`](05_chunks.exs) | Compile a chunk once, evaluate it many times against different states. |
| [`06_error_handling.exs`](06_error_handling.exs) | `pcall`, structured exception fields, and source/line attribution. |

These examples are covered by a smoke test (`test/examples_test.exs`)
that runs each one and asserts it completes without raising.
