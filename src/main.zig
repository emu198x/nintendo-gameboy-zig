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

    const AudioStream = opaque {};

    const AudioSpec = extern struct {
        format: u32,
        channels: c_int,
        freq: c_int,
    };

    const INIT_AUDIO: u32 = 0x00000010;
    const INIT_VIDEO: u32 = 0x00000020;
    const AUDIO_F32: u32 = 0x8120;
    const AUDIO_DEVICE_DEFAULT_PLAYBACK: u32 = 0xFFFFFFFF;
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
    extern "SDL3" fn SDL_GetKeyboardState(numkeys: ?*c_int) [*]const bool;
    extern "SDL3" fn SDL_GetTicksNS() u64;
    extern "SDL3" fn SDL_DelayNS(ns: u64) void;
    extern "SDL3" fn SDL_OpenAudioDeviceStream(devid: u32, spec: *const AudioSpec, callback: ?*const anyopaque, userdata: ?*anyopaque) ?*AudioStream;
    extern "SDL3" fn SDL_PutAudioStreamData(stream: *AudioStream, buf: [*]const u8, len: c_int) bool;
    extern "SDL3" fn SDL_ResumeAudioStreamDevice(stream: *AudioStream) bool;
    extern "SDL3" fn SDL_GetAudioStreamQueued(stream: *AudioStream) c_int;

    // Scancodes (USB HID standard, used by SDL)
    const SCANCODE_RIGHT: usize = 79;
    const SCANCODE_LEFT: usize = 80;
    const SCANCODE_DOWN: usize = 81;
    const SCANCODE_UP: usize = 82;
    const SCANCODE_Z: usize = 29;
    const SCANCODE_X: usize = 27;
    const SCANCODE_RETURN: usize = 40;
    const SCANCODE_BACKSPACE: usize = 42;
};

// -- Palette -----------------------------------------------------------

const shades = [4]u32{
    0xFFFFFFFF, // white
    0xFFAAAAAA, // light grey
    0xFF555555, // dark grey
    0xFF000000, // black
};

fn shadeToARGB(shade: u2) u32 {
    return shades[shade];
}

// -- Main --------------------------------------------------------------

pub fn main() void {
    var gba = std.heap.DebugAllocator(.{}){};
    defer _ = gba.deinit();
    const allocator = gba.allocator();

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

            const cart_size = cart_file.getEndPos() catch |err| {
                std.debug.print("Could not stat cartridge: {}\n", .{err});
                return;
            };
            const cart_data = allocator.alloc(u8, cart_size) catch |err| {
                std.debug.print("Could not allocate cartridge buffer: {}\n", .{err});
                return;
            };
            // Note: we intentionally don't free cart_data — it lives for the
            // whole program and GameBoy holds a slice into it.
            const cart_n = cart_file.readAll(cart_data) catch |err| {
                std.debug.print("Could not read cartridge: {}\n", .{err});
                return;
            };
            gb.loadCartridge(cart_data[0..cart_n]);
            std.debug.print("Loaded {d} byte cartridge\n", .{cart_n});
        }
    } else {
        std.debug.print("Usage: dmg <boot.bin> [cartridge.gb]\n", .{});
        return;
    }

    // Init SDL3
    if (!sdl.SDL_Init(sdl.INIT_VIDEO | sdl.INIT_AUDIO)) {
        std.debug.print("SDL init failed: {s}\n", .{sdl.SDL_GetError()});
        return;
    }
    defer sdl.SDL_Quit();

    // Open audio stream: stereo f32 @ 48kHz
    const audio_spec = sdl.AudioSpec{
        .format = sdl.AUDIO_F32,
        .channels = 2,
        .freq = @intCast(dmg.APU.sample_rate),
    };
    const audio_stream = sdl.SDL_OpenAudioDeviceStream(
        sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK,
        &audio_spec,
        null,
        null,
    ) orelse {
        std.debug.print("Audio stream failed: {s}\n", .{sdl.SDL_GetError()});
        return;
    };
    _ = sdl.SDL_ResumeAudioStreamDevice(audio_stream);

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
    // Frame pacing: 70224 T-cycles / 4.194304 MHz ≈ 16.7427 ms
    const frame_ns: u64 = 16_742_706;
    var next_frame_time: u64 = sdl.SDL_GetTicksNS();

    var frame_count: u32 = 0;
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
                pixels[y * 160 + x] = shadeToARGB(gb.ppu.framebuffer[y][x]);
            }
        }

        frame_count += 1;

        // Dump framebuffer at frames 600 and 1500 for test debugging
        if (frame_count == 600 or frame_count == 1500) {
            var name_buf: [32]u8 = undefined;
            const fname = std.fmt.bufPrint(&name_buf, "frame_{d}.ppm", .{frame_count}) catch "debug.ppm";
            const ppm_file = std.fs.cwd().createFile(fname, .{}) catch break;
            defer ppm_file.close();
            ppm_file.writeAll("P6\n160 144\n255\n") catch {};
            for (0..144) |y| {
                for (0..160) |x| {
                    const argb = pixels[y * 160 + x];
                    const rgb = [3]u8{
                        @truncate(argb >> 16),
                        @truncate(argb >> 8),
                        @truncate(argb),
                    };
                    ppm_file.writeAll(&rgb) catch {};
                }
            }
            std.debug.print("Dumped {s}\n", .{fname});
        }

        // Dump diagnostics
        if (false) {
            std.debug.print("Frame {d}: LCDC=0x{x:0>2} BGP=0x{x:0>2} SCY={d} SCX={d} IE=0x{x:0>2} IF=0x{x:0>2} IME={} PC=0x{x:0>4}\n", .{
                frame_count,
                gb.ppu.lcdc,     gb.ppu.bgp, gb.ppu.scy, gb.ppu.scx,
                gb.interrupt_enable, gb.interrupt_flag, gb.cpu.ime, gb.cpu.pc,
            });
            // Dump tile map row 0 (first 32 entries)
            std.debug.print("TileMap[0..32]: ", .{});
            for (0..32) |i| {
                std.debug.print("{x:0>2} ", .{gb.ram[0x9800 + i]});
            }
            std.debug.print("\n", .{});

            // Count non-white pixels
            var nonwhite: u32 = 0;
            for (0..144) |y| {
                for (0..160) |x| {
                    if (gb.ppu.framebuffer[y][x] != 0) nonwhite += 1;
                }
            }
            std.debug.print("Non-white pixels: {d}/23040\n", .{nonwhite});

            // Write PPM
            var fname_buf: [32]u8 = undefined;
            const fname = std.fmt.bufPrint(&fname_buf, "frame{d}.ppm", .{frame_count}) catch "frame.ppm";
            const ppm_file = std.fs.cwd().createFile(fname, .{}) catch |err| {
                std.debug.print("Could not create PPM: {}\n", .{err});
                break;
            };
            defer ppm_file.close();
            ppm_file.writeAll("P6\n160 144\n255\n") catch {};
            for (0..144) |y| {
                for (0..160) |x| {
                    const argb = pixels[y * 160 + x];
                    const rgb = [3]u8{
                        @truncate(argb >> 16),
                        @truncate(argb >> 8),
                        @truncate(argb),
                    };
                    ppm_file.writeAll(&rgb) catch {};
                }
            }
            std.debug.print("Wrote {s}\n", .{fname});
        }

        // Upload and present
        _ = sdl.SDL_UpdateTexture(texture, null, @ptrCast(&pixels), 160 * 4);
        _ = sdl.SDL_RenderClear(renderer);
        _ = sdl.SDL_RenderTexture(renderer, texture, null, null);
        _ = sdl.SDL_RenderPresent(renderer);

        // Drain APU samples into the audio stream
        var audio_buf: [2048]f32 = undefined;
        const n_samples = gb.apu.drainSamples(&audio_buf);
        if (n_samples > 0) {
            _ = sdl.SDL_PutAudioStreamData(audio_stream, @ptrCast(&audio_buf), @intCast(n_samples * @sizeOf(f32)));
        }

        // Handle events
        var event: sdl.Event = .{ .type = 0 };
        while (sdl.SDL_PollEvent(&event)) {
            if (event.type == sdl.EVENT_QUIT) {
                running = false;
            }
        }

        // Poll keyboard and update joypad state
        const keys = sdl.SDL_GetKeyboardState(null);
        var buttons: u8 = 0;
        if (keys[sdl.SCANCODE_RIGHT]) buttons |= 0x01;
        if (keys[sdl.SCANCODE_LEFT]) buttons |= 0x02;
        if (keys[sdl.SCANCODE_UP]) buttons |= 0x04;
        if (keys[sdl.SCANCODE_DOWN]) buttons |= 0x08;
        if (keys[sdl.SCANCODE_X]) buttons |= 0x10; // A
        if (keys[sdl.SCANCODE_Z]) buttons |= 0x20; // B
        if (keys[sdl.SCANCODE_BACKSPACE]) buttons |= 0x40; // Select
        if (keys[sdl.SCANCODE_RETURN]) buttons |= 0x80; // Start

        // Joypad interrupt on any button transitioning from not-pressed to pressed
        if ((buttons & ~gb.buttons) != 0) {
            gb.interrupt_flag |= 0x10;
        }
        gb.buttons = buttons;

        // Frame pacing: sleep until the next frame should start
        next_frame_time += frame_ns;
        const now = sdl.SDL_GetTicksNS();
        if (next_frame_time > now) {
            sdl.SDL_DelayNS(next_frame_time - now);
        } else {
            // Running behind: don't try to catch up
            next_frame_time = now;
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
