const std = @import("std");
const SpscQueue = @import("queue.zig").SpscQueue;
const project = @import("project.zig");

pub const PlaybackOp = union(enum) {
    toggle_play,
    reset,
};

pub const RecordOp = union(enum) {
    toggle_record: usize, // track index to record to
};

pub const GraphOp = union(enum) {
    add_track: *project.Track,
    remove_track: usize,
    add_plugin: struct { track_idx: usize, plugin: project.Plugin },
};

pub const Op = union(enum) {
    playback: PlaybackOp,
    record: RecordOp,
    graph: GraphOp,
};

pub const GarbageItem = union(enum) {
    plugin: project.Plugin,
    track: *project.Track,
};

pub const OpQueue = SpscQueue(Op, 32);
pub const GarbageQueue = SpscQueue(GarbageItem, 32);

pub const Action = union(enum) {
    op: Op,
    go_back,
};

pub const ActionList = struct {
    buffer: [2]Action = undefined,
    len: usize = 0,

    pub fn fromSlice(items: []const Action) error{Overflow}!ActionList {
        if (items.len > 2) return error.Overflow;
        var self = ActionList{};
        for (items) |item| {
            self.buffer[self.len] = item;
            self.len += 1;
        }
        return self;
    }

    pub fn appendAssumeCapacity(self: *ActionList, item: Action) void {
        std.debug.assert(self.len < 2);
        self.buffer[self.len] = item;
        self.len += 1;
    }

    pub fn constSlice(self: *const ActionList) []const Action {
        return self.buffer[0..self.len];
    }
};
