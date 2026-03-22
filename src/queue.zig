const std = @import("std");

const Message = struct {
    id: u32,
    data: f32,
};

pub fn BoundedList(comptime T: type, comptime N: usize) type {
    return struct {
        const Self = @This();
        buffer: [N]T = undefined,
        len: usize = 0,

        pub fn fromSlice(items: []const T) Self {
            std.debug.assert(items.len <= N);
            var self = Self{};
            @memcpy(self.buffer[0..items.len], items);
            self.len = items.len;
            return self;
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            std.debug.assert(self.len < N);
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn constSlice(self: *const Self) []const T {
            return self.buffer[0..self.len];
        }
    };
}

pub fn SpscQueue(comptime T: type, comptime N: usize) type {
    return struct {
        const Self = @This();
        const CAPACITY = N + 1;
        write_idx: std.atomic.Value(usize) = .init(0),
        read_idx: std.atomic.Value(usize) = .init(0),
        buf: [CAPACITY]T = undefined,

        pub fn push(self: *Self, value: T) bool {
            const w = self.write_idx.load(.monotonic);
            const r = self.read_idx.load(.acquire);

            if ((w + 1) % CAPACITY == r) return false; // full

            self.buf[w] = value;
            self.write_idx.store((w + 1) % CAPACITY, .release);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            const r = self.read_idx.load(.monotonic);
            const w = self.write_idx.load(.acquire);

            if (r == w) return null; // empty

            const val = self.buf[r];
            self.read_idx.store((r + 1) % CAPACITY, .release);
            return val;
        }
    };
}
