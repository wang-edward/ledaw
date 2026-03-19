const SpscQueue = @import("queue").SpscQueue;
const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}

test "basic push/pop" {
    var q: SpscQueue(u32, 4) = .{};

    try std.testing.expect(q.pop() == null); // empty

    try std.testing.expect(q.push(1));
    try std.testing.expect(q.push(2));
    try std.testing.expect(q.push(3));
    try std.testing.expect(q.push(4));

    try std.testing.expect(!q.push(5)); // full

    try std.testing.expectEqual(@as(?u32, 1), q.pop());
    try std.testing.expectEqual(@as(?u32, 2), q.pop());
    try std.testing.expectEqual(@as(?u32, 3), q.pop());
    try std.testing.expectEqual(@as(?u32, 4), q.pop());
    try std.testing.expect(q.pop() == null); // empty
}

test "wraparound correctness" {
    var q: SpscQueue(u32, 3) = .{};

    try std.testing.expect(q.push(10));
    try std.testing.expect(q.push(20));
    try std.testing.expectEqual(@as(?u32, 10), q.pop());
    try std.testing.expectEqual(@as(?u32, 20), q.pop());

    try std.testing.expect(q.push(30));
    try std.testing.expect(q.push(40)); // wraps to slot 0
    try std.testing.expect(q.push(50)); // slot 1
    try std.testing.expect(q.write_idx.load(.acquire) == 1);

    try std.testing.expect(!q.push(60)); // full

    try std.testing.expectEqual(@as(?u32, 30), q.pop());
    try std.testing.expectEqual(@as(?u32, 40), q.pop());
    try std.testing.expectEqual(@as(?u32, 50), q.pop());
    try std.testing.expect(q.pop() == null);
}

test "stress single-thread" {
    var q: SpscQueue(u32, 128) = .{};

    for (0..100_000) |i| {
        // fill
        while (q.push(@intCast(i)) == false) {}
        // empty
        try std.testing.expectEqual(@as(?u32, @intCast(i)), q.pop());
    }
}

fn runProducer(q: *SpscQueue(u32, 4), COUNT: usize) void {
    var i: u32 = 0;
    while (i < COUNT) : (i += 1) {
        while (!q.push(i)) {}
    }
}

fn runConsumer(q: *SpscQueue(u32, 4), COUNT: usize) void {
    var expected: u32 = 0;
    while (expected < COUNT) {
        if (q.pop()) |val| {
            if (val != expected) @panic("ORDER VIOLATION");
            expected += 1;
        }
    }
}

test "2-thread correctness" {
    const COUNT = 10_000_000;
    var q: SpscQueue(u32, 4) = .{};

    var producer = try std.Thread.spawn(.{}, runProducer, .{ &q, COUNT });
    var consumer = try std.Thread.spawn(.{}, runConsumer, .{ &q, COUNT });

    producer.join();
    consumer.join();
}

test "full/empty flip stress" {
    var q: SpscQueue(u8, 1) = .{}; // smallest possible queue

    for (0..100_000_000) |_| {
        try std.testing.expect(q.push(1));
        try std.testing.expect(q.pop() == 1);
    }
}
