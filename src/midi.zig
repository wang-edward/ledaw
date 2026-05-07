const std = @import("std");
const audio = @import("audio.zig");
const rl = @import("raylib");
const SpscQueue = @import("queue.zig").SpscQueue;

pub const Frame = u64;
pub const MAX_NOTES_PER_BLOCK = 1024; // big on purpose

pub const Note = struct {
    start: Frame,
    end: Frame,
    note: u8,
};

pub const NoteMsg = union(enum) {
    on: u8,
    off: u8,
};

pub const NoteQueue = SpscQueue(NoteMsg, 16);

pub fn beatsToFrames(beats: f32, tempo: f32, sample_rate: f32) Frame {
    return @intFromFloat((60.0 / tempo) * sample_rate * beats);
}

pub fn framesToBeats(frames: Frame, tempo: f32, sample_rate: f32) f32 {
    return @as(f32, @floatFromInt(frames)) / (sample_rate * 60.0 / tempo);
}

pub fn keyToMidi(key: rl.KeyboardKey) ?u8 {
    return switch (key) {
        // --- white keys (A–L) ---
        .a => 48, // C3
        .s => 50, // D3
        .d => 52, // E3
        .f => 53, // F3
        .g => 55, // G3
        .h => 57, // A3
        .j => 59, // B3
        .k => 60, // C4
        .l => 62, // D4
        .semicolon => 64, // E4
        .apostrophe => 65, // F4

        // --- black keys (W–O) ---
        .w => 49, // C#3
        .e => 51, // D#3
        .t => 54, // F#3
        .y => 56, // G#3
        .u => 58, // A#3
        .o => 61, // C#4
        .p => 63, // D#4
        else => null,
    };
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
                    out[count] = .{ .on = n.note };
                    count += 1;
                }
            }
            if (start <= n.end and n.end < end) {
                if (count < out.len) {
                    std.debug.print("on: {}\n", .{n});
                    std.debug.print("off: {}\n", .{n});
                    out[count] = .{ .off = n.note };
                    count += 1;
                }
            }
        }
        return count;
    }
};
