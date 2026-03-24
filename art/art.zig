const std = @import("std");
const net = std.net;

pub fn main() !void {
    const path = "/tmp/ledaw_ocr.sock";
    const stream = retry: {
        for (0..50) |_| {
            break :retry net.connectUnixSocket(path) catch {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            };
        }
        return error.OcrConnectionTimeout;
    };
    defer stream.close();

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
