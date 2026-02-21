const std = @import("std");

pub const Sample = f32;

const ProcessFn = *const fn (self: *anyopaque, ctx: *Context, out: []Sample) void;
pub const VTable = struct { process: ProcessFn };
pub const Node = struct { ptr: *anyopaque, v: *const VTable };

pub const Context = struct {
    sample_rate: f32,
    bpm: f32,
    arena: std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator, sr: f32, bpm: f32) Context {
        return .{ .sample_rate = sr, .bpm = bpm, .arena = std.heap.ArenaAllocator.init(backing) };
    }
    pub fn beginBlock(self: *Context) void {
        _ = self.arena.reset(.retain_capacity);
    }
    pub fn tmp(self: *Context) std.mem.Allocator {
        return self.arena.allocator();
    }
};

pub const Osc = struct {
    pub const Kind = union(enum) {
        sine: struct {},
        pwm: struct { duty: f32 = 0.5 },
        saw: struct {},
        sub: struct { duty: f32 = 0.5, offset: f32 = -12 },
    };

    phase: f32 = 0,
    freq: f32,
    kind: Kind,
    vt: VTable = .{ .process = Osc._process },

    pub fn init(freq: f32, kind: Kind) Osc {
        return .{ .freq = freq, .kind = kind };
    }
    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        const self: *Osc = @ptrCast(@alignCast(p));
        const base_inc = self.freq / ctx.sample_rate;
        const inc = switch (self.kind) {
            .sub => |sub| base_inc * std.math.exp2(sub.offset / 12.0),
            else => base_inc,
        };
        for (0..out.len) |i| {
            const sample: Sample = switch (self.kind) {
                .sine => std.math.sin(self.phase * 2.0 * std.math.pi),
                .pwm => |pwm| if (self.phase < pwm.duty) 1.0 else -1.0,
                .saw => 2.0 * self.phase - 1.0,
                .sub => |sub| if (self.phase < sub.duty) 1.0 else -1.0,
            };
            out[i] = @floatCast(sample);
            self.phase += inc;
            while (self.phase >= 1.0) self.phase -= 1.0;
        }
    }
    pub fn asNode(self: *Osc) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
    pub fn resetPhase(self: *Osc) void {
        self.phase = 0.0;
    }
};

pub const Lpf = struct {
    // References: "An Improved Virtual Analog Model of the Moog Ladder Filter"
    // Original Implementation: D'Angelo, Valimaki
    pub const THERMAL_VOLTAGE = 0.312;

    V: [4]f32 = .{ 0, 0, 0, 0 },
    dV: [4]f32 = .{ 0, 0, 0, 0 },
    tV: [4]f32 = .{ 0, 0, 0, 0 },

    input: Node,
    drive: f32,
    resonance: f32,
    cutoff: f32,
    vt: VTable = .{ .process = Lpf._process },

    pub fn init(input: Node, drive: f32, resonance: f32, cutoff: f32) Lpf {
        return .{ .input = input, .drive = drive, .resonance = resonance, .cutoff = cutoff };
    }
    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        const self: *Lpf = @ptrCast(@alignCast(p));
        const in = ctx.tmp().alloc(Sample, out.len) catch unreachable;
        self.input.v.process(self.input.ptr, ctx, in);

        const x = (std.math.pi * self.cutoff) / ctx.sample_rate;
        const g = 4.0 * std.math.pi * THERMAL_VOLTAGE * self.cutoff * (1.0 - x) / (1.0 + x);
        for (0..out.len) |i| {
            const dV0 = -g * (std.math.tanh((self.drive * in[i] + self.resonance * self.V[3] / (2.0 * THERMAL_VOLTAGE)) + self.tV[0]));
            self.V[0] += (dV0 + self.dV[0]) / (2.0 * ctx.sample_rate);
            self.dV[0] = dV0;
            self.tV[0] = std.math.tanh(self.V[0] / (2.0 * THERMAL_VOLTAGE));

            const dV1 = g * (self.tV[0] - self.tV[1]);
            self.V[1] += (dV1 + self.dV[1]) / (2.0 * ctx.sample_rate);
            self.dV[1] = dV1;
            self.tV[1] = std.math.tanh(self.V[1] / (2.0 * THERMAL_VOLTAGE));

            const dV2 = g * (self.tV[1] - self.tV[2]);
            self.V[2] += (dV2 + self.dV[2]) / (2.0 * ctx.sample_rate);
            self.dV[2] = dV2;
            self.tV[2] = std.math.tanh(self.V[2] / (2.0 * THERMAL_VOLTAGE));

            const dV3 = g * (self.tV[2] - self.tV[3]);
            self.V[3] += (dV3 + self.dV[3]) / (2.0 * ctx.sample_rate);
            self.dV[3] = dV3;
            self.tV[3] = std.math.tanh(self.V[3] / (2.0 * THERMAL_VOLTAGE));

            out[i] = self.V[3];
        }
    }
    pub fn asNode(self: *Lpf) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
};

pub const Delay = struct {
    input: Node,
    buffer: []Sample,
    write_pos: usize = 0,
    delay_time: f32, // seconds
    feedback: f32,
    mix: f32, // [0.0, 1.0]
    vt: VTable = .{ .process = Delay._process },

    pub fn init(alloc: std.mem.Allocator, input: Node, buffer_size: usize) !Delay {
        const buffer = try alloc.alloc(Sample, buffer_size);
        @memset(buffer, 0);
        return .{
            .input = input,
            .buffer = buffer,
            .delay_time = 0.25,
            .feedback = 0.3,
            .mix = 0.2,
        };
    }

    pub fn deinit(self: *Delay, alloc: std.mem.Allocator) void {
        alloc.free(self.buffer);
    }

    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        var self: *Delay = @ptrCast(@alignCast(p));
        const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
        self.input.v.process(self.input.ptr, ctx, tmp);

        const delay_samples = @as(usize, @intFromFloat(self.delay_time * ctx.sample_rate));
        const buffer_len = self.buffer.len;

        std.debug.assert(delay_samples < buffer_len);

        for (out, tmp) |*o, dry| {
            // read from buffer
            const read_pos = if (self.write_pos >= delay_samples)
                self.write_pos - delay_samples
            else
                buffer_len - (delay_samples - self.write_pos);

            const delayed = self.buffer[read_pos];

            self.buffer[self.write_pos] = dry + (delayed * self.feedback); // Write to buffer (input + feedback)
            o.* = dry * (1.0 - self.mix) + delayed * self.mix; // mix
            self.write_pos = (self.write_pos + 1) % buffer_len; // advance
        }
    }

    pub fn asNode(self: *Delay) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
};

pub const Adsr = struct {
    pub const Params = struct {
        attack: f32,
        decay: f32,
        sustain: f32,
        release: f32,
    };

    pub const Stage = enum { Idle, Attack, Decay, Sustain, Release };

    value: f32 = 0.0,
    stage: Stage = .Idle,

    input: Node,
    params: Params,
    vt: VTable = .{ .process = Adsr._process },

    pub fn init(input: Node, params: Params) Adsr {
        return .{
            .input = input,
            .params = params,
        };
    }
    pub fn asNode(self: *Adsr) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
    pub fn noteOn(self: *Adsr) void {
        self.stage = .Attack;
    }
    pub fn noteOff(self: *Adsr) void {
        if (self.stage != .Idle) {
            self.stage = .Release;
        }
    }
    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        const self: *Adsr = @ptrCast(@alignCast(p));

        // short circuit dfs if idle
        if (self.stage == .Idle) {
            @memset(out, 0);
            return;
        }

        const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
        self.input.v.process(self.input.ptr, ctx, tmp);

        const sr = ctx.sample_rate;
        for (out, tmp) |*o, x| {
            switch (self.stage) {
                .Idle => self.value = 0.0,
                .Attack => {
                    self.value += 1.0 / (self.params.attack * sr);
                    if (self.value >= 1.0) {
                        self.value = 1.0;
                        self.stage = .Decay;
                    }
                },
                .Decay => {
                    self.value -= (1.0 - self.params.sustain) / (self.params.decay * sr);
                    if (self.value <= self.params.sustain) {
                        self.value = self.params.sustain;
                        self.stage = .Sustain;
                    }
                },
                .Sustain => {}, // hold
                .Release => {
                    self.value -= self.params.sustain / (self.params.release * sr);
                    if (self.value <= 0.0) {
                        self.value = 0.0;
                        self.stage = .Idle;
                    }
                },
            }
            o.* = x * self.value;
        }
    }
};
