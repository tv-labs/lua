-- Simple test to verify test infrastructure
print('testing simple assertions')

assert(1 + 1 == 2)
assert("hello" .. " " .. "world" == "hello world")
assert(true)
assert(not false)

local x = 5
assert(x == 5)

function add(a, b)
  return a + b
end

assert(add(2, 3) == 5)

print('OK')
