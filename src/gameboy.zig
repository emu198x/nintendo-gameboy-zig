const std = @import("std");
const SM83 = @import("sm83.zig").SM83;
const Timer = @import("timer.zig").Timer;
const PPU = @import("ppu.zig").PPU;

pub const GameBoy = struct {
    cpu: SM83 = .{},
    timer: Timer = .{},
    ppu: PPU = .{},
    ram: [0x10000]u8 = [_]u8{0} ** 0x10000,
    boot_rom: [256]u8 = [_]u8{0} ** 256,
    boot_rom_active: bool = false,

    t_cycle: u64 = 0,
    cpu_divider: u2 = 0,

    /// Advance the system by one T-cycle.
    /// Timer ticks every T-cycle. CPU ticks every 4th (M-cycle).
    pub fn tick(self: *GameBoy) void {
        self.timer.tick();
        self.ppu.tick(self.ram[0x8000..0xA000]);

        if (self.cpu_divider == 0) {
            self.cpu.tick(self);
        }
        self.cpu_divider +%= 1;

        self.t_cycle += 1;
    }

    pub fn loadBootRom(self: *GameBoy, data: []const u8) void {
        @memcpy(self.boot_rom[0..data.len], data);
        self.boot_rom_active = true;
    }

    pub fn loadCartridge(self: *GameBoy, data: []const u8) void {
        const len = @min(data.len, 0x8000);
        @memcpy(self.ram[0..len], data[0..len]);
    }

    // -- Bus interface --------------------------------------------------

    pub fn read(self: *const GameBoy, addr: u16) u8 {
        return switch (addr) {
            0x0000...0x00FF => if (self.boot_rom_active) self.boot_rom[addr] else self.ram[addr],
            0xFF04 => self.timer.readDiv(),
            0xFF05 => self.timer.tima,
            0xFF06 => self.timer.tma,
            0xFF07 => self.timer.readTac(),
            0xFF40 => self.ppu.lcdc,
            0xFF41 => self.ppu.readStat(),
            0xFF42 => self.ppu.scy,
            0xFF43 => self.ppu.scx,
            0xFF44 => self.ppu.ly,
            0xFF45 => self.ppu.lyc,
            0xFF47 => self.ppu.bgp,
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
            0xFF40 => {
                self.ppu.lcdc = value;
            },
            0xFF41 => {
                self.ppu.stat = value & 0x78; // only bits 3-6 writable
            },
            0xFF42 => {
                self.ppu.scy = value;
            },
            0xFF43 => {
                self.ppu.scx = value;
            },
            0xFF45 => {
                self.ppu.lyc = value;
            },
            0xFF47 => {
                self.ppu.bgp = value;
            },
            0xFF50 => {
                if (value != 0) self.boot_rom_active = false;
            },
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

test "boot ROM overlays first 256 bytes" {
    var gb = GameBoy{};
    gb.ram[0] = 0xAA; // cartridge data
    gb.boot_rom[0] = 0x31; // boot ROM data
    gb.boot_rom_active = true;

    try std.testing.expectEqual(@as(u8, 0x31), gb.read(0x0000)); // boot ROM
    try std.testing.expectEqual(gb.ram[0x100], gb.read(0x0100)); // cartridge (past boot ROM)
}

test "boot ROM disables on FF50 write" {
    var gb = GameBoy{};
    gb.ram[0] = 0xAA;
    gb.boot_rom[0] = 0x31;
    gb.boot_rom_active = true;

    gb.write(0xFF50, 0x01);
    try std.testing.expect(!gb.boot_rom_active);
    try std.testing.expectEqual(@as(u8, 0xAA), gb.read(0x0000)); // now reads cartridge
}

test "FF50 write of zero does not disable boot ROM" {
    var gb = GameBoy{};
    gb.boot_rom_active = true;

    gb.write(0xFF50, 0x00);
    try std.testing.expect(gb.boot_rom_active);
}

test "bus write to DIV resets timer" {
    var gb = GameBoy{};
    for (0..512) |_| gb.tick();

    gb.write(0xFF04, 0x00); // any value resets
    try std.testing.expectEqual(@as(u8, 0), gb.read(0xFF04));
}
