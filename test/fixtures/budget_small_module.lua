-- A trivial module: requiring it does negligible instruction work. Used to
-- prove that `require` runs against the caller's `:max_instructions` budget rather
-- than resetting it (the pre-require work must still count).
return 1
