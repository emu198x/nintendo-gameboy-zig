# Rules

Hard constraints for the Game Boy (DMG) emulator. Non-negotiable.

## Clock

1. The master oscillator (4.194304 MHz crystal) drives the loop. Not the CPU. Not the PPU.
2. One T-cycle = one master clock tick. Everything derives from T-cycles.
3. The SM83 CPU ticks every 4 T-cycles (one M-cycle).
4. The PPU ticks every T-cycle (one dot per T-cycle during pixel transfer).
5. One clock, everything derives. `t_cycle` is the only time counter.

## Timer

6. A 16-bit internal counter increments every T-cycle.
7. DIV (FF04) reads the upper byte (bits 8-15) of the 16-bit counter.
8. Writing any value to DIV resets the entire 16-bit counter to 0.
9. TIMA (FF05) increments on the falling edge of `timer_enabled AND selected_counter_bit`.
10. Changing TAC or resetting DIV can cause spurious TIMA increments via falling edge.

## CPU

11. The SM83 is a cycle-accurate M-cycle state machine. No instruction-level abstraction.
12. Each M-cycle performs exactly one bus operation (read, write, or internal).
13. No "execute whole instruction then count cycles." The CPU steps through M-cycles one at a time.
14. Instruction decode happens in the fetch M-cycle. Subsequent M-cycles are driven by state, not by re-reading the opcode.

## Architecture

15. Components communicate through the bus, not by reaching into each other.
16. No frame-at-a-time rendering. No scanline-at-a-time shortcuts. Tick by tick.
17. The bus routes addresses to components. The CPU sees only read(addr) and write(addr, value).
