# Clock Model

**Status:** Accepted
**Date:** 2026-04-10

## Decision

The master oscillator ticks at T-cycle rate (4.194304 MHz). The CPU gets an M-cycle every 4 T-cycles via a divider counter. The PPU and timer advance every T-cycle.

## Context

The Game Boy's crystal runs at 4.194304 MHz. The SM83 CPU operates at master / 4 (~1.05 MHz). The DIV register is the upper byte of a 16-bit counter that increments every T-cycle. The PPU processes one dot per T-cycle during pixel transfer.

## Rationale

T-cycle is the natural granularity because:

- The timer's internal counter increments every T-cycle
- The PPU advances per T-cycle
- The CPU's M-cycle is a simple /4 divider, exactly how the hardware derives it

Using M-cycle as the base would require multiplying by 4 for timer and PPU updates — working against the grain of the hardware.

## Consequences

- The main loop ticks one T-cycle at a time
- A u2 counter divides the clock for CPU M-cycles (wraps 3 -> 0 = CPU tick)
- Timer, PPU, and other T-cycle components tick every iteration
- CPU ticks every 4th iteration (when divider is 0)
