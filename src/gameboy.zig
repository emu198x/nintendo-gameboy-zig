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
    interrupt_flag: u8 = 0, // IF (FF0F)
    interrupt_enable: u8 = 0, // IE (FFFF)

    /// Buttons pressed, 1 = pressed:
    /// bit 0: Right, 1: Left, 2: Up, 3: Down
    /// bit 4: A, 5: B, 6: Select, 7: Start
    buttons: u8 = 0,
    /// JOYP select bits from last write (bits 4-5).
    joypad_select: u8 = 0x30,

    t_cycle: u64 = 0,
    cpu_divider: u2 = 0,

    /// Advance the system by one T-cycle.
    /// Timer ticks every T-cycle. CPU ticks every 4th (M-cycle).
    pub fn tick(self: *GameBoy) void {
        self.timer.tick();

        const was_vblank = self.ppu.ly >= 144;
        self.ppu.tick(self.ram[0x8000..0xA000], self.ram[0xFE00..0xFEA0]);
        const now_vblank = self.ppu.ly >= 144;

        // Set VBLANK interrupt flag on transition into VBLANK
        if (!was_vblank and now_vblank) {
            self.interrupt_flag |= 0x01;
        }

        if (self.cpu_divider == 0) {
            self.cpu.tick(self);
        }
        self.cpu_divider +%= 1;

        self.t_cycle += 1;
    }

    pub fn readJoypad(self: *const GameBoy) u8 {
        var lines: u8 = 0x0F;
        if (self.joypad_select & 0x10 == 0) {
            // D-pad selected: clear bits for pressed D-pad buttons
            lines &= ~(self.buttons & 0x0F);
        }
        if (self.joypad_select & 0x20 == 0) {
            // Face buttons selected: clear bits for pressed face buttons
            lines &= ~((self.buttons >> 4) & 0x0F);
        }
        return 0xC0 | self.joypad_select | lines;
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
            0xFF00 => self.readJoypad(),
            0xFF0F => self.interrupt_flag,
            0xFF47 => self.ppu.bgp,
            0xFF48 => self.ppu.obp0,
            0xFF49 => self.ppu.obp1,
            0xFF4A => self.ppu.wy,
            0xFF4B => self.ppu.wx,
            0xFFFF => self.interrupt_enable,
            else => self.ram[addr],
        };
    }

    pub fn write(self: *GameBoy, addr: u16, value: u8) void {
        // Writes to cartridge ROM (0x0000-0x7FFF) are no-ops for ROM-only
        // cartridges. MBC chips use writes here for bank switching (TODO).
        if (addr < 0x8000) return;

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
                // LCD disable: reset PPU timing
                if (self.ppu.lcdc & 0x80 != 0 and value & 0x80 == 0) {
                    self.ppu.ly = 0;
                    self.ppu.dot = 0;
                }
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
            0xFF48 => {
                self.ppu.obp0 = value;
            },
            0xFF49 => {
                self.ppu.obp1 = value;
            },
            0xFF4A => {
                self.ppu.wy = value;
            },
            0xFF4B => {
                self.ppu.wx = value;
            },
            0xFF46 => {
                // OAM DMA: copy 0xA0 bytes from source to FE00-FE9F
                const source: u16 = @as(u16, value) << 8;
                var i: u16 = 0;
                while (i < 0xA0) : (i += 1) {
                    self.ram[0xFE00 + i] = self.ram[source + i];
                }
            },
            0xFF00 => {
                self.joypad_select = value & 0x30;
            },
            0xFF0F => {
                self.interrupt_flag = value;
            },
            0xFF50 => {
                if (value != 0) self.boot_rom_active = false;
            },
            0xFFFF => {
                self.interrupt_enable = value;
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
