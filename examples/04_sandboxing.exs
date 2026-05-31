# Sandboxing: the default VM blocks dangerous functions; you opt back
# in to exactly the operations you trust.
#
# What to look at:
#   - `Lua.new/0` sandboxes a curated list of functions (os.execute,
#     os.exit, os.getenv, require, loadfile, ...). Calling a sandboxed
#     function raises, which `pcall` turns into a `false, message`.
#   - `Lua.new(exclude: [...])` lifts the sandbox for specific paths.
#   - `Lua.new(sandboxed: [...])` replaces the whole sandbox list, and
#     `Lua.new(sandboxed: [])` disables sandboxing entirely.

# By default os.getenv is sandboxed, so pcall reports the failure.
{[ok?, message], _} =
  Lua.eval!(Lua.new(), ~S[return pcall(function() return os.getenv("HOME") end)])

IO.inspect(ok?, label: "os.getenv ok? (default sandbox)")
IO.inspect(message, label: "os.getenv message")
# => os.getenv ok? (default sandbox): false
# => os.getenv message: "Lua runtime error: os.getenv(_) is sandboxed"

# Explicitly allow os.getenv while keeping everything else sandboxed.
allowed = Lua.new(exclude: [[:os, :getenv]])
{[kind], _} = Lua.eval!(allowed, ~S[return type(os.getenv("HOME"))])
IO.inspect(kind, label: "os.getenv type (allowed)")
# => os.getenv type (allowed): "string" (or "nil" if HOME is unset)

# os.execute is still blocked on the `allowed` VM — we only lifted getenv.
{[exec_ok?, _], _} =
  Lua.eval!(allowed, ~S[return pcall(function() return os.execute("echo hi") end)])

IO.inspect(exec_ok?, label: "os.execute ok? (still sandboxed)")
# => os.execute ok? (still sandboxed): false
