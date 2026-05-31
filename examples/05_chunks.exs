# Chunks: compile a script once, then evaluate it many times against
# different states.
#
# What to look at:
#   - `Lua.load_chunk!/2` parses and compiles a string into a reusable
#     `%Lua.Chunk{}`. Compilation happens once.
#   - Passing the chunk to `Lua.eval!/2` skips parsing/compilation on
#     every run — useful for a template or rule evaluated per request.
#   - Each run uses a fresh state with different globals, so the same
#     compiled chunk produces different results.

# Compile once. The VM we compile against doesn't have to be the one we
# run against later.
{chunk, _} = Lua.load_chunk!(Lua.new(), "return greeting .. name .. '!'")

for name <- ["Ada", "Grace", "Edsger"] do
  state =
    Lua.new()
    |> Lua.set!([:greeting], "Hello, ")
    |> Lua.set!([:name], name)

  {[message], _} = Lua.eval!(state, chunk)
  IO.inspect(message, label: "greeting")
end

# => greeting: "Hello, Ada!"
# => greeting: "Hello, Grace!"
# => greeting: "Hello, Edsger!"

# You can also pre-parse with `Lua.parse_chunk/1` to surface syntax
# errors before ever running anything.
{:error, [error]} = Lua.parse_chunk("return 1 +")
IO.inspect(error, label: "syntax error")
