const std = @import("std");
const project = @import("project.zig");
const midi = @import("midi.zig");
const audio = @import("audio.zig");
const interface = @import("interface.zig");

pub const App = struct {
    pub const Screen = enum {
        timeline,
    };

    screen: Screen = .timeline,
    timeline: project.Timeline,

    pub fn init(
        alloc: std.mem.Allocator,
        num_tracks: usize,
        voices_per_track: usize,
        notes_per_track: []const []const midi.Note,
    ) !App {
        return .{
            .timeline = try project.Timeline.init(alloc, num_tracks, voices_per_track, notes_per_track),
        };
    }

    pub fn deinit(self: *App) void {
        self.timeline.deinit();
    }

    pub fn asNode(self: *App) audio.Node {
        return self.timeline.asNode();
    }

    pub fn render(self: *App) void {
        switch (self.screen) {
            .timeline => self.timeline.render(),
        }
    }
};
