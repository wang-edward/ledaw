const std = @import("std");
const net = std.net;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const path = "/tmp/ledaw_ocr.sock";

    // Remove stale socket, create server, then spawn python so it can connect
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const addr = try net.Address.initUnix(path);
    var server = try addr.listen(.{});
    defer server.deinit();

    var child = std.process.Child.init(
        &.{ "uv", "run", "--project", "art", "art/ocr.py" },
        allocator,
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
        if (n == 0) break; // disconnected
        const total = leftover + n;

        // Process complete lines
        var start: usize = 0;
        for (0..total) |i| {
            if (buf[i] == '\n') {
                const line = buf[start..i];
                std.debug.print("got: {s}\n", .{line});
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
    }
}
