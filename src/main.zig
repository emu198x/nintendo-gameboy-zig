const std = @import("std");
const dmg = @import("dmg");

pub fn main() void {
    var gb = dmg.GameBoy{};

    // Parse arguments
    var args = std.process.args();
    _ = args.next(); // skip program name
    const boot_rom_path = args.next();

    if (boot_rom_path) |path| {
        const boot_file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.debug.print("Could not open boot ROM '{s}': {}\n", .{ path, err });
            return;
        };
        defer boot_file.close();

        var boot_data: [256]u8 = undefined;
        const n = boot_file.readAll(&boot_data) catch |err| {
            std.debug.print("Could not read boot ROM: {}\n", .{err});
            return;
        };
        if (n != 256) {
            std.debug.print("Boot ROM is {d} bytes, expected 256\n", .{n});
            return;
        }
        gb.loadBootRom(&boot_data);
        std.debug.print("Boot ROM loaded from {s}\n", .{path});

        // Load cartridge if provided
        if (args.next()) |cart_path| {
            const cart_file = std.fs.cwd().openFile(cart_path, .{}) catch |err| {
                std.debug.print("Could not open cartridge '{s}': {}\n", .{ cart_path, err });
                return;
            };
            defer cart_file.close();

            var cart_data: [0x8000]u8 = undefined;
            const cart_n = cart_file.readAll(&cart_data) catch |err| {
                std.debug.print("Could not read cartridge: {}\n", .{err});
                return;
            };
            gb.loadCartridge(cart_data[0..cart_n]);
            std.debug.print("Cartridge loaded: {d} bytes\n", .{cart_n});
        }
    } else {
        std.debug.print("Usage: dmg <boot.bin> [cartridge.gb]\n", .{});
        std.debug.print("\nRunning without boot ROM (NOP test)...\n", .{});
    }

    // Run until halted or cycle limit
    const max_cycles: u64 = 4_000_000; // ~1 second of Game Boy time
    while (!gb.cpu.halted and gb.t_cycle < max_cycles) {
        gb.tick();
    }

    // Print final state
    std.debug.print("\n--- CPU State ---\n", .{});
    std.debug.print("T-cycles: {d}\n", .{gb.t_cycle});
    std.debug.print("PC:  0x{x:0>4}\n", .{gb.cpu.pc});
    std.debug.print("SP:  0x{x:0>4}\n", .{gb.cpu.sp});
    std.debug.print("AF:  0x{x:0>2}{x:0>2}\n", .{ gb.cpu.a, gb.cpu.f });
    std.debug.print("BC:  0x{x:0>2}{x:0>2}\n", .{ gb.cpu.b, gb.cpu.c });
    std.debug.print("DE:  0x{x:0>2}{x:0>2}\n", .{ gb.cpu.d, gb.cpu.e });
    std.debug.print("HL:  0x{x:0>2}{x:0>2}\n", .{ gb.cpu.h, gb.cpu.l });

    if (gb.cpu.halted) {
        std.debug.print("HALTED at opcode 0x{x:0>2}\n", .{gb.cpu.opcode});
    } else {
        std.debug.print("Cycle limit reached\n", .{});
    }
}
