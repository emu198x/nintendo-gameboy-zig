# CPU State Machine Design

**Status:** Accepted
**Date:** 2026-04-10

## Decision

The SM83 uses a stored opcode + M-cycle counter, not a tagged union state machine. Internal temporary registers `z` and `w` carry values between M-cycles.

## Options Considered

**Tagged union:** Each M-cycle phase is a variant in a `union(enum)` with per-state payloads. Compiler enforces exhaustive handling. But the union grows large (30+ variants for boot ROM alone), instruction logic is scattered across decode + multiple state handlers, and adding instructions requires new variants AND decode entries.

**Opcode + M-cycle counter (chosen):** After fetch, the opcode is stored in a `u8`. A `u3` counter tracks which M-cycle we're on. Each instruction is one switch arm with sub-cases per M-cycle. Two temporary bytes (`z`, `w`) carry intermediate values — same role as the Z80's internal WZ latch.

## Rationale

- Each instruction's logic lives in one place, easy to verify against documentation
- Similar opcodes group naturally (e.g., all LD rr, d16 share one switch arm)
- Minimal infrastructure — the state is just (opcode, m_cycle, z, w)
- `else => unreachable` in m_cycle sub-switches panics in debug builds, catching invalid transitions at runtime
- Rule 14 is satisfied: the opcode is read once during fetch, subsequent M-cycles dispatch on the stored value

## How It Works

```
M-cycle 0 (fetch):  read opcode from [PC++], store in self.opcode
                    1M instructions execute and stay at m_cycle 0
                    multi-M instructions set m_cycle = 1

M-cycles 1+:       dispatch on (opcode, m_cycle)
                    each does one bus op, advances m_cycle
                    final M-cycle resets m_cycle to 0
```

## Consequences

- One large switch statement in `execute()` — acceptable, mirrors how real microcode ROMs work
- Less compile-time safety on m_cycle values than a tagged union, but `unreachable` + tests cover the gap
- Adding a new instruction = one new switch arm, no other changes needed
