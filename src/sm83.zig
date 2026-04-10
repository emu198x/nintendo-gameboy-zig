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

            // LD r, d8 — load immediate into register (2M)
            0x06, 0x0E, 0x16, 0x1E, 0x26, 0x2E, 0x3E => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.setReg8(@truncate(self.opcode >> 3), bus.read(self.pc));
                    self.pc +%= 1;
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // LD rr, d16 — BC/DE/HL/SP (3M)
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

            // LD r, r / LD r, (HL) / LD (HL), r — register transfers and memory (1-2M)
            // 0x76 is HALT, not LD (HL), (HL)
            0x40...0x75, 0x77...0x7F => {
                const dst: u3 = @truncate(self.opcode >> 3);
                const src: u3 = @truncate(self.opcode);

                if (dst == 6) {
                    // LD (HL), r — write register to memory (2M)
                    switch (self.m_cycle) {
                        0 => {
                            self.m_cycle = 1;
                        },
                        1 => {
                            bus.write(self.hl(), self.getReg8(src));
                            self.m_cycle = 0;
                        },
                        else => unreachable,
                    }
                } else if (src == 6) {
                    // LD r, (HL) — read memory into register (2M)
                    switch (self.m_cycle) {
                        0 => {
                            self.m_cycle = 1;
                        },
                        1 => {
                            self.setReg8(dst, bus.read(self.hl()));
                            self.m_cycle = 0;
                        },
                        else => unreachable,
                    }
                } else {
                    // LD r, r — register to register (1M)
                    self.setReg8(dst, self.getReg8(src));
                }
            },

            // LD A, (BC) / LD A, (DE) — read from register pair address (2M)
            0x0A, 0x1A => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    const pair: u2 = @truncate(self.opcode >> 4);
                    self.a = bus.read(self.getReg16(pair));
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // LD (HL+), A / LD (HL-), A — write A to [HL], then inc/dec HL (2M)
            0x22, 0x32 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    const addr = self.hl();
                    bus.write(addr, self.a);
                    const new_hl = if (self.opcode == 0x22) addr +% 1 else addr -% 1;
                    self.h = @intCast(new_hl >> 8);
                    self.l = @intCast(new_hl & 0xFF);
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // LD A, (HL+) / LD A, (HL-) — read [HL] into A, then inc/dec HL (2M)
            0x2A, 0x3A => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    const addr = self.hl();
                    self.a = bus.read(addr);
                    const new_hl = if (self.opcode == 0x2A) addr +% 1 else addr -% 1;
                    self.h = @intCast(new_hl >> 8);
                    self.l = @intCast(new_hl & 0xFF);
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // LDH (a8), A — write A to [$FF00 + imm8] (3M)
            0xE0 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.z = bus.read(self.pc);
                    self.pc +%= 1;
                    self.m_cycle = 2;
                },
                2 => {
                    bus.write(0xFF00 | @as(u16, self.z), self.a);
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // LDH A, (a8) — read [$FF00 + imm8] into A (3M)
            0xF0 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.z = bus.read(self.pc);
                    self.pc +%= 1;
                    self.m_cycle = 2;
                },
                2 => {
                    self.a = bus.read(0xFF00 | @as(u16, self.z));
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // LD ($FF00+C), A — write A to [$FF00 + C] (2M)
            0xE2 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    bus.write(0xFF00 | @as(u16, self.c), self.a);
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

    fn getReg8(self: *const SM83, reg: u3) u8 {
        return switch (reg) {
            0 => self.b,
            1 => self.c,
            2 => self.d,
            3 => self.e,
            4 => self.h,
            5 => self.l,
            6 => unreachable, // (HL) handled separately
            7 => self.a,
        };
    }

    fn setReg8(self: *SM83, reg: u3, value: u8) void {
        switch (reg) {
            0 => {
                self.b = value;
            },
            1 => {
                self.c = value;
            },
            2 => {
                self.d = value;
            },
            3 => {
                self.e = value;
            },
            4 => {
                self.h = value;
            },
            5 => {
                self.l = value;
            },
            6 => unreachable, // (HL) handled separately
            7 => {
                self.a = value;
            },
        }
    }

    fn hl(self: *const SM83) u16 {
        return (@as(u16, self.h) << 8) | self.l;
    }

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

test "LD A, d8 loads immediate into A" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x3E; // LD A, $42
    ram[1] = 0x42;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};

    cpu.tick(&bus);
    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0x42), cpu.a);
    try std.testing.expectEqual(@as(u16, 2), cpu.pc);
}

test "LD B, A copies register" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x47; // LD B, A
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.a = 0xAB;

    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0xAB), cpu.b);
    try std.testing.expectEqual(@as(u3, 0), cpu.m_cycle); // 1M instruction
}

test "LD (HL), A writes to memory" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x77; // LD (HL), A
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.a = 0xFF;
    cpu.h = 0xC0;
    cpu.l = 0x00;

    cpu.tick(&bus);
    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0xFF), ram[0xC000]);
}

test "LD A, (HL) reads from memory" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x7E; // LD A, (HL)
    ram[0x8000] = 0xBE;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.h = 0x80;
    cpu.l = 0x00;

    cpu.tick(&bus);
    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0xBE), cpu.a);
}

test "LD (HL-), A writes and decrements HL" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x32; // LD (HL-), A
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.a = 0x42;
    cpu.h = 0x9F;
    cpu.l = 0xFF;

    cpu.tick(&bus);
    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0x42), ram[0x9FFF]);
    try std.testing.expectEqual(@as(u8, 0x9F), cpu.h);
    try std.testing.expectEqual(@as(u8, 0xFE), cpu.l);
}

test "LD A, (DE) reads from DE address" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x1A; // LD A, (DE)
    ram[0x0104] = 0xCE;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.d = 0x01;
    cpu.e = 0x04;

    cpu.tick(&bus);
    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0xCE), cpu.a);
}

test "LDH (a8), A writes to IO region" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0xE0; // LDH ($47), A
    ram[1] = 0x47;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.a = 0xFC;

    cpu.tick(&bus);
    cpu.tick(&bus);
    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0xFC), ram[0xFF47]);
    try std.testing.expectEqual(@as(u16, 2), cpu.pc);
}

test "LD (FF00+C), A writes to IO region" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0xE2;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.a = 0x80;
    cpu.c = 0x11;

    cpu.tick(&bus);
    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0x80), ram[0xFF11]);
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
