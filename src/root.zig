pub const GameBoy = @import("gameboy.zig").GameBoy;
pub const SM83 = @import("sm83.zig").SM83;
pub const Timer = @import("timer.zig").Timer;
pub const PPU = @import("ppu.zig").PPU;

test {
    _ = @import("gameboy.zig");
    _ = @import("sm83.zig");
    _ = @import("timer.zig");
    _ = @import("ppu.zig");
}
