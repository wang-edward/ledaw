const SpscQueue = @import("queue.zig").SpscQueue;

pub const PlaybackOp = union(enum) {
    TogglePlay,
    Reset,
};

pub const RecordOp = union(enum) {
    ToggleRecord: usize, // track index to record to
};

pub const Op = union(enum) {
    Playback: PlaybackOp,
    Record: RecordOp,
};

pub const OpQueue = SpscQueue(Op, 32);
