const std = @import("std");
const audio = @import("audio.zig");
const interface = @import("interface.zig");
const ops = @import("ops.zig");
const rl = @import("raylib");

pub const Tag = enum { lpf, delay };
pub const list = std.enums.values(Tag);

pub fn create(alloc: std.mem.Allocator, tag: Tag, input: audio.Node) !Plugin {
    return switch (tag) {
        .lpf => .{ .lpf = try Lpf.init(alloc, input) },
        .delay => .{ .delay = try Delay.init(alloc, input, 22050) },
    };
}

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

    pub fn render(self: *Plugin) void {
        switch (self.*) {
            inline else => |p| p.render(),
        }
    }

    pub fn handleEvent(self: *Plugin, event: interface.Event) ?ops.Action {
        switch (self.*) {
            inline else => |p| return p.handleEvent(event),
        }
    }
};

pub const Lpf = struct {
    lpf: audio.Lpf,

    pub fn init(alloc: std.mem.Allocator, input: audio.Node) !*Lpf {
        const self = try alloc.create(Lpf);
        self.* = .{ .lpf = audio.Lpf.init(input) };
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

    pub fn render(self: *Lpf) void {
        _ = self;
        interface.drawTextCentered("LPF", 64, 64, 10, rl.Color.green);
    }

    pub fn handleEvent(self: *Lpf, event: interface.Event) ?ops.Action {
        _ = self;
        return switch (event.key) {
            .backspace => .go_back,
            else => null,
        };
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

    pub fn render(self: *Delay) void {
        _ = self;
        interface.drawTextCentered("DELAY", 64, 64, 10, rl.Color.purple);
    }

    pub fn handleEvent(self: *Delay, event: interface.Event) ?ops.Action {
        _ = self;
        return switch (event.key) {
            .backspace => .go_back,
            else => null,
        };
    }
};
