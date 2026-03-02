const std = @import("std");
const synth = @import("synth.zig");
const midi = @import("midi.zig");
const audio = @import("audio.zig");
const plugin = @import("plugin.zig");
const interface = @import("interface.zig");
const rl = @import("raylib");
const ops = @import("ops.zig");

pub const ScreenState = enum {
    timeline,
    track,
    plugin,
};

pub var screen: ScreenState = .timeline;

pub const Timeline = struct {
    pub const MAX_TRACKS = 8;

    alloc: std.mem.Allocator,
    tracks: [MAX_TRACKS]*Track,
    track_count: usize,
    vt: audio.VTable = .{ .process = _process },

    active_track: usize = 0,
    scroll_offset: usize = 0,

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
            .track_count = num_tracks,
        };

        for (0..num_tracks) |i| {
            timeline.tracks[i] = try Track.init(alloc, voices_per_track, notes_per_track[i]);
        }

        return timeline;
    }

    pub fn deinit(self: *Timeline) void {
        for (self.tracks[0..self.track_count]) |t| {
            t.deinit(self.alloc);
            self.alloc.destroy(t);
        }
    }

    pub fn asNode(self: *Timeline) audio.Node {
        return .{ .ptr = self, .v = &self.vt };
    }

    pub fn activeTracks(self: *Timeline) []*Track {
        return self.tracks[0..self.track_count];
    }

    pub fn trackCount(self: *Timeline) usize {
        return self.track_count;
    }

    pub fn addTrack(self: *Timeline, track: *Track) void {
        std.debug.assert(self.track_count < MAX_TRACKS);
        self.tracks[self.track_count] = track;
        self.track_count += 1;
    }

    pub fn removeTrack(self: *Timeline, idx: usize) *Track {
        const n = self.track_count;
        std.debug.assert(idx < n);
        const removed = self.tracks[idx];
        var i = idx;
        while (i < n - 1) : (i += 1) {
            self.tracks[i] = self.tracks[i + 1];
        }
        self.track_count = n - 1;
        return removed;
    }

    fn _process(p: *anyopaque, ctx: *audio.Context, out: []audio.Sample) void {
        const self: *Timeline = @ptrCast(@alignCast(p));
        @memset(out, 0);
        for (self.tracks[0..self.track_count]) |track| {
            const track_out = ctx.tmp().alloc(audio.Sample, out.len) catch unreachable;
            const node = track.asNode();
            node.v.process(node.ptr, ctx, track_out);
            for (out, track_out) |*o, t| o.* += t;
        }
    }

    pub fn print(self: *Timeline) void {
        std.debug.print("timeline: {d} tracks\n", .{self.track_count});
        for (self.tracks[0..self.track_count], 0..) |track, i| {
            std.debug.print("  track {d}: {d} notes, {d} plugins", .{ i, track.player.notes.items.len, track.plugin_count });
            if (i == self.active_track) std.debug.print(" [active] ", .{});
            if (track.plugin_count > 0) {
                std.debug.print(" [", .{});
                for (track.plugins[0..track.plugin_count], 0..) |p, j| {
                    if (j > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}", .{@tagName(p)});
                }
                std.debug.print("]", .{});
            }
            std.debug.print("\n", .{});
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

    pub fn handleEvent(self: *Timeline, ev: interface.Event) ?ops.Op {
        if (ev.type != .key_press) return null;

        switch (ev.key) {
            .enter => {
                screen = .track;
                return null;
            },
            .down => {
                if (self.active_track < self.track_count - 1) {
                    self.active_track += 1;
                }
                return null;
            },
            .up => {
                if (self.active_track > 0) {
                    self.active_track -= 1;
                }
                return null;
            },
            .space => return .{ .Playback = .TogglePlay },
            .backspace => return .{ .Playback = .Reset },
            .r => return .{ .Record = .{ .ToggleRecord = self.active_track } },
            .c => {
                self.print();
                return null;
            },
            .equal => {
                if (self.track_count < MAX_TRACKS) {
                    const new_track = Track.init(self.alloc, 4, &.{}) catch return null;
                    return .{ .Graph = .{ .AddTrack = new_track } };
                }
                return null;
            },
            .minus => {
                if (self.track_count > 1) {
                    const idx = self.active_track;
                    if (self.active_track >= self.track_count - 1) {
                        self.active_track = self.track_count - 2;
                    }
                    return .{ .Graph = .{ .RemoveTrack = idx } };
                }
                return null;
            },
            else => return null,
        }
    }

    pub fn activeTrack(self: *Timeline) *Track {
        return self.tracks[self.active_track];
    }
};

pub const PluginTag = plugin.Tag;
pub const Plugin = plugin.Plugin;

pub const Track = struct {
    pub const MAX_PLUGINS = 8;

    synth: *synth.Uni,
    player: midi.Player,
    alloc: std.mem.Allocator,

    plugins: [MAX_PLUGINS]Plugin,
    plugin_count: usize,
    active_plugin: usize = 0,

    vt: audio.VTable = .{ .process = Track._process },

    pub fn init(alloc: std.mem.Allocator, voice_count: usize, notes_in: []const midi.Note) !*Track {
        const t = try alloc.create(Track);
        t.* = .{
            .synth = try synth.Uni.init(alloc, voice_count),
            .player = try midi.Player.init(alloc, notes_in),
            .alloc = alloc,
            .plugins = undefined,
            .plugin_count = 0,
        };
        return t;
    }

    pub fn deinit(self: *Track, alloc: std.mem.Allocator) void {
        self.synth.deinit(alloc);
        self.player.deinit(alloc);
        for (self.plugins[0..self.plugin_count]) |p| {
            p.deinit(alloc);
        }
    }

    fn _process(p: *anyopaque, ctx: *audio.Context, out: []audio.Sample) void {
        const self: *Track = @ptrCast(@alignCast(p));
        const node = self.output();
        node.v.process(node.ptr, ctx, out);
    }

    fn output(self: *Track) audio.Node {
        if (self.plugin_count > 0) return self.plugins[self.plugin_count - 1].asNode();
        return self.synth.asNode();
    }

    pub fn asNode(self: *Track) audio.Node {
        return .{ .ptr = self, .v = &self.vt };
    }

    pub fn addPlugin(self: *Track, p: Plugin) void {
        std.debug.assert(self.plugin_count < MAX_PLUGINS);
        self.plugins[self.plugin_count] = p;
        self.plugin_count += 1;
        self.rewire();
    }

    pub fn removePlugin(self: *Track, idx: usize) Plugin {
        const n = self.plugin_count;
        const removed = self.plugins[idx];
        var i = idx;
        while (i < n - 1) : (i += 1) {
            self.plugins[i] = self.plugins[i + 1];
        }
        self.plugin_count = n - 1;
        self.rewire();
        return removed;
    }

    pub fn hasPlugin(self: *Track, tag: PluginTag) bool {
        for (self.plugins[0..self.plugin_count]) |p| {
            if (p == tag) return true;
        }
        return false;
    }

    pub fn findPlugin(self: *Track, tag: PluginTag) ?usize {
        for (self.plugins[0..self.plugin_count], 0..) |p, i| {
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
        self.plugin_count = 0;
    }

    fn rewire(self: *Track) void {
        var prev = self.synth.asNode();
        for (self.plugins[0..self.plugin_count]) |*p| {
            p.setInput(prev);
            prev = p.asNode();
        }
    }

    pub fn handleEvent(self: *Track, ev: interface.Event) ?ops.Op {
        if (ev.type != .key_press) return null;

        switch (ev.key) {
            .escape => {
                screen = .timeline;
                return null;
            },
            .h => {
                if (self.active_plugin > 0) {
                    self.active_plugin -= 1;
                }
                return null;
            },
            .l => {
                if (self.plugin_count > 0 and self.active_plugin < self.plugin_count - 1) {
                    self.active_plugin += 1;
                }
                return null;
            },
            .enter => {
                if (self.plugin_count > 0) {
                    screen = .plugin;
                }
                return null;
            },
            else => return null,
        }
    }
};
