# Emu198x-Zig — Knowledge Map

Game Boy (DMG) emulator in Zig 0.15. Full hardware accuracy.

## System

- Crystal: 4.194304 MHz (T-cycles)
- CPU: SM83 @ master / 4 (M-cycles)
- PPU: 1 dot per T-cycle
- Timer: 16-bit counter at T-cycle rate, DIV = upper byte

## Chips

- [SM83 CPU](chips/sm83.md) — modified Z80 core, no IX/IY, no shadow registers
- PPU — pixel FIFO, mode-based state machine (not yet documented)
- APU — 4 channels (not yet documented)
- Timer — DIV/TIMA/TMA/TAC (not yet documented)

## Decisions

- [Clock model](decisions/clock-model.md) — T-cycle master oscillator with /4 CPU divider
