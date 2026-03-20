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

pub const Knob = struct {
    param: *audio.Param,
    pos: rl.Vector2,
    radius: f32,
    color: rl.Color,
    name: [:0]const u8,

    pub fn render(self: Knob) void {
        const angle = self.param.getNorm() * 360;
        rl.drawCircleSector(self.pos, self.radius, 0, angle, 360, self.color);
        interface.drawTextCentered(self.name, @intFromFloat(self.pos.x), @intFromFloat(self.pos.y + 20), 10, self.color);
    }
};

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

    pub fn handleEvent(self: *Plugin, event: interface.Event) ops.ActionList {
        switch (self.*) {
            inline else => |p| return p.handleEvent(event),
        }
    }

    pub fn getIcon(self: *Plugin) rl.Texture2D {
        switch (self.*) {
            inline else => |p| return p.icon,
        }
    }
};

pub const Lpf = struct {
    lpf: audio.Lpf,
    drive: Knob,
    resonance: Knob,
    cutoff: Knob,
    icon: rl.Texture2D,

    pub fn init(alloc: std.mem.Allocator, input: audio.Node) !*Lpf {
        const self = try alloc.create(Lpf);
        self.lpf = audio.Lpf.init(input);
        self.drive = .{ .param = &self.lpf.drive, .pos = .{ .x = 32, .y = 32 }, .radius = 10, .color = rl.Color.white, .name = "drive" };
        self.resonance = .{ .param = &self.lpf.resonance, .pos = .{ .x = 96, .y = 32 }, .radius = 10, .color = rl.Color.white, .name = "resonance" };
        self.cutoff = .{ .param = &self.lpf.cutoff, .pos = .{ .x = 32, .y = 96 }, .radius = 10, .color = rl.Color.white, .name = "cutoff" };
        self.icon = rl.loadTexture("assets/water_spell.png") catch unreachable;
        return self;
    }

    pub fn deinit(self: *Lpf, alloc: std.mem.Allocator) void {
        rl.unloadTexture(self.icon);
        alloc.destroy(self);
    }

    pub fn asNode(self: *Lpf) audio.Node {
        return self.lpf.asNode();
    }

    pub fn setInput(self: *Lpf, input: audio.Node) void {
        self.lpf.input = input;
    }

    pub fn render(self: *Lpf) void {
        self.drive.render();
        self.resonance.render();
        self.cutoff.render();
        interface.drawTextCentered("LPF", 64, 64, 10, rl.Color.green);
    }

    pub fn handleEvent(self: *Lpf, event: interface.Event) ops.ActionList {
        switch (event.key) {
            .backspace => return ops.ActionList.fromSlice(&.{.go_back}),
            .one => self.drive.param.setNorm(self.drive.param.getNorm() - 0.1),
            .two => self.drive.param.setNorm(self.drive.param.getNorm() + 0.1),
            .three => self.resonance.param.setNorm(self.resonance.param.getNorm() - 0.1),
            .four => self.resonance.param.setNorm(self.resonance.param.getNorm() + 0.1),
            .five => self.cutoff.param.setNorm(self.cutoff.param.getNorm() - 0.1),
            .six => self.cutoff.param.setNorm(self.cutoff.param.getNorm() + 0.1),
            else => {},
        }
        return .{};
    }
};

pub const Delay = struct {
    delay: audio.Delay,
    delay_time: Knob,
    feedback: Knob,
    mix: Knob,
    icon: rl.Texture2D,

    pub fn init(alloc: std.mem.Allocator, input: audio.Node, buffer_size: usize) !*Delay {
        const self = try alloc.create(Delay);
        self.delay = try audio.Delay.init(alloc, input, buffer_size);
        self.delay_time = .{ .param = &self.delay.delay_time, .pos = .{ .x = 32, .y = 32 }, .radius = 10, .color = rl.Color.white, .name = "delay_time" };
        self.feedback = .{ .param = &self.delay.feedback, .pos = .{ .x = 96, .y = 32 }, .radius = 10, .color = rl.Color.white, .name = "feedback" };
        self.mix = .{ .param = &self.delay.mix, .pos = .{ .x = 32, .y = 96 }, .radius = 10, .color = rl.Color.white, .name = "mix" };
        self.icon = rl.loadTexture("assets/slowed.png") catch unreachable;
        return self;
    }

    pub fn deinit(self: *Delay, alloc: std.mem.Allocator) void {
        rl.unloadTexture(self.icon);
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
        self.delay_time.render();
        self.feedback.render();
        self.mix.render();
        interface.drawTextCentered("DELAY", 64, 64, 10, rl.Color.purple);
    }

    pub fn handleEvent(self: *Delay, event: interface.Event) ops.ActionList {
        switch (event.key) {
            .backspace => return ops.ActionList.fromSlice(&.{.go_back}),
            .one => self.delay_time.param.setNorm(self.delay_time.param.getNorm() - 0.1),
            .two => self.delay_time.param.setNorm(self.delay_time.param.getNorm() + 0.1),
            .three => self.feedback.param.setNorm(self.feedback.param.getNorm() - 0.1),
            .four => self.feedback.param.setNorm(self.feedback.param.getNorm() + 0.1),
            .five => self.mix.param.setNorm(self.mix.param.getNorm() - 0.1),
            .six => self.mix.param.setNorm(self.mix.param.getNorm() + 0.1),
            else => {},
        }
        return .{};
    }
};
