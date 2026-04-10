const std = @import("std");

/// Minimal PPU stub — just enough to provide LY and mode timing.
/// No actual rendering yet.
pub const PPU = struct {
    dot: u16 = 0, // T-cycle within current scanline (0-455)
    ly: u8 = 0, // current scanline (0-153)

    const dots_per_line: u16 = 456;
    const lines_per_frame: u8 = 154;
    const vblank_start: u8 = 144;

    /// Advance the PPU by one T-cycle.
    pub fn tick(self: *PPU) void {
        self.dot += 1;
        if (self.dot >= dots_per_line) {
            self.dot = 0;
            self.ly +%= 1;
            if (self.ly >= lines_per_frame) {
                self.ly = 0;
            }
        }
    }

    /// Read the STAT register (FF41). Stub: returns mode only.
    pub fn readStat(self: *const PPU) u8 {
        return self.mode();
    }

    /// Current PPU mode based on dot position and scanline.
    pub fn mode(self: *const PPU) u8 {
        if (self.ly >= vblank_start) return 1; // VBLANK
        if (self.dot < 80) return 2; // OAM scan
        if (self.dot < 252) return 3; // pixel transfer (approximate)
        return 0; // HBLANK
    }
};

// -- Tests -----------------------------------------------------------

test "LY increments every 456 T-cycles" {
    var ppu = PPU{};
    for (0..456) |_| ppu.tick();
    try std.testing.expectEqual(@as(u8, 1), ppu.ly);
}

test "LY wraps at 154" {
    var ppu = PPU{};
    for (0..456 * 154) |_| ppu.tick();
    try std.testing.expectEqual(@as(u8, 0), ppu.ly);
}

test "LY reaches VBLANK at 144" {
    var ppu = PPU{};
    for (0..456 * 144) |_| ppu.tick();
    try std.testing.expectEqual(@as(u8, 144), ppu.ly);
    try std.testing.expectEqual(@as(u8, 1), ppu.mode());
}

test "mode transitions within a visible scanline" {
    var ppu = PPU{};

    // Start of line: OAM scan (mode 2)
    try std.testing.expectEqual(@as(u8, 2), ppu.mode());

    // After 80 dots: pixel transfer (mode 3)
    for (0..80) |_| ppu.tick();
    try std.testing.expectEqual(@as(u8, 3), ppu.mode());

    // After ~252 dots: HBLANK (mode 0)
    for (0..172) |_| ppu.tick();
    try std.testing.expectEqual(@as(u8, 0), ppu.mode());
}
