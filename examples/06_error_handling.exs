# Error handling: catch errors inside Lua with pcall, and catch errors
# in Elixir with structured exception fields.
#
# What to look at:
#   - Lua's `pcall` returns `false, message` instead of propagating an
#     error, so scripts can recover in-band.
#   - When an error escapes a script, `Lua.eval!/2` raises
#     `Lua.RuntimeException` with `:line`, `:source`, and `:call_stack`
#     populated. Pass `source:` so the attribution names your script.

# 1. In-band recovery with pcall.
{[ok?, message], _} =
  Lua.eval!(Lua.new(), ~S[return pcall(function() error("something broke") end)])

IO.inspect(ok?, label: "pcall ok?")
IO.inspect(message, label: "pcall message")
# => pcall ok?: false
# => pcall message: "something broke"

# 2. Let the error escape and inspect the structured exception.
try do
  Lua.eval!(
    Lua.new(),
    """
    local user = nil
    return user.name
    """,
    source: "profile.lua"
  )
rescue
  e in Lua.RuntimeException ->
    IO.inspect(e.source, label: "error source")
    IO.inspect(e.line, label: "error line")
    IO.puts("--- formatted message ---")
    IO.puts(Exception.message(e))
end

# => error source: "profile.lua"
# => error line: 2
# => --- formatted message ---
# =>   at profile.lua:2:
# =>   attempt to index a nil value (local 'user')
