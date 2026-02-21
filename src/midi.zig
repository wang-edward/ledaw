const std = @import("std");
const audio = @import("audio.zig");
const SpscQueue = @import("queue.zig").SpscQueue;

pub const Frame = u64;
pub const MAX_NOTES_PER_BLOCK = 1024; // big on purpose

pub const Note = struct {
    start: Frame,
    end: Frame,
    note: u8,
};

pub const NoteMsg = union(enum) {
    On: u8,
    Off: u8,
};

pub const NoteQueue = SpscQueue(NoteMsg, 16);

pub fn beatsToFrames(beats: f32, tempo: f32, ctx: *audio.Context) Frame {
    return @intFromFloat((60.0 / tempo) * ctx.sample_rate * beats);
}

pub const Player = struct {
    notes: std.ArrayListUnmanaged(Note) = .{},

    pub fn init(alloc: std.mem.Allocator, notes_in: []const Note) !Player {
        var notes: std.ArrayListUnmanaged(Note) = .{};
        try notes.appendSlice(alloc, notes_in);
        return .{ .notes = notes };
    }

    pub fn deinit(self: *Player, alloc: std.mem.Allocator) void {
        self.notes.deinit(alloc);
    }

    pub fn clear(self: *Player) void {
        self.notes.clearRetainingCapacity();
    }

    pub fn appendNotes(self: *Player, alloc: std.mem.Allocator, new_notes: []const Note) !void {
        try self.notes.appendSlice(alloc, new_notes);
    }

    pub fn advance(self: *Player, start: Frame, end: Frame, out: []NoteMsg) usize {
        // std.debug.print("start: {}, end: {}", .{ start, end });
        // std.debug.print("notes: {any}", .{self.notes});
        std.debug.assert(end >= start);
        std.debug.assert(end - start < 8192);

        var count: usize = 0;

        for (self.notes.items) |n| {
            // TODO check what happens when advance() is called on the latter boundary wrt <, <=
            // so what if pre_accum == n.start... is this even a problem?
            //
            // TODO better array that doesn't need manual counting?
            if (start <= n.start and n.start < end) {
                if (count < out.len) {
                    std.debug.print("on: {}\n", .{n});
                    out[count] = .{ .On = n.note };
                    count += 1;
                }
            }
            if (start <= n.end and n.end < end) {
                if (count < out.len) {
                    std.debug.print("on: {}\n", .{n});
                    std.debug.print("off: {}\n", .{n});
                    out[count] = .{ .Off = n.note };
                    count += 1;
                }
            }
        }
        return count;
    }
};
