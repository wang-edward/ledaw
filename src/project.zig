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

    recording: *std.atomic.Value(bool),

    pub fn init(
        alloc: std.mem.Allocator,
        playhead: *std.atomic.Value(u64),
        recording: *std.atomic.Value(bool),
        ctx: *audio.Context,
    ) !App {
        return .{
            .timeline = try Timeline.init(alloc, playhead, ctx),
            .mode = .normal,
            .active_notes = std.AutoHashMap(rl.KeyboardKey, u8).init(alloc),
            .note_offset = 0,
            .recording = recording,
        };
    }

    pub fn deinit(self: *App) void {
        self.timeline.deinit();
        self.active_notes.deinit();
    }

    pub fn render(self: *App) void {
        self.timeline.render();
        // draw after for overlay
        if (self.mode == .insert) {
            for (0..interface.WIDTH) |x| {
                for (0..interface.HEIGHT) |y| {
                    if (x == 0 or y == 0 or x == interface.WIDTH - 1 or y == interface.WIDTH - 1) {
                        rl.drawPixel(@intCast(x), @intCast(y), rl.Color.purple);
                    }
                }
            }
        }
        if (self.recording.load(.acquire)) {
            for (0..interface.WIDTH) |x| {
                for (0..interface.HEIGHT) |y| {
                    if (x == 1 or y == 1 or x == interface.WIDTH - 2 or y == interface.WIDTH - 2) {
                        rl.drawPixel(@intCast(x), @intCast(y), rl.Color.red);
                    }
                }
            }
        }
    }

    pub fn handleEvent(self: *App, event: interface.Event) ops.ActionList {
        switch (self.mode) {
            .insert => {
                // play notes
                if (midi.keyToMidi(event.key)) |base| {
                    const raw = @as(i16, base) + self.note_offset;
                    if (raw < 0 or raw > 127) return .{};
                    const note: u8 = @intCast(raw);

                    switch (event.type) {
                        .key_press => {
                            self.active_notes.put(event.key, note) catch return .{};
                            while (!self.note_queue.push(.{ .on = note })) {}
                        },
                        .key_release => {
                            if (self.active_notes.get(event.key)) |held| {
                                _ = self.active_notes.remove(event.key);
                                while (!self.note_queue.push(.{ .off = held })) {}
                            }
                        },
                    }
                    return .{};
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
                        .z => self.note_offset = @max(self.note_offset - 12, -24),
                        .x => self.note_offset = @min(self.note_offset + 12, 24),
                        else => {},
                    }
                }
                return .{};
            },
            .normal => {
                if (event.type != .key_press) return .{};
                if (event.key == .i) {
                    self.mode = .insert;
                    return .{};
                }
                return self.timeline.handleEvent(event);
            },
        }
    }
};

const BeatFrame = struct {
    center: f32,
    radius: f32,
    fn leftEdge(self: BeatFrame) f32 {
        return self.center - self.radius;
    }
    fn rightEdge(self: BeatFrame) f32 {
        return self.center + self.radius;
    }
    fn width(self: BeatFrame) f32 {
        return self.radius * 2;
    }
};
const BeatWindow = struct {
    start: f32,
    len: f32,
    fn leftEdge(self: BeatWindow) f32 {
        return self.start;
    }
    fn rightEdge(self: BeatWindow) f32 {
        return self.start + self.len;
    }
};

pub const Timeline = struct {
    const Screen = enum { overview, track, midi_editor };
    pub const MAX_TRACKS = 8;
    const HEADER_HEIGHT = 12;
    const ROW_HEIGHT = 28;

    screen: Screen,

    alloc: std.mem.Allocator,
    tracks: [MAX_TRACKS]*Track,
    track_count: usize,
    midi_editor: MidiEditor,
    vt: audio.VTable = .{ .process = _process },

    active_track: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    scroll_offset: usize = 0,
    playhead: *std.atomic.Value(u64),
    ctx: *audio.Context,
    frame: BeatFrame = .{ .center = 0, .radius = 8.0 },
    bar_width: f32 = 4.0,
    cursor: BeatWindow = .{ .start = 0, .len = 4.0 },
    step_size: f32 = 4.0,

    pub fn init(
        alloc: std.mem.Allocator,
        playhead: *std.atomic.Value(u64),
        ctx: *audio.Context,
    ) !Timeline {
        return .{
            .alloc = alloc,
            .tracks = undefined,
            .track_count = 0,
            .midi_editor = .{},
            .screen = .overview,
            .playhead = playhead,
            .ctx = ctx,
        };
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
        return self.tracks[self.active_track.load(.acquire)];
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

    pub fn clear(self: *Timeline) void {
        self.screen = .overview;
        for (self.activeTracks()) |t| {
            t.clear();
        }
        self.track_count = 0;
        self.active_track = std.atomic.Value(usize).init(0);
        self.playhead.store(0, .release);
        self.frame.center = 0;
        self.cursor.start = 0;
    }

    fn cursorFocus(self: *Timeline) void {
        if (self.cursor.leftEdge() < self.frame.leftEdge()) {
            const diff = self.frame.leftEdge() - self.cursor.leftEdge();
            self.frame.center -= diff;
        } else if (self.cursor.rightEdge() > self.frame.rightEdge()) {
            const diff = self.cursor.rightEdge() - self.frame.rightEdge();
            self.frame.center += diff;
        }
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
        const tempo = self.ctx.bpm;
        const sr = self.ctx.sample_rate;
        std.debug.print("timeline: {d} tracks\n", .{self.track_count});
        for (self.tracks[0..self.track_count], 0..) |track, i| {
            std.debug.print("  track {d}: {d} notes, {d} plugins", .{ i, track.player.notes.items.len, track.plugin_count });
            if (i == self.active_track.load(.acquire)) std.debug.print(" [active] ", .{});
            if (track.plugin_count > 0) {
                std.debug.print(" [", .{});
                for (track.plugins[0..track.plugin_count], 0..) |p, j| {
                    if (j > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}", .{@tagName(p)});
                }
                std.debug.print("]", .{});
            }
            std.debug.print("\n", .{});
            for (track.player.notes.items) |note| {
                std.debug.print("    note={d} start={d:.2} end={d:.2}\n", .{
                    note.note,
                    midi.framesToBeats(note.start, tempo, sr),
                    midi.framesToBeats(note.end, tempo, sr),
                });
            }
        }
    }

    pub fn render(self: *Timeline) void {
        switch (self.screen) {
            .overview => {
                const W: f32 = @floatFromInt(interface.WIDTH);
                const num_rows = @min(self.track_count, MAX_TRACKS);
                const b = midi.framesToBeats(self.playhead.load(.acquire), self.ctx.bpm, self.ctx.sample_rate);
                if (b > self.frame.rightEdge() or b < self.frame.leftEdge()) {
                    self.frame.center = b;
                }

                // beat position text
                const bar: i32 = @intFromFloat(@floor(b / self.bar_width));
                const beat_in_bar: i32 = @intFromFloat(@mod(b, self.bar_width));
                var buf: [20:0]u8 = .{0} ** 20;
                _ = std.fmt.bufPrint(&buf, "{d}.{d}", .{ bar + 1, beat_in_bar + 1 }) catch {};
                interface.drawTextCentered(&buf, interface.WIDTH / 2, HEADER_HEIGHT / 2, 8, rl.Color.white);

                // bar lines
                var bar_pos = @floor(self.frame.leftEdge() / self.bar_width) * self.bar_width;
                while (bar_pos < self.frame.rightEdge()) : (bar_pos += self.bar_width) {
                    const pct = (bar_pos - self.frame.leftEdge()) / self.frame.width();
                    const x: i32 = @intFromFloat(pct * W);
                    rl.drawLine(x, HEADER_HEIGHT, x, HEADER_HEIGHT + @as(i32, @intCast(num_rows)) * ROW_HEIGHT, rl.Color.dark_gray);
                }

                // track rows + notes
                for (0..num_rows) |i| {
                    const row_y: i32 = @as(i32, @intCast(i)) * ROW_HEIGHT + HEADER_HEIGHT;
                    rl.drawRectangleLines(0, row_y, @intCast(interface.WIDTH), ROW_HEIGHT, rl.Color.dark_gray);

                    // render notes: 2px buffer top/bottom, 24 semitones (2 octaves) in between
                    const track = self.tracks[i + self.scroll_offset];
                    for (track.player.notes.items) |note| {
                        const start_beat = midi.framesToBeats(note.start, self.ctx.bpm, self.ctx.sample_rate);
                        const end_beat = midi.framesToBeats(note.end, self.ctx.bpm, self.ctx.sample_rate);
                        if (end_beat < self.frame.leftEdge() or start_beat > self.frame.rightEdge()) continue;

                        const left_pct = (start_beat - self.frame.leftEdge()) / self.frame.width();
                        const right_pct = (end_beat - self.frame.leftEdge()) / self.frame.width();
                        const x1: i32 = @intFromFloat(@max(left_pct * W, 0));
                        const x2: i32 = @intFromFloat(@min(right_pct * W, W));

                        // map note to 0..23 (2 octaves), invert so higher notes are higher on screen
                        const slot: i32 = 23 - @as(i32, note.note % 24);
                        const ny = row_y + 2 + slot;
                        rl.drawLine(x1, ny, @max(x2, x1 + 1), ny, rl.Color.green);
                    }
                }

                // active track highlight
                {
                    const row: i32 = @intCast(self.active_track.load(.acquire) - self.scroll_offset);
                    const y = row * ROW_HEIGHT + HEADER_HEIGHT;
                    rl.drawRectangleLines(0, y, @intCast(interface.WIDTH), ROW_HEIGHT, rl.Color.red);
                }

                // playhead
                if (self.frame.leftEdge() < b and b < self.frame.rightEdge()) {
                    const pct = (b - self.frame.leftEdge()) / self.frame.width();
                    const x: i32 = @intFromFloat(pct * W);
                    rl.drawLine(x, HEADER_HEIGHT, x, @intCast(interface.HEIGHT), rl.Color.white);
                }

                // cursor
                {
                    const row: i32 = @intCast(self.active_track.load(.acquire) - self.scroll_offset);
                    const y = row * ROW_HEIGHT + HEADER_HEIGHT;
                    const left_pct = (self.cursor.leftEdge() - self.frame.leftEdge()) / self.frame.width();
                    const right_pct = (self.cursor.rightEdge() - self.frame.leftEdge()) / self.frame.width();
                    const left_px: i32 = @intFromFloat(left_pct * W);
                    const right_px: i32 = @intFromFloat(right_pct * W);
                    rl.drawRectangleLines(left_px, y, right_px - left_px, ROW_HEIGHT, rl.Color.orange);
                }
            },
            .track => self.activeTrack().render(),
            .midi_editor => self.midi_editor.render(),
        }
    }

    pub fn handleEvent(self: *Timeline, event: interface.Event) ops.ActionList {
        const actions = switch (self.screen) {
            .overview => {
                switch (event.key) {
                    .p => std.debug.print("in the TIMELINE\n", .{}),
                    .enter => self.screen = .track,
                    // .e => self.screen = .midi_editor,
                    .h => {
                        self.cursor.start -= self.step_size;
                        self.cursorFocus();
                    },
                    .l => {
                        self.cursor.start += self.step_size;
                        self.cursorFocus();
                    },
                    .j => {
                        const at = self.active_track.load(.acquire);
                        if (self.track_count > 0 and at < self.track_count - 1) {
                            return ops.ActionList.fromSlice(&.{.{ .op = .{ .graph = .{ .set_active_track = at + 1 } } }});
                        }
                    },
                    .k => {
                        const at = self.active_track.load(.acquire);
                        if (at > 0) {
                            return ops.ActionList.fromSlice(&.{.{ .op = .{ .graph = .{ .set_active_track = at - 1 } } }});
                        }
                    },
                    .space => return ops.ActionList.fromSlice(&.{.{ .op = .{ .playback = .toggle_play } }}),
                    .backspace => return ops.ActionList.fromSlice(&.{.{ .op = .{ .playback = .reset } }}),
                    .r => return ops.ActionList.fromSlice(&.{.{ .op = .{ .record = .toggle_record } }}),
                    .c => self.print(),
                    .equal => if (self.track_count < MAX_TRACKS) {
                        const new_track = Track.init(self.alloc, &self.active_track, &.{}) catch unreachable;
                        return ops.ActionList.fromSlice(&.{.{ .op = .{ .graph = .{ .add_track = new_track } } }});
                    },
                    // .minus => if (self.track_count > 1) {
                    //     const idx = self.active_track.load(.acquire);
                    //     return ops.ActionList.fromSlice(&.{.{ .op = .{ .graph = .{ .remove_track = idx } } }});
                    // },
                    // zoom
                    .right_bracket => self.frame.radius = @max(self.frame.radius / 2, 8),
                    .left_bracket => self.frame.radius = @min(self.frame.radius * 2, 32),
                    else => {},
                }
                return .{};
            },
            .track => self.activeTrack().handleEvent(event),
            .midi_editor => self.midi_editor.handleEvent(event),
        };

        var result = ops.ActionList{};
        for (actions.constSlice()) |ac| {
            switch (ac) {
                .go_back => self.screen = .overview,
                else => result.appendAssumeCapacity(ac),
            }
        }
        return result;
    }
};

pub const PluginTag = plugin.Tag;
pub const Plugin = plugin.Plugin;

pub const Track = struct {
    const Screen = enum { overview, plugin, plugin_selector };
    pub const MAX_PLUGINS = 2;

    synth: *synth.Uni,
    player: midi.Player,
    alloc: std.mem.Allocator,

    index: *const std.atomic.Value(usize),
    plugins: [MAX_PLUGINS]Plugin,
    plugin_count: usize,
    active_plugin: usize = 0,
    selector_index: usize = 0,

    screen: Screen,

    vt: audio.VTable = .{ .process = Track._process },

    pub fn init(alloc: std.mem.Allocator, index: *const std.atomic.Value(usize), notes_in: []const midi.Note) !*Track {
        const t = try alloc.create(Track);
        t.* = .{
            .synth = try synth.Uni.init(alloc),
            .player = try midi.Player.init(alloc, notes_in),
            .alloc = alloc,
            .index = index,
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
                rl.drawRectangle(0, 0, 32, 32, rl.Color.red);
                interface.drawTextCentered(&interface.toString(usize, self.index.load(.acquire)), 16, 16, 8, rl.Color.light_gray);

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
                    rl.drawTexture(self.plugins[i].getIcon(), x - 8, y - 8, rl.Color.white);
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
            },
            .plugin => {
                std.debug.assert(self.plugin_count > 0);
                self.plugins[self.active_plugin].render();
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

    pub fn handleEvent(self: *Track, event: interface.Event) ops.ActionList {
        switch (self.screen) {
            .overview => {
                switch (event.key) {
                    .p => std.debug.print("in the TRACK\n", .{}),
                    .backspace => return ops.ActionList.fromSlice(&.{.go_back}),
                    .a => {
                        self.selector_index = std.crypto.random.intRangeLessThan(usize, 0, plugin.list.len);
                        self.screen = .plugin_selector;
                    },
                    .enter => if (self.plugin_count > 0) {
                        self.screen = .plugin;
                    },
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
                const actions = self.plugins[self.active_plugin].handleEvent(event);
                var result = ops.ActionList{};
                for (actions.constSlice()) |ac| {
                    switch (ac) {
                        .go_back => self.screen = .overview,
                        else => result.appendAssumeCapacity(ac),
                    }
                }
                return result;
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
                        const p = plugin.create(self.alloc, plugin.list[self.selector_index], input) catch return .{};
                        return ops.ActionList.fromSlice(&.{.{ .op = .{ .graph = .{ .add_plugin = .{ .track_idx = self.index.load(.acquire), .plugin = p } } } }});
                    },
                    else => {},
                }
            },
        }
        return .{};
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
    }

    pub fn handleEvent(self: *MidiEditor, event: interface.Event) ops.ActionList {
        _ = self;

        switch (event.key) {
            .p => std.debug.print("in the MIDI EDITOR\n", .{}),
            .backspace => return ops.ActionList.fromSlice(&.{.go_back}),
            else => {},
        }
        return .{};
    }
};
