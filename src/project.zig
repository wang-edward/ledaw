const std = @import("std");
const uni = @import("uni.zig");
const midi = @import("midi.zig");
const audio = @import("audio.zig");
const interface = @import("interface.zig");
const rl = @import("raylib");

pub const Timeline = struct {
    pub const MAX_TRACKS = 8;

    alloc: std.mem.Allocator,
    tracks: [2][MAX_TRACKS]*Track,
    track_counts: [2]usize,
    active: std.atomic.Value(usize) = .init(0),
    vt: audio.VTable = .{ .process = _process },

    pub fn init(
        alloc: std.mem.Allocator,
        num_tracks: usize,
        voices_per_track: usize,
        notes_per_track: []const []const midi.Note,
    ) !Timeline {
        std.debug.assert(num_tracks <= MAX_TRACKS);
        std.debug.assert(notes_per_track.len == num_tracks);

        var timeline: Timeline = .{
            .alloc = alloc,
            .tracks = undefined,
            .track_counts = .{ num_tracks, 0 },
        };

        for (0..num_tracks) |i| {
            timeline.tracks[0][i] = try Track.init(alloc, voices_per_track, notes_per_track[i]);
        }

        return timeline;
    }

    pub fn deinit(self: *Timeline) void {
        const buf = self.active.load(.acquire);
        for (self.tracks[buf][0..self.track_counts[buf]]) |t| {
            t.deinit(self.alloc);
            self.alloc.destroy(t);
        }
    }

    pub fn asNode(self: *Timeline) audio.Node {
        return .{ .ptr = self, .v = &self.vt };
    }

    pub fn activeTracks(self: *Timeline) []*Track {
        const buf = self.active.load(.acquire);
        return self.tracks[buf][0..self.track_counts[buf]];
    }

    pub fn trackCount(self: *Timeline) usize {
        return self.track_counts[self.active.load(.acquire)];
    }

    pub fn addTrack(self: *Timeline, track: *Track) void {
        const front = self.active.load(.monotonic);
        const back = 1 - front;
        const n = self.track_counts[front];
        std.debug.assert(n < MAX_TRACKS);
        @memcpy(self.tracks[back][0..n], self.tracks[front][0..n]);
        self.tracks[back][n] = track;
        self.track_counts[back] = n + 1;
        self.active.store(back, .release);
    }

    pub fn removeTrack(self: *Timeline, idx: usize) *Track {
        const front = self.active.load(.monotonic);
        const back = 1 - front;
        const n = self.track_counts[front];
        std.debug.assert(idx < n);
        const removed = self.tracks[front][idx];
        @memcpy(self.tracks[back][0..idx], self.tracks[front][0..idx]);
        if (idx < n - 1) {
            @memcpy(self.tracks[back][idx .. n - 1], self.tracks[front][idx + 1 .. n]);
        }
        self.track_counts[back] = n - 1;
        self.active.store(back, .release);
        return removed;
    }

    fn _process(p: *anyopaque, ctx: *audio.Context, out: []audio.Sample) void {
        const self: *Timeline = @ptrCast(@alignCast(p));
        const buf = self.active.load(.acquire);
        @memset(out, 0);
        for (self.tracks[buf][0..self.track_counts[buf]]) |track| {
            const track_out = ctx.tmp().alloc(audio.Sample, out.len) catch unreachable;
            const node = track.asNode();
            node.v.process(node.ptr, ctx, track_out);
            for (out, track_out) |*o, t| o.* += t;
        }
    }

    pub fn render(self: *Timeline) void {
        _ = self;
        for (0..interface.WIDTH) |x| {
            for (0..interface.HEIGHT) |y| {
                if ((x + y) % 2 == 0) {
                    rl.drawPixel(@intCast(x), @intCast(y), rl.Color.red);
                }
            }
        }
    }
};

pub const PluginTag = enum { lpf };

pub const Plugin = union(PluginTag) {
    lpf: audio.Lpf,

    pub fn deinitState(self: Plugin, alloc: std.mem.Allocator) void {
        switch (self) {
            inline else => |p| {
                if (@hasField(@TypeOf(p), "state")) {
                    if (@hasDecl(@TypeOf(p.state.*), "deinit")) {
                        p.state.deinit(alloc);
                    } else {
                        alloc.destroy(p.state);
                    }
                }
            },
        }
    }

    pub fn asNode(self: *Plugin) audio.Node {
        switch (self.*) {
            inline else => |*p| return p.asNode(),
        }
    }

    pub fn setInput(self: *Plugin, input: audio.Node) void {
        switch (self.*) {
            inline else => |*p| {
                p.input = input;
            },
        }
    }
};

pub const Track = struct {
    pub const MAX_PLUGINS = 8;

    synth: *uni.Uni,
    player: midi.Player,
    alloc: std.mem.Allocator,

    plugins: [2][MAX_PLUGINS]Plugin,
    plugin_counts: [2]usize,
    active: std.atomic.Value(usize) = .init(0),

    vt: audio.VTable = .{ .process = Track._process },

    pub fn init(alloc: std.mem.Allocator, voice_count: usize, notes_in: []const midi.Note) !*Track {
        const t = try alloc.create(Track);
        t.* = .{
            .synth = try uni.Uni.init(alloc, voice_count),
            .player = try midi.Player.init(alloc, notes_in),
            .alloc = alloc,
            .plugins = undefined,
            .plugin_counts = .{ 0, 0 },
        };
        return t;
    }

    pub fn deinit(self: *Track, alloc: std.mem.Allocator) void {
        self.synth.deinit(alloc);
        self.player.deinit(alloc);
        const buf = self.active.load(.acquire);
        for (self.plugins[buf][0..self.plugin_counts[buf]]) |p| {
            p.deinitState(alloc);
        }
    }

    fn _process(p: *anyopaque, ctx: *audio.Context, out: []audio.Sample) void {
        const self: *Track = @ptrCast(@alignCast(p));
        const node = self.output();
        node.v.process(node.ptr, ctx, out);
    }

    fn output(self: *Track) audio.Node {
        const buf = self.active.load(.acquire);
        if (self.plugin_counts[buf] > 0) return self.plugins[buf][self.plugin_counts[buf] - 1].asNode();
        return self.synth.asNode();
    }

    pub fn asNode(self: *Track) audio.Node {
        return .{ .ptr = self, .v = &self.vt };
    }

    pub fn addPlugin(self: *Track, plugin: Plugin) void {
        const front = self.active.load(.monotonic);
        const back = 1 - front;
        const n = self.plugin_counts[front];
        std.debug.assert(n < MAX_PLUGINS);
        @memcpy(self.plugins[back][0..n], self.plugins[front][0..n]);
        self.plugins[back][n] = plugin;
        self.plugin_counts[back] = n + 1;
        self.rewireBuf(back);
        self.active.store(back, .release);
    }

    pub fn removePlugin(self: *Track, idx: usize) Plugin {
        const front = self.active.load(.monotonic);
        const back = 1 - front;
        const n = self.plugin_counts[front];
        const removed = self.plugins[front][idx];
        @memcpy(self.plugins[back][0..idx], self.plugins[front][0..idx]);
        if (idx < n - 1) {
            @memcpy(self.plugins[back][idx .. n - 1], self.plugins[front][idx + 1 .. n]);
        }
        self.plugin_counts[back] = n - 1;
        self.rewireBuf(back);
        self.active.store(back, .release);
        return removed;
    }

    pub fn hasPlugin(self: *Track, tag: PluginTag) bool {
        const buf = self.active.load(.acquire);
        for (self.plugins[buf][0..self.plugin_counts[buf]]) |p| {
            if (p == tag) return true;
        }
        return false;
    }

    pub fn findPlugin(self: *Track, tag: PluginTag) ?usize {
        const buf = self.active.load(.acquire);
        for (self.plugins[buf][0..self.plugin_counts[buf]], 0..) |p, i| {
            if (p == tag) return i;
        }
        return null;
    }

    pub fn removePluginByTag(self: *Track, tag: PluginTag) ?Plugin {
        if (self.findPlugin(tag)) |idx| {
            return self.removePlugin(idx);
        }
        return null;
    }

    pub fn clear(self: *Track) void {
        self.player.clear();
        self.synth.allNotesOff();
        const front = self.active.load(.monotonic);
        const back = 1 - front;
        self.plugin_counts[back] = 0;
        self.active.store(back, .release);
    }

    fn rewireBuf(self: *Track, buf: usize) void {
        var prev = self.synth.asNode();
        for (self.plugins[buf][0..self.plugin_counts[buf]]) |*p| {
            p.setInput(prev);
            prev = p.asNode();
        }
    }
};
