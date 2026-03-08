const SpscQueue = @import("queue.zig").SpscQueue;
const project = @import("project.zig");

pub const PlaybackOp = union(enum) {
    TogglePlay,
    Reset,
};

pub const RecordOp = union(enum) {
    ToggleRecord: usize, // track index to record to
};

pub const GraphOp = union(enum) {
    AddTrack: *project.Track,
    RemoveTrack: usize,
    AddPlugin: struct { track_idx: usize, plugin: project.Plugin },
    RemovePluginByTag: struct { track_idx: usize, tag: project.PluginTag },
};

pub const Op = union(enum) {
    Playback: PlaybackOp,
    Record: RecordOp,
    Graph: GraphOp,
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
