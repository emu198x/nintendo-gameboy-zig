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

    // Instruction state
    opcode: u8 = 0,
    m_cycle: u3 = 0,
    z: u8 = 0, // internal temp (low byte)
    w: u8 = 0, // internal temp (high byte)
    halted: bool = false,

    /// Execute one M-cycle.
    pub fn tick(self: *SM83, bus: anytype) void {
        if (self.halted) return;

        if (self.m_cycle == 0) {
            self.opcode = bus.read(self.pc);
            self.pc +%= 1;
        }

        self.execute(bus);
    }

    fn execute(self: *SM83, bus: anytype) void {
        switch (self.opcode) {
            0x00 => {}, // NOP

            // LD rr, d16 — BC/DE/HL/SP
            0x01, 0x11, 0x21, 0x31 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.z = bus.read(self.pc);
                    self.pc +%= 1;
                    self.m_cycle = 2;
                },
                2 => {
                    const high = bus.read(self.pc);
                    self.pc +%= 1;
                    self.setReg16(@truncate(self.opcode >> 4), (@as(u16, high) << 8) | self.z);
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            else => {
                self.halted = true;
            },
        }
    }

    // -- Helpers --------------------------------------------------------

    fn wz(self: *const SM83) u16 {
        return (@as(u16, self.w) << 8) | self.z;
    }

    fn setWZ(self: *SM83, value: u16) void {
        self.w = @intCast(value >> 8);
        self.z = @intCast(value & 0xFF);
    }

    fn setReg16(self: *SM83, pair: u2, value: u16) void {
        const high: u8 = @intCast(value >> 8);
        const low: u8 = @intCast(value & 0xFF);
        switch (pair) {
            0 => {
                self.b = high;
                self.c = low;
            },
            1 => {
                self.d = high;
                self.e = low;
            },
            2 => {
                self.h = high;
                self.l = low;
            },
            3 => {
                self.sp = value;
            },
        }
    }

    fn getReg16(self: *const SM83, pair: u2) u16 {
        return switch (pair) {
            0 => (@as(u16, self.b) << 8) | self.c,
            1 => (@as(u16, self.d) << 8) | self.e,
            2 => (@as(u16, self.h) << 8) | self.l,
            3 => self.sp,
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
    try std.testing.expect(!cpu.halted);
    try std.testing.expectEqual(@as(u3, 0), cpu.m_cycle);
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
    ram[0] = 0x76; // HALT — not yet implemented
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};

    cpu.tick(&bus);
    try std.testing.expect(cpu.halted);
}

test "halted CPU does not advance PC" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x76;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};

    cpu.tick(&bus);
    const pc_after_halt = cpu.pc;

    cpu.tick(&bus);
    try std.testing.expectEqual(pc_after_halt, cpu.pc);
}

test "LD SP, d16 takes 3 M-cycles" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x31; // LD SP, $FFFE
    ram[1] = 0xFE;
    ram[2] = 0xFF;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};

    // M-cycle 0: fetch opcode, set up
    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u3, 1), cpu.m_cycle);
    try std.testing.expectEqual(@as(u16, 0), cpu.sp); // not set yet

    // M-cycle 1: read low byte
    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u3, 2), cpu.m_cycle);

    // M-cycle 2: read high byte, complete
    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u3, 0), cpu.m_cycle);
    try std.testing.expectEqual(@as(u16, 0xFFFE), cpu.sp);
    try std.testing.expectEqual(@as(u16, 3), cpu.pc);
}

test "LD HL, d16 loads into H and L" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x21; // LD HL, $9FFF
    ram[1] = 0xFF;
    ram[2] = 0x9F;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};

    cpu.tick(&bus);
    cpu.tick(&bus);
    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0x9F), cpu.h);
    try std.testing.expectEqual(@as(u8, 0xFF), cpu.l);
}

test "LD DE, d16 loads into D and E" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x11; // LD DE, $0104
    ram[1] = 0x04;
    ram[2] = 0x01;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};

    cpu.tick(&bus);
    cpu.tick(&bus);
    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0x01), cpu.d);
    try std.testing.expectEqual(@as(u8, 0x04), cpu.e);
}

test "multi-M-cycle instruction followed by NOP" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x31; // LD SP, $1234
    ram[1] = 0x34;
    ram[2] = 0x12;
    // ram[3] = 0x00 (NOP)
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};

    // LD SP: 3 M-cycles
    cpu.tick(&bus);
    cpu.tick(&bus);
    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u16, 0x1234), cpu.sp);

    // NOP: 1 M-cycle
    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u16, 4), cpu.pc);
    try std.testing.expectEqual(@as(u3, 0), cpu.m_cycle);
}
