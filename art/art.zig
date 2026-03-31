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

const OcrData = struct {
    boxes: []const [4]i64,
    frame_w: i64,
    frame_h: i64,
};

fn renderOcrBoxes(json_str: []const u8) void {
    const parsed = std.json.parseFromSlice(OcrData, ledaw.A, json_str, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const data = parsed.value;

    if (data.frame_w == 0 or data.frame_h == 0) return;

    const fw: f32 = @floatFromInt(data.frame_w);
    const fh: f32 = @floatFromInt(data.frame_h);
    const w: f32 = @floatFromInt(interface.WIDTH);
    const h: f32 = @floatFromInt(interface.HEIGHT);

    for (data.boxes) |box| {
        const x1: i32 = @intFromFloat(@as(f32, @floatFromInt(box[0])) * w / fw);
        const y1: i32 = @intFromFloat(@as(f32, @floatFromInt(box[1])) * h / fh);
        const x2: i32 = @intFromFloat(@as(f32, @floatFromInt(box[2])) * w / fw);
        const y2: i32 = @intFromFloat(@as(f32, @floatFromInt(box[3])) * h / fh);
        rl.drawRectangleLines(x1, y1, x2 - x1, y2 - y1, rl.Color.green);
    }
}

pub fn main() !void {
    var read_thread = try std.Thread.spawn(.{}, readerThreadMain, .{});
    defer read_thread.join();

    // ledaw
    ledaw.g_app = try project.App.init(ledaw.A, &ledaw.g_playhead, &ledaw.context);
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

        if (rl.isKeyPressed(.a)) {
            std.debug.print("{s}", .{line_buf[idx]});
            ledaw.g_app.timeline.clear();
            for (line_buf[idx]) |ch| {
                const key = std.meta.intToEnum(rl.KeyboardKey, ch) catch continue;
                const ev = interface.Event{ .type = .key_press, .key = key };
                const actions = ledaw.g_app.handleEvent(ev);
                for (actions.constSlice()) |ac| {
                    switch (ac) {
                        .op => |o| while (!ledaw.g_op_queue.push(o)) {},
                        else => {},
                    }
                }
            }
        }
        if (rl.isKeyPressed(.b)) {
            while (!ledaw.g_op_queue.push(.{ .playback = .reset })) {}
            while (!ledaw.g_op_queue.push(.{ .playback = .toggle_play })) {}
        }

        // render DAW to left texture
        interface.preRender();
        ledaw.g_app.render();

        // render OCR boxes to right texture
        interface.preRenderOcr();
        if (len > 0) {
            renderOcrBoxes(line_buf[idx][0..len]);
        } else {
            std.debug.print("no line\n", .{});
        }

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
