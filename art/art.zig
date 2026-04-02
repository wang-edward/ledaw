const std = @import("std");
const rl = @import("raylib");
const ledaw = @import("main");
const c = ledaw.c;

const net = std.net;
const interface = ledaw.interface;
const project = ledaw.project;
const midi = ledaw.midi;

var line_buf: [2][4096]u8 = undefined;
var line_len: [2]usize = .{ 0, 0 };
var line_idx: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

fn readerThreadMain() !void {
    // setup socket and ocr process
    const path = "/tmp/ledaw_ocr.sock";
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const addr = try net.Address.initUnix(path);
    var server = try addr.listen(.{});
    defer server.deinit();

    var child = std.process.Child.init(
        &.{ "uv", "run", "--project", "art", "art/ocr.py" },
        ledaw.A,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    defer _ = child.wait() catch {};

    const conn = try server.accept();
    defer conn.stream.close();
    const stream = conn.stream;

    var buf: [4096]u8 = undefined;
    var leftover: usize = 0;

    while (true) {
        const n = try stream.read(buf[leftover..]);
        if (n == 0) @panic("disconnected");
        const total = leftover + n;

        var last_line: ?[]const u8 = null;
        var start: usize = 0;
        for (0..total) |i| {
            if (buf[i] == '\n') {
                last_line = buf[start..i];
                start = i + 1;
            }
        }

        // Shift leftover to front
        if (start < total) {
            std.mem.copyForwards(u8, &buf, buf[start..total]);
            leftover = total - start;
        } else {
            leftover = 0;
        }

        if (last_line) |line| {
            const curr_idx = line_idx.load(.acquire);
            const next_idx = curr_idx ^ 1;
            @memcpy(line_buf[next_idx][0..line.len], line);
            line_len[next_idx] = line.len;
            line_idx.store(next_idx, .release);
        }
    }
}

// -- pixel data --

const GRID_SIZE = 32;

const FrameData = struct {
    px: []const u8, // hex string
    w: i64,
    h: i64,
};

var pixels: [GRID_SIZE * GRID_SIZE]u8 = .{0} ** (GRID_SIZE * GRID_SIZE);
var pixels_valid: bool = false;

fn hexVal(ch: u8) ?u4 {
    if (ch >= '0' and ch <= '9') return @intCast(ch - '0');
    if (ch >= 'a' and ch <= 'f') return @intCast(ch - 'a' + 10);
    return null;
}

fn parsePixels(json_str: []const u8) void {
    const parsed = std.json.parseFromSlice(FrameData, ledaw.A, json_str, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const hex = parsed.value.px;

    if (hex.len != GRID_SIZE * GRID_SIZE * 2) return;

    for (0..GRID_SIZE * GRID_SIZE) |i| {
        const hi = hexVal(hex[2 * i]) orelse return;
        const lo = hexVal(hex[2 * i + 1]) orelse return;
        pixels[i] = (@as(u8, hi) << 4) | lo;
    }
    pixels_valid = true;
}

fn renderPixelGrid() void {
    if (!pixels_valid) return;

    const scale = interface.WIDTH / GRID_SIZE; // 128/32 = 4
    for (0..GRID_SIZE) |py| {
        for (0..GRID_SIZE) |px| {
            const val = pixels[py * GRID_SIZE + px];
            const color = rl.Color{ .r = val, .g = val, .b = val, .a = 255 };
            const x: i32 = @intCast(px * scale);
            const y: i32 = @intCast(py * scale);
            rl.drawRectangle(x, y, scale, scale, color);
        }
    }
}

// -- song generation --

fn sendEvent(ev: interface.Event) void {
    const actions = ledaw.g_app.handleEvent(ev);
    for (actions.constSlice()) |ac| {
        switch (ac) {
            .op => |o| while (!ledaw.g_op_queue.push(o)) {},
            else => {},
        }
    }
}

fn pushOp(op: ledaw.ops.Op) void {
    while (!ledaw.g_op_queue.push(op)) {}
}

fn pixelsToSong() void {
    if (!pixels_valid) return;

    const rand = std.crypto.random;
    const tempo: f32 = 120;
    const SR = ledaw.SAMPLE_RATE;

    // reset
    pushOp(.{ .graph = .clear_timeline });
    pushOp(.{ .playback = .reset });

    // enter insert mode + start recording
    ledaw.g_app.mode = .insert;
    pushOp(.{ .record = .{ .set_record = true } });

    var playhead_pos: u64 = 0;

    // track which poll_key indices are held
    var held = std.StaticBitSet(interface.poll_keys.len).initEmpty();

    for (&pixels) |val| {
        const key_idx = val % interface.poll_keys.len;
        const key = interface.poll_keys[key_idx];

        if (held.isSet(key_idx)) {
            sendEvent(.{ .type = .key_release, .key = key });
            held.unset(key_idx);
        } else {
            sendEvent(.{ .type = .key_press, .key = key });
            held.set(key_idx);
        }

        // advance playhead by random duration (0.01 to 0.1 beats)
        const duration = 0.01 + @as(f32, @floatFromInt(rand.intRangeAtMost(u32, 0, 9))) * 0.01;
        // std.debug.print("skip forward {} beats", .{duration});
        const frames = midi.beatsToFrames(duration, tempo, SR);
        playhead_pos += frames;
        pushOp(.{ .playback = .{ .set_playhead = playhead_pos } });
    }

    // release all held keys
    for (0..interface.poll_keys.len) |i| {
        if (held.isSet(i)) {
            sendEvent(.{ .type = .key_release, .key = interface.poll_keys[i] });
        }
    }

    // stop recording
    pushOp(.{ .record = .{ .set_record = false } });
    ledaw.g_app.mode = .normal;
}

// -- main --

pub fn main() !void {
    var read_thread = try std.Thread.spawn(.{}, readerThreadMain, .{});
    defer read_thread.join();

    ledaw.g_app = try project.App.init(ledaw.A, &ledaw.g_playhead, &ledaw.g_recording, &ledaw.context);
    ledaw.g_app.timeline.addTrack(try project.Track.init(ledaw.A, &ledaw.g_app.timeline.active_track, &.{}));
    defer ledaw.g_app.deinit();
    ledaw.root = ledaw.g_app.timeline.asNode();
    defer ledaw.g_record_buffer.deinit(ledaw.A);

    const audio_thread = try std.Thread.spawn(.{}, ledaw.audioThreadMain, .{});
    defer {
        ledaw.g_run_audio.store(false, .release);
        if (ledaw.g_sio_ptr.load(.acquire)) |p| c.soundio_wakeup(p);
        audio_thread.join();
    }

    try interface.initDual();
    defer interface.deinit();

    while (!rl.windowShouldClose()) {
        const idx = line_idx.load(.acquire);
        const len = line_len[idx];

        // parse incoming pixel data
        if (len > 0) {
            parsePixels(line_buf[idx][0..len]);
        }

        if (rl.isKeyPressed(.b)) {
            ledaw.g_app.note_offset = 0;
            pixelsToSong();
        }
        if (rl.isKeyPressed(.a)) {
            ledaw.g_app.timeline.screen = .overview;
            pushOp(.{ .playback = .reset });
            pushOp(.{ .playback = .{ .set_play = true } });
        }
        if (rl.isKeyPressed(.c)) {
            ledaw.g_app.timeline.print();
        }

        // render DAW to left texture
        interface.preRender();
        ledaw.g_app.render();

        // render camera feed to right texture
        interface.preRenderOcr();
        renderPixelGrid();

        // draw both to screen
        interface.postRender();

        // drain garbage from audio thread
        while (ledaw.g_garbage_queue.pop()) |item| {
            switch (item) {
                .plugin => |p| p.deinit(ledaw.A),
                .track => |t| {
                    t.deinit(ledaw.A);
                    ledaw.A.destroy(t);
                },
            }
        }
    }
}
