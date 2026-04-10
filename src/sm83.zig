const std = @import("std");

pub const SM83 = struct {
    // Registers
    a: u8 = 0,
    f: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    d: u8 = 0,
    e: u8 = 0,
    h: u8 = 0,
    l: u8 = 0,
    sp: u16 = 0,
    pc: u16 = 0,

    state: State = .fetch,

    pub const State = enum {
        /// Fetch the next opcode from [PC] and decode.
        fetch,
        /// CPU is halted (HALT instruction or unimplemented opcode).
        halted,
    };

    /// Execute one M-cycle.
    pub fn tick(self: *SM83, bus: anytype) void {
        switch (self.state) {
            .fetch => {
                const opcode = bus.read(self.pc);
                self.pc +%= 1;
                self.state = decode(opcode);
            },
            .halted => {},
        }
    }

    fn decode(opcode: u8) State {
        return switch (opcode) {
            0x00 => .fetch, // NOP: 1 M-cycle, done
            else => .halted,
        };
    }
};

// -- Tests -----------------------------------------------------------

const TestBus = struct {
    ram: []u8,

    pub fn read(self: *const TestBus, addr: u16) u8 {
        return self.ram[addr];
    }

    pub fn write(self: *TestBus, addr: u16, value: u8) void {
        self.ram[addr] = value;
    }
};

test "NOP advances PC by 1" {
    var ram = [_]u8{0x00} ** 0x10000;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};

    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u16, 1), cpu.pc);
    try std.testing.expectEqual(SM83.State.fetch, cpu.state);
}

test "consecutive NOPs advance PC" {
    var ram = [_]u8{0x00} ** 0x10000;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};

    for (0..10) |_| cpu.tick(&bus);
    try std.testing.expectEqual(@as(u16, 10), cpu.pc);
}

test "unimplemented opcode halts" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x01; // LD BC, d16 — not yet implemented
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};

    cpu.tick(&bus);
    try std.testing.expectEqual(SM83.State.halted, cpu.state);
}

test "halted CPU does not advance PC" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x01;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};

    cpu.tick(&bus); // hits unimplemented, halts
    const pc_after_halt = cpu.pc;

    cpu.tick(&bus); // should not advance
    try std.testing.expectEqual(pc_after_halt, cpu.pc);
}
