const std = @import("std");
const dmg = @import("dmg");

pub fn main() void {
    var gb = dmg.GameBoy{};

    // Run for 2048 T-cycles = 512 M-cycles = 512 NOPs
    for (0..2048) |_| {
        gb.tick();
    }

    // Expected: PC = 0x0200 (512), DIV = 0x08 (2048 / 256)
    std.debug.print("T-cycles: {d}\n", .{gb.t_cycle});
    std.debug.print("CPU PC:   0x{x:0>4}\n", .{gb.cpu.pc});
    std.debug.print("DIV:      0x{x:0>2}\n", .{gb.timer.readDiv()});
}
