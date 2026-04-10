const std = @import("std");

/// Pixel FIFO — circular buffer holding up to 16 two-bit pixels.
const Fifo = struct {
    data: [16]u2 = [_]u2{0} ** 16,
    head: u8 = 0,
    len: u8 = 0,

    fn push8(self: *Fifo, pixels: [8]u2) void {
        for (pixels) |p| {
            self.data[(self.head +% self.len) & 0xF] = p;
            self.len += 1;
        }
    }

    fn pop(self: *Fifo) u2 {
        const p = self.data[self.head & 0xF];
        self.head +%= 1;
        self.len -= 1;
        return p;
    }

    fn clear(self: *Fifo) void {
        self.head = 0;
        self.len = 0;
    }
};

/// BG tile fetcher — 4 states, 2 dots each. Reads tile data from VRAM
/// and pushes 8 pixels to the FIFO per cycle.
const Fetcher = struct {
    state: State = .read_tile_id,
    ticks: u1 = 0,
    tile_id: u8 = 0,
    tile_data_low: u8 = 0,
    tile_data_high: u8 = 0,
    x: u8 = 0, // tile column counter

    const State = enum {
        read_tile_id,
        read_tile_data_low,
        read_tile_data_high,
        push,
    };

    fn reset(self: *Fetcher) void {
        self.state = .read_tile_id;
        self.ticks = 0;
        self.x = 0;
    }

    fn tick(self: *Fetcher, ppu: *PPU, vram: []const u8) void {
        self.ticks +%= 1;
        if (self.ticks != 0) return; // first dot of pair, wait

        switch (self.state) {
            .read_tile_id => {
                const y: u16 = ppu.ly +% ppu.scy;
                const x: u16 = @as(u16, self.x) * 8 +% ppu.scx;
                const map_base: u16 = if (ppu.lcdc & 0x08 != 0) 0x1C00 else 0x1800;
                const map_addr = map_base + (y / 8 % 32) * 32 + (x / 8 % 32);
                self.tile_id = vram[map_addr];
                self.state = .read_tile_data_low;
            },
            .read_tile_data_low => {
                self.tile_data_low = vram[self.tileDataAddr(ppu)];
                self.state = .read_tile_data_high;
            },
            .read_tile_data_high => {
                self.tile_data_high = vram[self.tileDataAddr(ppu) + 1];
                self.state = .push;
            },
            .push => {
                if (ppu.fifo.len <= 8) {
                    ppu.fifo.push8(self.decodePixels());
                    self.x +%= 1;
                    self.state = .read_tile_id;
                }
                // FIFO full: stall, retry next 2-dot cycle
            },
        }
    }

    fn tileDataAddr(self: *const Fetcher, ppu: *const PPU) u16 {
        const row: u16 = (@as(u16, ppu.ly) +% ppu.scy) % 8;
        if (ppu.lcdc & 0x10 != 0) {
            // Unsigned: base 0x0000 (= 0x8000 in absolute), tile_id 0-255
            return @as(u16, self.tile_id) * 16 + row * 2;
        } else {
            // Signed: base 0x1000 (= 0x9000 in absolute), tile_id is signed
            const signed_id: i16 = @as(i8, @bitCast(self.tile_id));
            return @intCast(@as(i16, 0x1000) + signed_id * 16 + @as(i16, @intCast(row)) * 2);
        }
    }

    fn decodePixels(self: *const Fetcher) [8]u2 {
        var pixels: [8]u2 = undefined;
        for (0..8) |i| {
            const bit: u3 = @intCast(7 - i);
            const low: u1 = @truncate(self.tile_data_low >> bit);
            const high: u1 = @truncate(self.tile_data_high >> bit);
            pixels[i] = (@as(u2, high) << 1) | low;
        }
        return pixels;
    }
};

/// Game Boy PPU with pixel FIFO rendering.
pub const PPU = struct {
    // Timing
    dot: u16 = 0,
    ly: u8 = 0,

    // LCD output
    lcd_x: u8 = 0,
    discard_pixels: u8 = 0,

    // Pixel pipeline
    fifo: Fifo = .{},
    fetcher: Fetcher = .{},

    // Registers
    lcdc: u8 = 0x91, // power-on default: LCD on, BG tile data unsigned, BG enabled
    stat: u8 = 0,
    scy: u8 = 0,
    scx: u8 = 0,
    lyc: u8 = 0,
    bgp: u8 = 0xFC,

    // Output
    framebuffer: [144][160]u2 = [_][160]u2{[_]u2{0} ** 160} ** 144,
    frame_ready: bool = false,

    const dots_per_line: u16 = 456;
    const lines_per_frame: u8 = 154;
    const vblank_start: u8 = 144;
    const oam_end: u16 = 80;

    /// Advance the PPU by one T-cycle.
    pub fn tick(self: *PPU, vram: []const u8) void {
        if (self.lcdc & 0x80 == 0) return; // LCD off: timing frozen

        if (self.ly >= vblank_start) {
            // Mode 1: VBLANK
            if (self.ly == vblank_start and self.dot == 0) {
                self.frame_ready = true;
            }
        } else if (self.dot < oam_end) {
            // Mode 2: OAM scan — no-op for now (no sprites)
        } else {
            if (self.dot == oam_end) {
                // Entering mode 3: reset pixel pipeline
                self.fetcher.reset();
                self.fifo.clear();
                self.lcd_x = 0;
                self.discard_pixels = self.scx & 7;
            }

            if (self.lcd_x < 160) {
                // Mode 3: pixel transfer
                self.fetcher.tick(self, vram);

                if (self.fifo.len > 0) {
                    const pixel = self.fifo.pop();
                    if (self.discard_pixels > 0) {
                        self.discard_pixels -= 1;
                    } else {
                        self.framebuffer[self.ly][self.lcd_x] = pixel;
                        self.lcd_x += 1;
                    }
                }
            }
            // else: Mode 0 (HBLANK) — idle
        }

        // Advance timing (always when LCD is on)
        self.dot += 1;
        if (self.dot >= dots_per_line) {
            self.dot = 0;
            self.ly +%= 1;
            if (self.ly >= lines_per_frame) {
                self.ly = 0;
            }
        }
    }

    /// Current PPU mode.
    pub fn mode(self: *const PPU) u8 {
        if (self.ly >= vblank_start) return 1;
        if (self.dot < oam_end) return 2;
        if (self.lcd_x < 160) return 3;
        return 0;
    }

    /// Read STAT register (FF41).
    pub fn readStat(self: *const PPU) u8 {
        var s = self.stat & 0x78; // preserve writable bits 3-6
        s |= self.mode();
        if (self.ly == self.lyc) s |= 0x04; // LYC coincidence flag
        return s;
    }
};

// -- Tests -----------------------------------------------------------

test "FIFO push and pop" {
    var fifo = Fifo{};
    fifo.push8(.{ 3, 2, 1, 0, 3, 2, 1, 0 });
    try std.testing.expectEqual(@as(u8, 8), fifo.len);
    try std.testing.expectEqual(@as(u2, 3), fifo.pop());
    try std.testing.expectEqual(@as(u2, 2), fifo.pop());
    try std.testing.expectEqual(@as(u8, 6), fifo.len);
}

test "fetcher decodes tile data into pixels" {
    var fetcher = Fetcher{};
    fetcher.tile_data_low = 0b10101010;
    fetcher.tile_data_high = 0b11001100;
    const pixels = fetcher.decodePixels();
    // Bit 7: high=1, low=1 -> 3
    // Bit 6: high=1, low=0 -> 2
    // Bit 5: high=0, low=1 -> 1
    // Bit 4: high=0, low=0 -> 0
    // Bit 3: high=1, low=1 -> 3
    // Bit 2: high=1, low=0 -> 2
    // Bit 1: high=0, low=1 -> 1
    // Bit 0: high=0, low=0 -> 0
    try std.testing.expectEqual(@as(u2, 3), pixels[0]);
    try std.testing.expectEqual(@as(u2, 2), pixels[1]);
    try std.testing.expectEqual(@as(u2, 1), pixels[2]);
    try std.testing.expectEqual(@as(u2, 0), pixels[3]);
    try std.testing.expectEqual(@as(u2, 3), pixels[4]);
    try std.testing.expectEqual(@as(u2, 2), pixels[5]);
    try std.testing.expectEqual(@as(u2, 1), pixels[6]);
    try std.testing.expectEqual(@as(u2, 0), pixels[7]);
}

test "LY increments every 456 T-cycles" {
    var vram = [_]u8{0} ** 0x2000;
    var ppu = PPU{};
    for (0..456) |_| ppu.tick(&vram);
    try std.testing.expectEqual(@as(u8, 1), ppu.ly);
}

test "LY wraps at 154" {
    var vram = [_]u8{0} ** 0x2000;
    var ppu = PPU{};
    for (0..456 * 154) |_| ppu.tick(&vram);
    try std.testing.expectEqual(@as(u8, 0), ppu.ly);
}

test "frame_ready set at start of VBLANK" {
    var vram = [_]u8{0} ** 0x2000;
    var ppu = PPU{};
    // 456*144 dots bring us to ly=144, dot=0. One more tick to enter VBLANK.
    for (0..456 * 144 + 1) |_| ppu.tick(&vram);
    try std.testing.expect(ppu.frame_ready);
    try std.testing.expectEqual(@as(u8, 144), ppu.ly);
}

test "mode transitions within a visible scanline" {
    var vram = [_]u8{0} ** 0x2000;
    var ppu = PPU{};

    // Mode 2 at start
    try std.testing.expectEqual(@as(u8, 2), ppu.mode());

    // Mode 3 after OAM scan
    for (0..80) |_| ppu.tick(&vram);
    try std.testing.expectEqual(@as(u8, 3), ppu.mode());
}

test "pixels appear in framebuffer" {
    var vram = [_]u8{0} ** 0x2000;
    // Set up a tile at ID 0 with a simple pattern
    // Tile data at 0x0000 (unsigned addressing, LCDC bit 4 set)
    // Row 0: low=0xFF, high=0x00 -> all pixels = 01
    vram[0] = 0xFF; // tile 0, row 0, low byte
    vram[1] = 0x00; // tile 0, row 0, high byte
    // Tile map at 0x1800: all zeros (tile ID 0)

    var ppu = PPU{};
    ppu.lcdc = 0x91; // LCD on, unsigned tile data, BG enabled
    ppu.scx = 0;
    ppu.scy = 0;

    // Run one full scanline (456 dots)
    for (0..456) |_| ppu.tick(&vram);

    // Check that pixels were written to the framebuffer
    // All pixels should be 1 (low=1, high=0)
    try std.testing.expectEqual(@as(u2, 1), ppu.framebuffer[0][0]);
    try std.testing.expectEqual(@as(u2, 1), ppu.framebuffer[0][79]);
    try std.testing.expectEqual(@as(u2, 1), ppu.framebuffer[0][159]);
}
