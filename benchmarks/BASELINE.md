# Performance baseline — Luerl gap (1.0.0)

Recorded for the 1.0.0 perf gate (#267). Numbers are the **compiled
`chunk` path** (the production embedding path: compile once, run many)
vs Luerl 1.5 on the same machine, same run.

**Measurement discipline:** benchmarks were run **serially, one `mix run`
at a time, with no other CPU load**. Running them concurrently with
tests/agents inflates deviation badly (table/oop cases swing ±80–260%
under load); the numbers below are the quiet-machine read. Use
`mix run benchmarks/<workload>.exs` (quick mode) one at a time, or
`LUA_BENCH_MODE=full` for publishable figures.

## Environment

- Apple M4 (arm64), Erlang/OTP 29.0, Elixir 1.20.0
- Mode: `quick` (Benchee short windows), serial, 2026-06-15
- Comparison baseline: Luerl `~> 1.5`

## Results (chunk path vs Luerl, after the 1.0 perf pass)

| Workload | chunk vs Luerl | Note |
|---|---|---|
| fibonacci | 1.08× slower | call-heavy worst case |
| table_ops — build (n=100) | ~1.01× (tie) | |
| table_ops — sort | ~1.05× slower | was 1.41×; one-pass `:array.from_list` write-back |
| table_ops — sum / map-reduce / pairs-hash | 0.77×–1.02× | several *faster* than Luerl |
| string_ops — concat | ~0.95× (faster) | |
| string_ops — format-in-loop | ~0.89× (faster) | was 1.37×; bignum float + template cache |
| string.format — long (literal-heavy) | ~0.21× (≈4.8× faster) | |
| string.format — width-flagged | ~0.81× (faster) | was 1.31×; template cache |
| string.format — many-specs | ~0.84× (faster) | was 1.34×; fast path + float + cache |
| closures | ~1.25× slower | at the bar; closure/upvalue machinery |
| oop | 1.07× slower | |

## What changed in the 1.0 perf pass

- **Bare-specifier fast path** in `string.format` — skips the spec parser
  and the no-op sign/width passes for plain `%d`/`%s`/`%x`/… directives.
- **Exact bignum fixed-precision float formatter** — replaces
  `:io_lib.format/2` for `%.Nf`; byte-identical to `:io_lib` over 300k
  random value/precision pairs, far fewer operations.
- **Byte-based decimal placement** — avoids `String.pad_leading/3`'s
  grapheme machinery on ASCII digit strings.
- **Parsed-template cache** — memoizes the compiled `string.format`
  segment list in the threaded `%Lua{}` state (no ETS/process dict), so
  a format string reused across calls is scanned once, not every call.
  This flipped the format-dense loops from slower-than-Luerl to faster.
- **One-pass `table.sort` write-back** — `Table.replace_sequence/2`
  rebuilds the array part with a single `:array.from_list/2` instead of N
  path-copying `:array.set/3` calls. No representation change, so no
  large-`n` regression (cf. the deferred B7 array+hash rewrite).

## Gate verdict

Every workload is within 25% of Luerl on the `chunk` path; string.format,
string_ops, and most table ops are *faster* than Luerl. `closures` sits at
the 1.25× line (closure-creation/upvalue capture) — a candidate for the
ongoing 1.1.x perf-parity work (#267–#269), not a 1.0 blocker.
