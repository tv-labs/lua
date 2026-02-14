source = File.read!("test/lua53_tests/constructs.lua")
lines = String.split(source, "\n")

chunk = Enum.take(lines, 96) |> Enum.join("\n")

lua = Lua.new(exclude: [[:package], [:require]])
{_, _lua} = Lua.eval!(lua, chunk)
IO.puts("OK")
