const std = @import("std");

pub const Timer = struct {
    counter: u16 = 0,
    tima: u8 = 0,
    tma: u8 = 0,
    tac: u8 = 0,
    /// Set to true when TIMA overflows. GameBoy.tick consumes this to
    /// raise the timer interrupt flag (IF bit 2).
    overflow_pending: bool = false,

    /// Advance the timer by one T-cycle.
    pub fn tick(self: *Timer) void {
        const old_bit = self.timerBit();
        self.counter +%= 1;
        const new_bit = self.timerBit();

        // TIMA increments on falling edge of (enabled AND selected bit)
        if (old_bit and !new_bit) {
            self.incrementTima();
        }
    }

    pub fn readDiv(self: *const Timer) u8 {
        return @intCast(self.counter >> 8);
    }

    /// Writing any value to DIV resets the entire 16-bit counter.
    /// If the selected timer bit was high, the reset causes a falling edge.
    pub fn writeDiv(self: *Timer) void {
        const old_bit = self.timerBit();
        self.counter = 0;
        if (old_bit) {
            self.incrementTima();
        }
    }

    pub fn readTac(self: *const Timer) u8 {
        return self.tac;
    }

    /// Writing TAC can cause a spurious TIMA increment if the selected bit
    /// transitions from high to low (falling edge).
    pub fn writeTac(self: *Timer, value: u8) void {
        const old_bit = self.timerBit();
        self.tac = value;
        const new_bit = self.timerBit();
        if (old_bit and !new_bit) {
            self.incrementTima();
        }
    }

    fn incrementTima(self: *Timer) void {
        self.tima +%= 1;
        if (self.tima == 0) {
            // Overflow: reload from TMA and flag the interrupt.
            // TODO: real hardware delays reload by 1 M-cycle.
            self.tima = self.tma;
            self.overflow_pending = true;
        }
    }

    /// Returns the current state of (timer_enabled AND selected_counter_bit).
    /// TIMA increments on the falling edge of this combined signal.
    fn timerBit(self: *const Timer) bool {
        if (self.tac & 0x04 == 0) return false;
        const clock_select: u2 = @truncate(self.tac);
        const bit_pos: u4 = switch (clock_select) {
            0 => 9, // every 1024 T-cycles
            1 => 3, // every 16 T-cycles
            2 => 5, // every 64 T-cycles
            3 => 7, // every 256 T-cycles
        };
        return (self.counter >> bit_pos) & 1 != 0;
    }
};

// -- Tests -----------------------------------------------------------

test "DIV increments every 256 T-cycles" {
    var timer = Timer{};
    for (0..256) |_| timer.tick();
    try std.testing.expectEqual(@as(u8, 1), timer.readDiv());
}

test "DIV reads upper byte of counter" {
    var timer = Timer{};
    for (0..1024) |_| timer.tick();
    try std.testing.expectEqual(@as(u8, 4), timer.readDiv());
}

test "writing DIV resets counter to zero" {
    var timer = Timer{};
    for (0..512) |_| timer.tick();
    try std.testing.expectEqual(@as(u8, 2), timer.readDiv());
    timer.writeDiv();
    try std.testing.expectEqual(@as(u8, 0), timer.readDiv());
    try std.testing.expectEqual(@as(u16, 0), timer.counter);
}

test "counter wraps at 16 bits" {
    var timer = Timer{};
    for (0..65536) |_| timer.tick();
    try std.testing.expectEqual(@as(u16, 0), timer.counter);
    try std.testing.expectEqual(@as(u8, 0), timer.readDiv());
}

test "TIMA increments at selected rate" {
    var timer = Timer{};
    timer.tac = 0x05; // enabled, clock select 01 = bit 3 = every 16 T-cycles

    for (0..16) |_| timer.tick();
    try std.testing.expectEqual(@as(u8, 1), timer.tima);

    for (0..16) |_| timer.tick();
    try std.testing.expectEqual(@as(u8, 2), timer.tima);
}

test "TIMA does not increment when disabled" {
    var timer = Timer{};
    timer.tac = 0x01; // disabled, clock select 01

    for (0..64) |_| timer.tick();
    try std.testing.expectEqual(@as(u8, 0), timer.tima);
}

test "writeDiv falling edge increments TIMA" {
    var timer = Timer{};
    timer.tac = 0x05; // enabled, clock select 01 = bit 3

    // Advance until bit 3 is set (counter = 8, binary 1000)
    for (0..8) |_| timer.tick();
    try std.testing.expectEqual(@as(u16, 8), timer.counter);

    // Reset DIV: bit 3 goes from 1 to 0 = falling edge
    timer.writeDiv();
    try std.testing.expectEqual(@as(u8, 1), timer.tima);
}
