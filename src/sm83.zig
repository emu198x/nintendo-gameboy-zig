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
    ime: bool = false, // interrupt master enable

    pub const flag_z: u8 = 0x80;
    pub const flag_n: u8 = 0x40;
    pub const flag_h: u8 = 0x20;
    pub const flag_c: u8 = 0x10;

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

            // LD (HL), d8 — load immediate into memory (3M)
            0x36 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.z = bus.read(self.pc);
                    self.pc +%= 1;
                    self.m_cycle = 2;
                },
                2 => {
                    bus.write(self.hl(), self.z);
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

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

            // LD (BC), A / LD (DE), A — write A to register pair address (2M)
            0x02, 0x12 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    const pair: u2 = @truncate(self.opcode >> 4);
                    bus.write(self.getReg16(pair), self.a);
                    self.m_cycle = 0;
                },
                else => unreachable,
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

            // LD (a16), A — write A to absolute address (4M)
            0xEA => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.z = bus.read(self.pc);
                    self.pc +%= 1;
                    self.m_cycle = 2;
                },
                2 => {
                    self.w = bus.read(self.pc);
                    self.pc +%= 1;
                    self.m_cycle = 3;
                },
                3 => {
                    bus.write(self.wz(), self.a);
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // LD A, (a16) — read from absolute address into A (4M)
            0xFA => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.z = bus.read(self.pc);
                    self.pc +%= 1;
                    self.m_cycle = 2;
                },
                2 => {
                    self.w = bus.read(self.pc);
                    self.pc +%= 1;
                    self.m_cycle = 3;
                },
                3 => {
                    self.a = bus.read(self.wz());
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

            // INC r / DEC r — 8-bit register (1M)
            0x04, 0x05, 0x0C, 0x0D, 0x14, 0x15, 0x1C, 0x1D,
            0x24, 0x25, 0x2C, 0x2D, 0x3C, 0x3D,
            => {
                const reg: u3 = @truncate(self.opcode >> 3);
                const val = self.getReg8(reg);
                const is_dec = self.opcode & 1 != 0;
                const result = if (is_dec) val -% 1 else val +% 1;
                self.setReg8(reg, result);

                self.f = self.f & flag_c; // preserve carry
                if (result == 0) self.f |= flag_z;
                if (is_dec) {
                    self.f |= flag_n;
                    if (val & 0xF == 0) self.f |= flag_h;
                } else {
                    if (val & 0xF == 0xF) self.f |= flag_h;
                }
            },

            // INC (HL) / DEC (HL) — read-modify-write (3M)
            0x34, 0x35 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.z = bus.read(self.hl());
                    self.m_cycle = 2;
                },
                2 => {
                    const is_dec = self.opcode & 1 != 0;
                    const result = if (is_dec) self.z -% 1 else self.z +% 1;
                    bus.write(self.hl(), result);

                    self.f = self.f & flag_c;
                    if (result == 0) self.f |= flag_z;
                    if (is_dec) {
                        self.f |= flag_n;
                        if (self.z & 0xF == 0) self.f |= flag_h;
                    } else {
                        if (self.z & 0xF == 0xF) self.f |= flag_h;
                    }
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // INC rr / DEC rr — 16-bit register pair (2M, no flags)
            0x03, 0x13, 0x23, 0x33, 0x0B, 0x1B, 0x2B, 0x3B => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    const pair: u2 = @truncate(self.opcode >> 4);
                    const val = self.getReg16(pair);
                    self.setReg16(pair, if (self.opcode & 0x08 != 0) val -% 1 else val +% 1);
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // ALU A, r — register operand (1M) / ALU A, (HL) — memory operand (2M)
            0x80...0xBF => {
                const op: u3 = @truncate(self.opcode >> 3);
                const src: u3 = @truncate(self.opcode);

                if (src == 6) {
                    // ALU A, (HL) — 2M
                    switch (self.m_cycle) {
                        0 => {
                            self.m_cycle = 1;
                        },
                        1 => {
                            self.aluOp(op, bus.read(self.hl()));
                            self.m_cycle = 0;
                        },
                        else => unreachable,
                    }
                } else {
                    self.aluOp(op, self.getReg8(src));
                }
            },

            // ALU A, d8 — immediate operand (2M)
            0xC6, 0xCE, 0xD6, 0xDE, 0xE6, 0xEE, 0xF6, 0xFE => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    const op: u3 = @truncate(self.opcode >> 3);
                    self.aluOp(op, bus.read(self.pc));
                    self.pc +%= 1;
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // DI — disable interrupts (1M)
            0xF3 => {
                self.ime = false;
            },

            // EI — enable interrupts (1M, takes effect after next instruction)
            // TODO: delayed enable (IME set after the following instruction)
            0xFB => {
                self.ime = true;
            },

            // CPL — complement A (1M)
            0x2F => {
                self.a = ~self.a;
                self.f = (self.f & (flag_z | flag_c)) | flag_n | flag_h;
            },

            // SCF — set carry flag (1M)
            0x37 => {
                self.f = (self.f & flag_z) | flag_c;
            },

            // CCF — complement carry flag (1M)
            0x3F => {
                self.f = (self.f & flag_z) ^ flag_c;
            },

            // JP (HL) — jump to address in HL (1M)
            0xE9 => {
                self.pc = self.hl();
            },

            // LD SP, HL (2M)
            0xF9 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.sp = self.hl();
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // RETI — return from interrupt (4M)
            0xD9 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.z = bus.read(self.sp);
                    self.sp +%= 1;
                    self.m_cycle = 2;
                },
                2 => {
                    self.w = bus.read(self.sp);
                    self.sp +%= 1;
                    self.m_cycle = 3;
                },
                3 => {
                    self.pc = self.wz();
                    self.ime = true;
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // RET cc — conditional return (2M not taken, 5M taken)
            0xC0, 0xC8, 0xD0, 0xD8 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    // Internal: evaluate condition
                    if (self.condMet()) {
                        self.m_cycle = 2;
                    } else {
                        self.m_cycle = 0;
                    }
                },
                2 => {
                    self.z = bus.read(self.sp);
                    self.sp +%= 1;
                    self.m_cycle = 3;
                },
                3 => {
                    self.w = bus.read(self.sp);
                    self.sp +%= 1;
                    self.m_cycle = 4;
                },
                4 => {
                    self.pc = self.wz();
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // JP cc, a16 — conditional absolute jump (3M not taken, 4M taken)
            0xC2, 0xCA, 0xD2, 0xDA => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.z = bus.read(self.pc);
                    self.pc +%= 1;
                    self.m_cycle = 2;
                },
                2 => {
                    self.w = bus.read(self.pc);
                    self.pc +%= 1;
                    if (self.condMet()) {
                        self.m_cycle = 3;
                    } else {
                        self.m_cycle = 0;
                    }
                },
                3 => {
                    self.pc = self.wz();
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // CALL cc, a16 — conditional call (3M not taken, 6M taken)
            0xC4, 0xCC, 0xD4, 0xDC => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.z = bus.read(self.pc);
                    self.pc +%= 1;
                    self.m_cycle = 2;
                },
                2 => {
                    self.w = bus.read(self.pc);
                    self.pc +%= 1;
                    if (self.condMet()) {
                        self.m_cycle = 3;
                    } else {
                        self.m_cycle = 0;
                    }
                },
                3 => {
                    self.sp -%= 1;
                    self.m_cycle = 4;
                },
                4 => {
                    bus.write(self.sp, @intCast(self.pc >> 8));
                    self.sp -%= 1;
                    self.m_cycle = 5;
                },
                5 => {
                    bus.write(self.sp, @truncate(self.pc));
                    self.pc = self.wz();
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // RST n — restart (push PC, jump to fixed address) (4M)
            0xC7, 0xCF, 0xD7, 0xDF, 0xE7, 0xEF, 0xF7, 0xFF => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.sp -%= 1;
                    self.m_cycle = 2;
                },
                2 => {
                    bus.write(self.sp, @intCast(self.pc >> 8));
                    self.sp -%= 1;
                    self.m_cycle = 3;
                },
                3 => {
                    bus.write(self.sp, @truncate(self.pc));
                    self.pc = @as(u16, self.opcode & 0x38);
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // ADD SP, r8 — add signed immediate to SP (4M)
            0xE8 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.z = bus.read(self.pc);
                    self.pc +%= 1;
                    self.m_cycle = 2;
                },
                2 => {
                    // Internal: compute result
                    const offset: i8 = @bitCast(self.z);
                    const sp = self.sp;
                    const result = @as(u16, @bitCast(@as(i16, @bitCast(sp)) +% @as(i16, offset)));

                    self.f = 0;
                    if ((sp & 0xF) + (self.z & 0xF) > 0xF) self.f |= flag_h;
                    if ((sp & 0xFF) +% @as(u16, self.z) > 0xFF) self.f |= flag_c;
                    _ = result;
                    self.m_cycle = 3;
                },
                3 => {
                    const offset: i8 = @bitCast(self.z);
                    self.sp = @bitCast(@as(i16, @bitCast(self.sp)) +% @as(i16, offset));
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // LD HL, SP+r8 — load SP + signed immediate into HL (3M)
            0xF8 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.z = bus.read(self.pc);
                    self.pc +%= 1;
                    self.m_cycle = 2;
                },
                2 => {
                    const offset: i8 = @bitCast(self.z);
                    const sp = self.sp;
                    const result = @as(u16, @bitCast(@as(i16, @bitCast(sp)) +% @as(i16, offset)));

                    self.f = 0;
                    if ((sp & 0xF) + (self.z & 0xF) > 0xF) self.f |= flag_h;
                    if ((sp & 0xFF) +% @as(u16, self.z) > 0xFF) self.f |= flag_c;

                    self.h = @intCast(result >> 8);
                    self.l = @intCast(result & 0xFF);
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // RLCA / RRCA / RLA / RRA — rotate A (1M, Z always cleared)
            0x07 => { // RLCA
                const bit7 = self.a >> 7;
                self.a = (self.a << 1) | bit7;
                self.f = if (bit7 != 0) flag_c else @as(u8, 0);
            },
            0x0F => { // RRCA
                const bit0 = self.a & 1;
                self.a = (self.a >> 1) | (bit0 << 7);
                self.f = if (bit0 != 0) flag_c else @as(u8, 0);
            },
            0x17 => { // RLA
                const old_carry: u8 = if (self.f & flag_c != 0) 1 else 0;
                const new_carry = self.a & 0x80;
                self.a = (self.a << 1) | old_carry;
                self.f = if (new_carry != 0) flag_c else @as(u8, 0);
            },
            0x1F => { // RRA
                const old_carry: u8 = if (self.f & flag_c != 0) 0x80 else 0;
                const new_carry = self.a & 1;
                self.a = (self.a >> 1) | old_carry;
                self.f = if (new_carry != 0) flag_c else @as(u8, 0);
            },

            // DAA — decimal adjust A for BCD (1M)
            0x27 => {
                var adjust: u8 = 0;
                var carry = false;

                if (self.f & flag_h != 0 or (self.f & flag_n == 0 and self.a & 0x0F > 9)) {
                    adjust |= 0x06;
                }
                if (self.f & flag_c != 0 or (self.f & flag_n == 0 and self.a > 0x99)) {
                    adjust |= 0x60;
                    carry = true;
                }

                if (self.f & flag_n != 0) {
                    self.a -%= adjust;
                } else {
                    self.a +%= adjust;
                }

                self.f = (self.f & flag_n) | (if (carry) flag_c else @as(u8, 0));
                if (self.a == 0) self.f |= flag_z;
            },

            // ADD HL, rr — 16-bit addition (2M)
            0x09, 0x19, 0x29, 0x39 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    const pair: u2 = @truncate(self.opcode >> 4);
                    const hl_val: u32 = self.hl();
                    const rr_val: u32 = self.getReg16(pair);
                    const result = hl_val + rr_val;

                    self.f = self.f & flag_z; // preserve Z
                    if ((hl_val & 0xFFF) + (rr_val & 0xFFF) > 0xFFF) self.f |= flag_h;
                    if (result > 0xFFFF) self.f |= flag_c;

                    const r16: u16 = @truncate(result);
                    self.h = @intCast(r16 >> 8);
                    self.l = @intCast(r16 & 0xFF);
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // JR r8 — unconditional relative jump (3M)
            0x18 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.z = bus.read(self.pc);
                    self.pc +%= 1;
                    self.m_cycle = 2;
                },
                2 => {
                    // Internal cycle: apply signed offset
                    const offset: i8 = @bitCast(self.z);
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // JR cc, r8 — conditional relative jump (2M not taken, 3M taken)
            0x20, 0x28, 0x30, 0x38 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.z = bus.read(self.pc);
                    self.pc +%= 1;
                    if (self.condMet()) {
                        self.m_cycle = 2; // branch taken: internal cycle
                    } else {
                        self.m_cycle = 0; // not taken: done
                    }
                },
                2 => {
                    const offset: i8 = @bitCast(self.z);
                    self.pc = @bitCast(@as(i16, @bitCast(self.pc)) +% offset);
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // JP a16 — unconditional absolute jump (4M)
            0xC3 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.z = bus.read(self.pc);
                    self.pc +%= 1;
                    self.m_cycle = 2;
                },
                2 => {
                    self.w = bus.read(self.pc);
                    self.pc +%= 1;
                    self.m_cycle = 3;
                },
                3 => {
                    self.pc = self.wz();
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // CALL a16 — call subroutine (6M)
            0xCD => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.z = bus.read(self.pc);
                    self.pc +%= 1;
                    self.m_cycle = 2;
                },
                2 => {
                    self.w = bus.read(self.pc);
                    self.pc +%= 1;
                    self.m_cycle = 3;
                },
                3 => {
                    // Internal: prepare to push return address
                    self.sp -%= 1;
                    self.m_cycle = 4;
                },
                4 => {
                    bus.write(self.sp, @intCast(self.pc >> 8));
                    self.sp -%= 1;
                    self.m_cycle = 5;
                },
                5 => {
                    bus.write(self.sp, @truncate(self.pc));
                    self.pc = self.wz();
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // RET — return from subroutine (4M)
            0xC9 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.z = bus.read(self.sp);
                    self.sp +%= 1;
                    self.m_cycle = 2;
                },
                2 => {
                    self.w = bus.read(self.sp);
                    self.sp +%= 1;
                    self.m_cycle = 3;
                },
                3 => {
                    self.pc = self.wz();
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // PUSH rr — push register pair to stack (4M)
            0xC5, 0xD5, 0xE5, 0xF5 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    // Internal cycle
                    self.sp -%= 1;
                    self.m_cycle = 2;
                },
                2 => {
                    const pair = self.pushPopPair();
                    bus.write(self.sp, @intCast(pair >> 8));
                    self.sp -%= 1;
                    self.m_cycle = 3;
                },
                3 => {
                    const pair = self.pushPopPair();
                    bus.write(self.sp, @truncate(pair));
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // POP rr — pop register pair from stack (3M)
            0xC1, 0xD1, 0xE1, 0xF1 => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    self.z = bus.read(self.sp);
                    self.sp +%= 1;
                    self.m_cycle = 2;
                },
                2 => {
                    self.w = bus.read(self.sp);
                    self.sp +%= 1;
                    self.setPushPopPair(self.wz());
                    self.m_cycle = 0;
                },
                else => unreachable,
            },

            // CB prefix — two-byte instructions (2M+ depending on operand)
            0xCB => switch (self.m_cycle) {
                0 => {
                    self.m_cycle = 1;
                },
                1 => {
                    const cb_op = bus.read(self.pc);
                    self.pc +%= 1;
                    self.executeCB(cb_op);
                },
                else => unreachable,
            },

            else => {
                self.halted = true;
            },
        }
    }

    // -- Helpers --------------------------------------------------------

    fn aluOp(self: *SM83, op: u3, operand: u8) void {
        switch (op) {
            0 => self.addA(operand, false),
            1 => self.addA(operand, true),
            2 => self.subA(operand, false, true),
            3 => self.subA(operand, true, true),
            4 => { // AND
                self.a &= operand;
                self.f = flag_h | (if (self.a == 0) flag_z else @as(u8, 0));
            },
            5 => { // XOR
                self.a ^= operand;
                self.f = if (self.a == 0) flag_z else 0;
            },
            6 => { // OR
                self.a |= operand;
                self.f = if (self.a == 0) flag_z else 0;
            },
            7 => self.subA(operand, false, false), // CP (flags only)
        }
    }

    fn addA(self: *SM83, operand: u8, with_carry: bool) void {
        const carry: u16 = if (with_carry and self.f & flag_c != 0) 1 else 0;
        const a: u16 = self.a;
        const b: u16 = operand;
        const result = a + b + carry;
        const half = (a & 0xF) + (b & 0xF) + carry;

        self.f = 0;
        if (@as(u8, @truncate(result)) == 0) self.f |= flag_z;
        if (half > 0xF) self.f |= flag_h;
        if (result > 0xFF) self.f |= flag_c;
        self.a = @truncate(result);
    }

    fn subA(self: *SM83, operand: u8, with_carry: bool, store: bool) void {
        const carry: u16 = if (with_carry and self.f & flag_c != 0) 1 else 0;
        const a: u16 = self.a;
        const b: u16 = operand;
        const result = a -% b -% carry;
        const half = (a & 0xF) -% (b & 0xF) -% carry;

        self.f = flag_n;
        if (@as(u8, @truncate(result)) == 0) self.f |= flag_z;
        if (half & 0x10 != 0) self.f |= flag_h;
        if (result & 0x100 != 0) self.f |= flag_c;
        if (store) self.a = @truncate(result);
    }

    /// Check if the condition encoded in bits 4-3 of the opcode is met.
    fn condMet(self: *const SM83) bool {
        return switch (@as(u2, @truncate(self.opcode >> 3))) {
            0 => self.f & flag_z == 0, // NZ
            1 => self.f & flag_z != 0, // Z
            2 => self.f & flag_c == 0, // NC
            3 => self.f & flag_c != 0, // C
        };
    }

    /// Get the 16-bit value of the register pair for PUSH/POP.
    /// PUSH/POP use AF instead of SP for pair index 3.
    fn pushPopPair(self: *const SM83) u16 {
        return switch (@as(u2, @truncate(self.opcode >> 4))) {
            0 => (@as(u16, self.b) << 8) | self.c,
            1 => (@as(u16, self.d) << 8) | self.e,
            2 => (@as(u16, self.h) << 8) | self.l,
            3 => (@as(u16, self.a) << 8) | self.f,
        };
    }

    fn setPushPopPair(self: *SM83, value: u16) void {
        const high: u8 = @intCast(value >> 8);
        const low: u8 = @truncate(value);
        switch (@as(u2, @truncate(self.opcode >> 4))) {
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
                self.a = high;
                self.f = low & 0xF0; // lower 4 bits of F always 0
            },
        }
    }

    /// Execute a CB-prefixed instruction. Called during M-cycle 1.
    fn executeCB(self: *SM83, cb_op: u8) void {
        const reg: u3 = @truncate(cb_op);
        const bit: u3 = @truncate(cb_op >> 3);

        if (reg == 6) {
            // (HL) operand — would need more M-cycles.
            // TODO: implement CB (HL) operations
            self.halted = true;
            return;
        }

        const val = self.getReg8(reg);

        switch (@as(u2, @truncate(cb_op >> 6))) {
            0 => {
                // Rotate/shift operations (0x00-0x3F)
                const op: u3 = @truncate(cb_op >> 3);
                const result = switch (op) {
                    0 => rlc: { // RLC
                        self.f = if (val & 0x80 != 0) flag_c else @as(u8, 0);
                        break :rlc (val << 1) | (val >> 7);
                    },
                    1 => rrc: { // RRC
                        self.f = if (val & 1 != 0) flag_c else @as(u8, 0);
                        break :rrc (val >> 1) | (val << 7);
                    },
                    2 => rl: { // RL
                        const carry: u8 = if (self.f & flag_c != 0) 1 else 0;
                        self.f = if (val & 0x80 != 0) flag_c else @as(u8, 0);
                        break :rl (val << 1) | carry;
                    },
                    3 => rr: { // RR
                        const carry: u8 = if (self.f & flag_c != 0) 0x80 else 0;
                        self.f = if (val & 1 != 0) flag_c else @as(u8, 0);
                        break :rr (val >> 1) | carry;
                    },
                    4 => sla: { // SLA
                        self.f = if (val & 0x80 != 0) flag_c else @as(u8, 0);
                        break :sla val << 1;
                    },
                    5 => sra: { // SRA (arithmetic — bit 7 preserved)
                        self.f = if (val & 1 != 0) flag_c else @as(u8, 0);
                        break :sra (val >> 1) | (val & 0x80);
                    },
                    6 => swap: { // SWAP
                        self.f = 0;
                        break :swap (val >> 4) | (val << 4);
                    },
                    7 => srl: { // SRL
                        self.f = if (val & 1 != 0) flag_c else @as(u8, 0);
                        break :srl val >> 1;
                    },
                };
                if (result == 0) self.f |= flag_z;
                self.setReg8(reg, result);
                self.m_cycle = 0;
            },
            1 => {
                // BIT b, r (0x40-0x7F)
                self.f = (self.f & flag_c) | flag_h;
                if (val & (@as(u8, 1) << bit) == 0) self.f |= flag_z;
                self.m_cycle = 0;
            },
            2 => {
                // RES b, r (0x80-0xBF)
                self.setReg8(reg, val & ~(@as(u8, 1) << bit));
                self.m_cycle = 0;
            },
            3 => {
                // SET b, r (0xC0-0xFF)
                self.setReg8(reg, val | (@as(u8, 1) << bit));
                self.m_cycle = 0;
            },
        }
    }

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

test "XOR A clears A and sets zero flag" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0xAF; // XOR A
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.a = 0x42;

    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0), cpu.a);
    try std.testing.expect(cpu.f & SM83.flag_z != 0);
    try std.testing.expect(cpu.f & SM83.flag_n == 0);
    try std.testing.expect(cpu.f & SM83.flag_h == 0);
    try std.testing.expect(cpu.f & SM83.flag_c == 0);
}

test "INC C sets half-carry on nibble overflow" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x0C; // INC C
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.c = 0x0F;

    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0x10), cpu.c);
    try std.testing.expect(cpu.f & SM83.flag_h != 0);
    try std.testing.expect(cpu.f & SM83.flag_n == 0);
}

test "DEC B sets half-carry on nibble borrow" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x05; // DEC B
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.b = 0x10;

    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0x0F), cpu.b);
    try std.testing.expect(cpu.f & SM83.flag_h != 0);
    try std.testing.expect(cpu.f & SM83.flag_n != 0);
}

test "DEC B to zero sets zero flag" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x05; // DEC B
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.b = 0x01;

    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0), cpu.b);
    try std.testing.expect(cpu.f & SM83.flag_z != 0);
}

test "INC/DEC preserves carry flag" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x0C; // INC C
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.f = SM83.flag_c; // carry set before INC

    cpu.tick(&bus);
    try std.testing.expect(cpu.f & SM83.flag_c != 0); // carry preserved
}

test "CP d8 sets flags without modifying A" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0xFE; // CP $42
    ram[1] = 0x42;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.a = 0x42;

    cpu.tick(&bus);
    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0x42), cpu.a); // unchanged
    try std.testing.expect(cpu.f & SM83.flag_z != 0); // equal
    try std.testing.expect(cpu.f & SM83.flag_n != 0); // subtraction
}

test "INC HL is 2M and no flags" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x23; // INC HL
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.h = 0x80;
    cpu.l = 0xFF;
    cpu.f = 0;

    cpu.tick(&bus);
    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0x81), cpu.h);
    try std.testing.expectEqual(@as(u8, 0x00), cpu.l);
    try std.testing.expectEqual(@as(u8, 0), cpu.f); // no flags changed
}

test "RLA rotates through carry" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x17; // RLA
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.a = 0x80; // bit 7 set
    cpu.f = 0; // carry clear

    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0x00), cpu.a); // 0x80 << 1, no carry in
    try std.testing.expect(cpu.f & SM83.flag_c != 0); // old bit 7 → carry
    try std.testing.expect(cpu.f & SM83.flag_z == 0); // RLA never sets Z
}

test "RLA carries in old carry" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x17; // RLA
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.a = 0x00;
    cpu.f = SM83.flag_c; // carry set

    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0x01), cpu.a); // carry rotated into bit 0
    try std.testing.expect(cpu.f & SM83.flag_c == 0); // old bit 7 was 0
}

test "AND d8 sets half-carry flag" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0xE6; // AND $0F
    ram[1] = 0x0F;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.a = 0xF0;

    cpu.tick(&bus);
    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0x00), cpu.a);
    try std.testing.expect(cpu.f & SM83.flag_z != 0);
    try std.testing.expect(cpu.f & SM83.flag_h != 0); // AND always sets H
}

test "JR NZ takes branch when Z clear" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x20; // JR NZ, -3 (0xFD = -3)
    ram[1] = 0xFD;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.f = 0; // Z clear

    cpu.tick(&bus); // fetch
    cpu.tick(&bus); // read offset, branch taken
    cpu.tick(&bus); // internal: apply offset
    // PC was 2 after reading offset, -3 = 0xFFFF
    try std.testing.expectEqual(@as(u16, 0xFFFF), cpu.pc);
    try std.testing.expectEqual(@as(u3, 0), cpu.m_cycle);
}

test "JR NZ skips branch when Z set" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0x20; // JR NZ, -3
    ram[1] = 0xFD;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.f = SM83.flag_z; // Z set

    cpu.tick(&bus); // fetch
    cpu.tick(&bus); // read offset, not taken
    try std.testing.expectEqual(@as(u16, 2), cpu.pc); // just advances past
    try std.testing.expectEqual(@as(u3, 0), cpu.m_cycle);
}

test "CALL pushes return address and jumps" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0xCD; // CALL $0095
    ram[1] = 0x95;
    ram[2] = 0x00;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.sp = 0xFFFE;

    for (0..6) |_| cpu.tick(&bus);
    try std.testing.expectEqual(@as(u16, 0x0095), cpu.pc);
    try std.testing.expectEqual(@as(u16, 0xFFFC), cpu.sp);
    // Return address (0x0003) pushed: high then low
    try std.testing.expectEqual(@as(u8, 0x00), ram[0xFFFD]);
    try std.testing.expectEqual(@as(u8, 0x03), ram[0xFFFC]);
}

test "RET pops return address" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0xC9; // RET
    ram[0xFFFC] = 0x03; // return address low
    ram[0xFFFD] = 0x00; // return address high
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.sp = 0xFFFC;

    for (0..4) |_| cpu.tick(&bus);
    try std.testing.expectEqual(@as(u16, 0x0003), cpu.pc);
    try std.testing.expectEqual(@as(u16, 0xFFFE), cpu.sp);
}

test "PUSH BC and POP BC round-trip" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0xC5; // PUSH BC
    ram[1] = 0xC1; // POP BC
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.sp = 0xFFFE;
    cpu.b = 0x12;
    cpu.c = 0x34;

    // PUSH BC: 4 M-cycles
    for (0..4) |_| cpu.tick(&bus);
    try std.testing.expectEqual(@as(u16, 0xFFFC), cpu.sp);

    // Clear BC
    cpu.b = 0;
    cpu.c = 0;

    // POP BC: 3 M-cycles
    for (0..3) |_| cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0x12), cpu.b);
    try std.testing.expectEqual(@as(u8, 0x34), cpu.c);
    try std.testing.expectEqual(@as(u16, 0xFFFE), cpu.sp);
}

test "POP AF masks lower 4 bits of F" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0xF1; // POP AF
    ram[0xFFFC] = 0xFF; // F value with low bits set
    ram[0xFFFD] = 0x42; // A value
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.sp = 0xFFFC;

    for (0..3) |_| cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0x42), cpu.a);
    try std.testing.expectEqual(@as(u8, 0xF0), cpu.f); // lower 4 bits cleared
}

test "BIT 7, H sets Z when bit clear" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0xCB; // CB prefix
    ram[1] = 0x7C; // BIT 7, H
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.h = 0x00; // bit 7 clear
    cpu.f = SM83.flag_c; // carry set before

    cpu.tick(&bus); // fetch CB
    cpu.tick(&bus); // fetch 0x7C, execute
    try std.testing.expect(cpu.f & SM83.flag_z != 0);
    try std.testing.expect(cpu.f & SM83.flag_h != 0);
    try std.testing.expect(cpu.f & SM83.flag_n == 0);
    try std.testing.expect(cpu.f & SM83.flag_c != 0); // preserved
}

test "BIT 7, H clears Z when bit set" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0xCB;
    ram[1] = 0x7C;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.h = 0x80; // bit 7 set

    cpu.tick(&bus);
    cpu.tick(&bus);
    try std.testing.expect(cpu.f & SM83.flag_z == 0);
}

test "RL C rotates through carry" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0xCB;
    ram[1] = 0x11; // RL C
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};
    cpu.c = 0x80;
    cpu.f = 0; // carry clear

    cpu.tick(&bus);
    cpu.tick(&bus);
    try std.testing.expectEqual(@as(u8, 0x00), cpu.c);
    try std.testing.expect(cpu.f & SM83.flag_c != 0); // old bit 7
    try std.testing.expect(cpu.f & SM83.flag_z != 0); // result is 0
}

test "JP a16 jumps to absolute address" {
    var ram = [_]u8{0x00} ** 0x10000;
    ram[0] = 0xC3; // JP $0100
    ram[1] = 0x00;
    ram[2] = 0x01;
    var bus = TestBus{ .ram = &ram };
    var cpu = SM83{};

    for (0..4) |_| cpu.tick(&bus);
    try std.testing.expectEqual(@as(u16, 0x0100), cpu.pc);
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
