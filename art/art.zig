const std = @import("std");
const rl = @import("raylib");
const ledaw = @import("main");
const c = ledaw.c;

const net = std.net;
const interface = ledaw.interface;
const project = ledaw.project;
const midi = ledaw.midi;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

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
        A,
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

    // ledaw
    ledaw.g_app = try project.App.init(A, &ledaw.g_playhead, &ledaw.context);
    ledaw.g_app.timeline.addTrack(try project.Track.init(A, &ledaw.g_app.timeline.active_track, &.{}));
    defer ledaw.g_app.deinit();
    ledaw.root = ledaw.g_app.timeline.asNode();
    defer ledaw.g_record_buffer.deinit(A);

    const audio_thread = try std.Thread.spawn(.{}, ledaw.audioThreadMain, .{});
    defer {
        ledaw.g_run_audio.store(false, .release);
        if (ledaw.g_sio_ptr.load(.acquire)) |p| c.soundio_wakeup(p);
        audio_thread.join();
    }

    try interface.init();
    defer interface.deinit();

    while (!rl.windowShouldClose()) {
        const n = try stream.read(buf[leftover..]);
        if (n == 0) break; // disconnected
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
            std.debug.print("{s}\n", .{line});
        }
    }
}
