const std = @import("std");
const synth = @import("synth.zig");
const midi = @import("midi.zig");
const audio = @import("audio.zig");
const plugin = @import("plugin.zig");
const interface = @import("interface.zig");
const rl = @import("raylib");
const ops = @import("ops.zig");

pub const App = struct {
    const Mode = enum { normal, insert };

    timeline: Timeline,
    mode: Mode,

    active_notes: std.AutoHashMap(rl.KeyboardKey, u8), // keep key state for (press, offset, release) case
    note_offset: i16,
    note_queue: midi.NoteQueue = .{},

    pub fn init(
        alloc: std.mem.Allocator,
        num_tracks: usize,
        voices_per_track: usize,
        notes_per_track: []const []const midi.Note,
    ) !App {
        return .{
            .timeline = try Timeline.init(alloc, num_tracks, voices_per_track, notes_per_track),
            .mode = .normal,
            .active_notes = std.AutoHashMap(rl.KeyboardKey, u8).init(alloc),
            .note_offset = 0,
        };
    }

    pub fn deinit(self: *App) void {
        self.timeline.deinit();
        self.active_notes.deinit();
    }

    pub fn render(self: *App) void {
        self.timeline.render();
        // draw after for overlay
        for (0..interface.WIDTH) |x| {
            for (0..interface.HEIGHT) |y| {
                if (x == 0 or y == 0 or x == interface.WIDTH - 1 or y == interface.WIDTH - 1) {
                    rl.drawPixel(@intCast(x), @intCast(y), rl.Color.purple);
                }
            }
        }
    }

    pub fn handleEvent(self: *App, event: interface.Event) ?ops.Action {
        switch (self.mode) {
            .insert => {
                // play notes
                if (midi.keyToMidi(event.key)) |base| {
                    const raw = @as(i16, base) + self.note_offset;
                    if (raw < 0 or raw > 127) return null;
                    const note: u8 = @intCast(raw);

                    switch (event.type) {
                        .key_press => {
                            self.active_notes.put(event.key, note) catch return null;
                            while (!self.note_queue.push(.{ .on = note })) {}
                        },
                        .key_release => {
                            if (self.active_notes.get(event.key)) |held| {
                                _ = self.active_notes.remove(event.key);
                                while (!self.note_queue.push(.{ .off = held })) {}
                            }
                        },
                    }
                    return null;
                }

                // insert mode commands
                if (event.type == .key_press) {
                    switch (event.key) {
                        .escape => {
                            // drain held notes before switching mode
                            var it = self.active_notes.iterator();
                            while (it.next()) |entry| {
                                while (!self.note_queue.push(.{ .off = entry.value_ptr.* })) {}
                            }
                            self.active_notes.clearRetainingCapacity();
                            self.mode = .normal;
                        },
                        .z => self.note_offset = @max(self.note_offset - 12, -48),
                        .x => self.note_offset = @min(self.note_offset + 12, 48),
                        else => {},
                    }
                }
                return null;
            },
            .normal => {
                if (event.type != .key_press) return null;
                if (event.key == .i) {
                    self.mode = .insert;
                    return null;
                }
                return self.timeline.handleEvent(event);
            },
        }
    }
};

pub const Timeline = struct {
    const Screen = enum { overview, track, midi_editor };
    pub const MAX_TRACKS = 8;

    alloc: std.mem.Allocator,
    tracks: [MAX_TRACKS]*Track,
    track_count: usize,
    midi_editor: MidiEditor,
    vt: audio.VTable = .{ .process = _process },

    active_track: usize = 0,
    scroll_offset: usize = 0,

    screen: Screen,

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
            .midi_editor = .{},
            .screen = .overview,
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

    // TODO remove?
    pub fn activeTracks(self: *Timeline) []*Track {
        return self.tracks[0..self.track_count];
    }

    pub fn activeTrack(self: *Timeline) *Track {
        return self.tracks[self.active_track];
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
        switch (self.screen) {
            .overview => {
                for (0..interface.WIDTH) |x| {
                    for (0..interface.HEIGHT) |y| {
                        if ((x + y) % 2 == 0) {
                            rl.drawPixel(@intCast(x), @intCast(y), rl.Color.red);
                        }
                    }
                }
                rl.drawText("TIMELINE_OVERVIEW", 30, 30, 10, rl.Color.light_gray);
            },
            .track => {
                // track doesn't know it's own index, draw it here
                rl.drawRectangle(0, 0, 32, 32, rl.Color.red);
                interface.drawTextCentered(&interface.toString(usize, self.active_track), 16, 16, 8, rl.Color.light_gray);
                self.activeTrack().render();
            },
            .midi_editor => self.midi_editor.render(),
        }
    }

    pub fn handleEvent(self: *Timeline, event: interface.Event) ?ops.Action {
        const action = switch (self.screen) {
            .overview => {
                switch (event.key) {
                    .p => std.debug.print("in the TRACK\n", .{}),
                    .enter => self.screen = .track,
                    .e => self.screen = .midi_editor,
                    .down => if (self.active_track < self.track_count - 1) {
                        self.active_track += 1;
                    },
                    .up => if (self.active_track > 0) {
                        self.active_track -= 1;
                    },
                    .space => return .{ .op = .{ .playback = .toggle_play } },
                    .backspace => return .{ .op = .{ .playback = .reset } },
                    .r => return .{ .op = .{ .record = .{ .toggle_record = self.active_track } } },
                    .c => self.print(),
                    .equal => if (self.track_count < MAX_TRACKS) {
                        const new_track = Track.init(self.alloc, 4, &.{}) catch return null;
                        return .{ .op = .{ .graph = .{ .add_track = new_track } } };
                    },
                    .minus => if (self.track_count > 1) {
                        const idx = self.active_track;
                        if (self.active_track >= self.track_count - 1) {
                            self.active_track = self.track_count - 2;
                        }
                        return .{ .op = .{ .graph = .{ .remove_track = idx } } };
                    },
                    else => {},
                }
                return null;
            },
            .track => self.activeTrack().handleEvent(event),
            .midi_editor => self.midi_editor.handleEvent(event),
        } orelse return null;

        return switch (action) {
            .go_back => {
                self.screen = .overview;
                return null;
            },
            .add_plugin => |p| .{ .op = .{ .graph = .{ .add_plugin = .{ .track_idx = self.active_track, .plugin = p } } } },
            else => action,
        };
    }
};

pub const PluginTag = plugin.Tag;
pub const Plugin = plugin.Plugin;

pub const Track = struct {
    const Screen = enum { overview, plugin, plugin_selector };
    pub const MAX_PLUGINS = 8;

    synth: *synth.Uni,
    player: midi.Player,
    alloc: std.mem.Allocator,

    plugins: [MAX_PLUGINS]Plugin,
    plugin_count: usize,
    active_plugin: usize = 0,
    selector_index: usize = 0,

    screen: Screen,

    vt: audio.VTable = .{ .process = Track._process },

    pub fn init(alloc: std.mem.Allocator, voice_count: usize, notes_in: []const midi.Note) !*Track {
        const t = try alloc.create(Track);
        t.* = .{
            .synth = try synth.Uni.init(alloc, voice_count),
            .player = try midi.Player.init(alloc, notes_in),
            .alloc = alloc,
            .plugins = undefined,
            .plugin_count = 0,
            .screen = .overview,
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
        const node = self.outputNode();
        node.v.process(node.ptr, ctx, out);
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

    fn outputNode(self: *Track) audio.Node {
        return if (self.plugin_count > 0) self.plugins[self.plugin_count - 1].asNode() else self.synth.asNode();
    }

    pub fn render(self: *Track) void {
        switch (self.screen) {
            .overview => {
                // draw grid (bottom half only, y >= 64)
                for (0..5) |i| {
                    const ix: i32 = @intCast(i);
                    rl.drawLine(ix * 32, 64, ix * 32, 128, rl.Color.white); // vertical
                }
                for (0..3) |i| {
                    const iy: i32 = @intCast(i);
                    rl.drawLine(0, 64 + iy * 32, 128, 64 + iy * 32, rl.Color.white); // horizontal
                }

                for (0..self.plugin_count) |i| {
                    const ix: i32 = @intCast(i % 4);
                    const iy: i32 = @intCast(i / 4);
                    const x = ix * 32 + 16;
                    const y = iy * 32 + 64 + 16;

                    const name = @tagName(self.plugins[i]);
                    const font_size = 10;
                    const width = rl.measureText(name, font_size);
                    rl.drawText(name, x - @divTrunc(width, 2), y + 6, font_size, rl.Color.white);

                    if (i == self.active_plugin) {
                        rl.drawCircle(x, y, 5.0, rl.Color.green);
                    }
                }

                for (self.plugin_count..MAX_PLUGINS) |i| {
                    const ix: i32 = @intCast(i % 4);
                    const iy: i32 = @intCast(i / 4);
                    const x = ix * 32 + 16;
                    const y = iy * 32 + 64 + 16;

                    rl.drawCircle(x, y, 1.0, rl.Color.red);
                    rl.drawText("none", x - 11, y + 4, 10, rl.Color.white);
                }

                rl.drawText("TRACK", 30, 30, 10, rl.Color.light_gray);
            },
            .plugin => {
                // TODO: plugin render
            },
            .plugin_selector => {
                for (plugin.list, 0..) |tag, i| {
                    const name = @tagName(tag);
                    const y: i32 = @intCast(i * 16);
                    const color: rl.Color = if (i == self.selector_index) rl.Color.blue else rl.Color.red;
                    rl.drawRectangle(0, y, 128, 16, rl.Color.dark_gray);
                    rl.drawText(name, 0, y, 5, color);
                }
            },
        }
    }

    pub fn handleEvent(self: *Track, event: interface.Event) ?ops.Action {
        switch (self.screen) {
            .overview => {
                switch (event.key) {
                    .p => std.debug.print("in the TRACK\n", .{}),
                    .backspace => return .go_back,
                    .a => self.screen = .plugin_selector,
                    .enter => self.screen = .plugin,
                    .l => if (self.plugin_count > 0) {
                        self.active_plugin = @min(self.active_plugin + 1, self.plugin_count - 1);
                    },
                    .h => if (self.active_plugin > 0) {
                        self.active_plugin -= 1;
                    },
                    // .x => self.removePlugin(self.active_plugin),
                    else => {},
                }
            },
            .plugin => {
                switch (event.key) {
                    .backspace => return .go_back,
                    else => {},
                }
            },
            .plugin_selector => {
                switch (event.key) {
                    .backspace => self.screen = .overview,
                    .k => if (self.selector_index > 0) {
                        self.selector_index -= 1;
                    },
                    .j => if (self.selector_index < plugin.list.len - 1) {
                        self.selector_index += 1;
                    },
                    .enter => {
                        const input = self.outputNode();

                        self.screen = .overview;
                        const p = plugin.create(self.alloc, plugin.list[self.selector_index], input) catch return null;
                        return .{ .add_plugin = p };
                    },
                    else => {},
                }
            },
        }
        return null;
    }
};

pub const MidiEditor = struct {
    pub fn render(self: *MidiEditor) void {
        _ = self;
        for (0..interface.WIDTH) |x| {
            for (0..interface.HEIGHT) |y| {
                if ((x + y) % 2 == 0) {
                    // rl.drawPixel(@intCast(x), @intCast(y), rl.Color.brown);
                }
            }
        }

        rl.drawText("MIDI_EDITOR", 30, 30, 10, rl.Color.light_gray);
    }

    pub fn handleEvent(self: *MidiEditor, event: interface.Event) ?ops.Action {
        _ = self;

        switch (event.key) {
            .p => std.debug.print("in the MIDI EDITOR\n", .{}),
            .backspace => return .go_back,
            else => {},
        }
        return null;
    }
};
