const std = @import("std");
const dmg = @import("dmg");

// -- SDL3 bindings (manual, no C headers needed) -----------------------

const sdl = struct {
    const Window = opaque {};
    const Renderer = opaque {};
    const Texture = opaque {};

    const Event = extern struct {
        type: u32,
        _pad: [124]u8 = [_]u8{0} ** 124,
    };

    const INIT_VIDEO: u32 = 0x00000020;
    const EVENT_QUIT: u32 = 0x100;
    const PIXELFORMAT_ARGB8888: u32 = 0x16362004;
    const TEXTUREACCESS_STREAMING: c_int = 1;
    const SCALEMODE_NEAREST: c_int = 0;

    extern "SDL3" fn SDL_Init(flags: u32) bool;
    extern "SDL3" fn SDL_Quit() void;
    extern "SDL3" fn SDL_GetError() [*:0]const u8;
    extern "SDL3" fn SDL_CreateWindow(title: [*:0]const u8, w: c_int, h: c_int, flags: u64) ?*Window;
    extern "SDL3" fn SDL_DestroyWindow(window: *Window) void;
    extern "SDL3" fn SDL_CreateRenderer(window: *Window, name: ?[*:0]const u8) ?*Renderer;
    extern "SDL3" fn SDL_DestroyRenderer(renderer: *Renderer) void;
    extern "SDL3" fn SDL_CreateTexture(renderer: *Renderer, format: u32, access: c_int, w: c_int, h: c_int) ?*Texture;
    extern "SDL3" fn SDL_DestroyTexture(texture: *Texture) void;
    extern "SDL3" fn SDL_UpdateTexture(texture: *Texture, rect: ?*anyopaque, pixels: [*]const u8, pitch: c_int) bool;
    extern "SDL3" fn SDL_RenderClear(renderer: *Renderer) bool;
    extern "SDL3" fn SDL_RenderTexture(renderer: *Renderer, texture: *Texture, srcrect: ?*anyopaque, dstrect: ?*anyopaque) bool;
    extern "SDL3" fn SDL_RenderPresent(renderer: *Renderer) bool;
    extern "SDL3" fn SDL_PollEvent(event: *Event) bool;
    extern "SDL3" fn SDL_SetTextureScaleMode(texture: *Texture, mode: c_int) bool;
};

// -- Palette -----------------------------------------------------------

const shades = [4]u32{
    0xFFFFFFFF, // white
    0xFFAAAAAA, // light grey
    0xFF555555, // dark grey
    0xFF000000, // black
};

fn paletteToARGB(bgp: u8, index: u2) u32 {
    const shade: u2 = @truncate(bgp >> (@as(u3, index) * 2));
    return shades[shade];
}

// -- Main --------------------------------------------------------------

pub fn main() void {
    var gb = dmg.GameBoy{};

    // Parse arguments
    var args = std.process.args();
    _ = args.next();
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
        }
    } else {
        std.debug.print("Usage: dmg <boot.bin> [cartridge.gb]\n", .{});
        return;
    }

    // Init SDL3
    if (!sdl.SDL_Init(sdl.INIT_VIDEO)) {
        std.debug.print("SDL init failed: {s}\n", .{sdl.SDL_GetError()});
        return;
    }
    defer sdl.SDL_Quit();

    const scale = 4;
    const window = sdl.SDL_CreateWindow("DMG", 160 * scale, 144 * scale, 0) orelse {
        std.debug.print("Window failed: {s}\n", .{sdl.SDL_GetError()});
        return;
    };
    defer sdl.SDL_DestroyWindow(window);

    const renderer = sdl.SDL_CreateRenderer(window, null) orelse {
        std.debug.print("Renderer failed: {s}\n", .{sdl.SDL_GetError()});
        return;
    };
    defer sdl.SDL_DestroyRenderer(renderer);

    const texture = sdl.SDL_CreateTexture(
        renderer,
        sdl.PIXELFORMAT_ARGB8888,
        sdl.TEXTUREACCESS_STREAMING,
        160,
        144,
    ) orelse {
        std.debug.print("Texture failed: {s}\n", .{sdl.SDL_GetError()});
        return;
    };
    defer sdl.SDL_DestroyTexture(texture);

    _ = sdl.SDL_SetTextureScaleMode(texture, sdl.SCALEMODE_NEAREST);

    // Main loop
    var running = true;
    while (running) {
        // Run emulation until VBLANK
        gb.ppu.frame_ready = false;
        while (!gb.ppu.frame_ready) {
            gb.tick();
            if (gb.cpu.halted) break;
        }

        // Convert framebuffer to ARGB
        var pixels: [144 * 160]u32 = undefined;
        for (0..144) |y| {
            for (0..160) |x| {
                pixels[y * 160 + x] = paletteToARGB(gb.ppu.bgp, gb.ppu.framebuffer[y][x]);
            }
        }

        // Upload and present
        _ = sdl.SDL_UpdateTexture(texture, null, @ptrCast(&pixels), 160 * 4);
        _ = sdl.SDL_RenderClear(renderer);
        _ = sdl.SDL_RenderTexture(renderer, texture, null, null);
        _ = sdl.SDL_RenderPresent(renderer);

        // Handle events
        var event: sdl.Event = .{ .type = 0 };
        while (sdl.SDL_PollEvent(&event)) {
            if (event.type == sdl.EVENT_QUIT) {
                running = false;
            }
        }

        if (gb.cpu.halted) {
            std.debug.print("CPU halted at PC=0x{x:0>4} opcode=0x{x:0>2}\n", .{ gb.cpu.pc, gb.cpu.opcode });
            // Keep window open until closed
            while (running) {
                while (sdl.SDL_PollEvent(&event)) {
                    if (event.type == sdl.EVENT_QUIT) running = false;
                }
            }
        }
    }
}
