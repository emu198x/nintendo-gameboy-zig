const std = @import("std");
const SM83 = @import("sm83.zig").SM83;
const Timer = @import("timer.zig").Timer;

pub const GameBoy = struct {
    cpu: SM83 = .{},
    timer: Timer = .{},
    ram: [0x10000]u8 = [_]u8{0} ** 0x10000,

    t_cycle: u64 = 0,
    cpu_divider: u2 = 0,

    /// Advance the system by one T-cycle.
    /// Timer ticks every T-cycle. CPU ticks every 4th (M-cycle).
    pub fn tick(self: *GameBoy) void {
        self.timer.tick();

        if (self.cpu_divider == 0) {
            self.cpu.tick(self);
        }
        self.cpu_divider +%= 1;

        self.t_cycle += 1;
    }

    // -- Bus interface --------------------------------------------------

    pub fn read(self: *const GameBoy, addr: u16) u8 {
        return switch (addr) {
            0xFF04 => self.timer.readDiv(),
            0xFF05 => self.timer.tima,
            0xFF06 => self.timer.tma,
            0xFF07 => self.timer.readTac(),
            else => self.ram[addr],
        };
    }

    pub fn write(self: *GameBoy, addr: u16, value: u8) void {
        switch (addr) {
            0xFF04 => self.timer.writeDiv(),
            0xFF05 => {
                self.timer.tima = value;
            },
            0xFF06 => {
                self.timer.tma = value;
            },
            0xFF07 => self.timer.writeTac(value),
            else => {
                self.ram[addr] = value;
            },
        }
    }
};

// -- Tests -----------------------------------------------------------

test "tick advances T-cycle count" {
    var gb = GameBoy{};
    gb.tick();
    try std.testing.expectEqual(@as(u64, 1), gb.t_cycle);
}

test "CPU ticks every 4 T-cycles" {
    var gb = GameBoy{};

    // 4 T-cycles = 1 M-cycle = 1 NOP
    for (0..4) |_| gb.tick();
    try std.testing.expectEqual(@as(u16, 1), gb.cpu.pc);

    // 8 T-cycles = 2 M-cycles = 2 NOPs
    for (0..4) |_| gb.tick();
    try std.testing.expectEqual(@as(u16, 2), gb.cpu.pc);
}

test "DIV matches T-cycle count" {
    var gb = GameBoy{};

    // 2048 T-cycles: counter = 0x0800, DIV = 0x08
    for (0..2048) |_| gb.tick();
    try std.testing.expectEqual(@as(u8, 8), gb.timer.readDiv());
}

test "bus reads DIV from timer" {
    var gb = GameBoy{};
    for (0..512) |_| gb.tick();

    // DIV via bus should match timer directly
    try std.testing.expectEqual(gb.timer.readDiv(), gb.read(0xFF04));
}

test "bus write to DIV resets timer" {
    var gb = GameBoy{};
    for (0..512) |_| gb.tick();

    gb.write(0xFF04, 0x00); // any value resets
    try std.testing.expectEqual(@as(u8, 0), gb.read(0xFF04));
}
