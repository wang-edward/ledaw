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
    set_active_track: usize,
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

const BoundedList = @import("queue.zig").BoundedList;
pub const ActionList = BoundedList(Action, 2);
