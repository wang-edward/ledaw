const std = @import("std");
const audio = @import("audio.zig");

pub const Tag = enum { lpf, delay };

pub const Plugin = union(Tag) {
    lpf: *Lpf,
    delay: *Delay,

    pub fn deinit(self: Plugin, alloc: std.mem.Allocator) void {
        switch (self) {
            inline else => |p| p.deinit(alloc),
        }
    }

    pub fn asNode(self: *Plugin) audio.Node {
        switch (self.*) {
            inline else => |p| return p.asNode(),
        }
    }

    pub fn setInput(self: *Plugin, input: audio.Node) void {
        switch (self.*) {
            inline else => |p| p.setInput(input),
        }
    }
};

pub const Lpf = struct {
    lpf: audio.Lpf,

    pub fn init(alloc: std.mem.Allocator, input: audio.Node, drive: f32, resonance: f32, cutoff: f32) !*Lpf {
        const self = try alloc.create(Lpf);
        self.* = .{ .lpf = audio.Lpf.init(input, drive, resonance, cutoff) };
        return self;
    }

    pub fn deinit(self: *Lpf, alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }

    pub fn asNode(self: *Lpf) audio.Node {
        return self.lpf.asNode();
    }

    pub fn setInput(self: *Lpf, input: audio.Node) void {
        self.lpf.input = input;
    }
};

pub const Delay = struct {
    delay: audio.Delay,

    pub fn init(alloc: std.mem.Allocator, input: audio.Node, buffer_size: usize) !*Delay {
        const self = try alloc.create(Delay);
        self.* = .{ .delay = try audio.Delay.init(alloc, input, buffer_size) };
        return self;
    }

    pub fn deinit(self: *Delay, alloc: std.mem.Allocator) void {
        self.delay.deinit(alloc);
        alloc.destroy(self);
    }

    pub fn asNode(self: *Delay) audio.Node {
        return self.delay.asNode();
    }

    pub fn setInput(self: *Delay, input: audio.Node) void {
        self.delay.input = input;
    }
};
