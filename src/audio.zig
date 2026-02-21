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
    pub const State = struct {
        phase: f32 = 0,
    };

    pub const Kind = union(enum) {
        sine: struct {},
        pwm: struct { duty: f32 = 0.5 },
        saw: struct {},
        sub: struct { duty: f32 = 0.5, offset: f32 = -12 },
    };

    freq: f32,
    kind: Kind,
    state: *State,
    vt: VTable = .{ .process = Osc._process },

    pub fn init(freq: f32, kind: Kind, state: *State) Osc {
        return .{ .freq = freq, .kind = kind, .state = state };
    }
    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        const self: *Osc = @ptrCast(@alignCast(p));
        const st = self.state;
        const base_inc = self.freq / ctx.sample_rate;
        const inc = switch (self.kind) {
            .sub => |sub| base_inc * std.math.exp2(sub.offset / 12.0),
            else => base_inc,
        };
        for (0..out.len) |i| {
            const sample: Sample = switch (self.kind) {
                .sine => std.math.sin(st.phase * 2.0 * std.math.pi),
                .pwm => |pwm| if (st.phase < pwm.duty) 1.0 else -1.0,
                .saw => 2.0 * st.phase - 1.0,
                .sub => |sub| if (st.phase < sub.duty) 1.0 else -1.0,
            };
            out[i] = @floatCast(sample);
            st.phase += inc;
            while (st.phase >= 1.0) st.phase -= 1.0;
        }
    }
    pub fn asNode(self: *Osc) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
    pub fn resetPhase(self: *Osc) void {
        self.state.phase = 0.0;
    }
};

pub const Lpf = struct {
    // References: "An Improved Virtual Analog Model of the Moog Ladder Filter"
    // Original Implementation: D'Angelo, Valimaki
    pub const THERMAL_VOLTAGE = 0.312;

    pub const State = struct {
        V: [4]f32 = .{ 0, 0, 0, 0 },
        dV: [4]f32 = .{ 0, 0, 0, 0 },
        tV: [4]f32 = .{ 0, 0, 0, 0 },
    };

    input: Node,
    drive: f32,
    resonance: f32,
    cutoff: f32,
    state: *State,
    vt: VTable = .{ .process = Lpf._process },

    pub fn init(input: Node, drive: f32, resonance: f32, cutoff: f32, state: *State) Lpf {
        return .{ .input = input, .drive = drive, .resonance = resonance, .cutoff = cutoff, .state = state };
    }
    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        const self: *Lpf = @ptrCast(@alignCast(p));
        const in = ctx.tmp().alloc(Sample, out.len) catch unreachable;
        self.input.v.process(self.input.ptr, ctx, in);

        const st = self.state;
        const x = (std.math.pi * self.cutoff) / ctx.sample_rate;
        const g = 4.0 * std.math.pi * THERMAL_VOLTAGE * self.cutoff * (1.0 - x) / (1.0 + x);
        for (0..out.len) |i| {
            const dV0 = -g * (std.math.tanh((self.drive * in[i] + self.resonance * st.V[3] / (2.0 * THERMAL_VOLTAGE)) + st.tV[0]));
            st.V[0] += (dV0 + st.dV[0]) / (2.0 * ctx.sample_rate);
            st.dV[0] = dV0;
            st.tV[0] = std.math.tanh(st.V[0] / (2.0 * THERMAL_VOLTAGE));

            const dV1 = g * (st.tV[0] - st.tV[1]);
            st.V[1] += (dV1 + st.dV[1]) / (2.0 * ctx.sample_rate);
            st.dV[1] = dV1;
            st.tV[1] = std.math.tanh(st.V[1] / (2.0 * THERMAL_VOLTAGE));

            const dV2 = g * (st.tV[1] - st.tV[2]);
            st.V[2] += (dV2 + st.dV[2]) / (2.0 * ctx.sample_rate);
            st.dV[2] = dV2;
            st.tV[2] = std.math.tanh(st.V[2] / (2.0 * THERMAL_VOLTAGE));

            const dV3 = g * (st.tV[2] - st.tV[3]);
            st.V[3] += (dV3 + st.dV[3]) / (2.0 * ctx.sample_rate);
            st.dV[3] = dV3;
            st.tV[3] = std.math.tanh(st.V[3] / (2.0 * THERMAL_VOLTAGE));

            out[i] = st.V[3];
        }
    }
    pub fn asNode(self: *Lpf) Node {
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

    pub const State = struct {
        value: f32 = 0.0,
        stage: Stage = .Idle,

        pub fn noteOn(self: *State) void {
            self.stage = .Attack;
        }
        pub fn noteOff(self: *State) void {
            if (self.stage != .Idle) {
                self.stage = .Release;
            }
        }
    };

    input: Node,
    params: Params,
    state: *State,
    vt: VTable = .{ .process = Adsr._process },

    pub fn init(input: Node, params: Params, state: *State) Adsr {
        return .{
            .input = input,
            .params = params,
            .state = state,
        };
    }
    pub fn asNode(self: *Adsr) Node {
        return .{ .ptr = self, .v = &self.vt };
    }
    pub fn noteOn(self: *Adsr) void {
        self.state.noteOn();
    }
    pub fn noteOff(self: *Adsr) void {
        self.state.noteOff();
    }
    fn _process(p: *anyopaque, ctx: *Context, out: []Sample) void {
        const self: *Adsr = @ptrCast(@alignCast(p));
        const st = self.state;

        // short circuit dfs if idle
        if (st.stage == .Idle) {
            @memset(out, 0);
            return;
        }

        const tmp = ctx.tmp().alloc(Sample, out.len) catch unreachable;
        self.input.v.process(self.input.ptr, ctx, tmp);

        const sr = ctx.sample_rate;
        for (out, tmp) |*o, x| {
            switch (st.stage) {
                .Idle => st.value = 0.0,
                .Attack => {
                    st.value += 1.0 / (self.params.attack * sr);
                    if (st.value >= 1.0) {
                        st.value = 1.0;
                        st.stage = .Decay;
                    }
                },
                .Decay => {
                    st.value -= (1.0 - self.params.sustain) / (self.params.decay * sr);
                    if (st.value <= self.params.sustain) {
                        st.value = self.params.sustain;
                        st.stage = .Sustain;
                    }
                },
                .Sustain => {}, // hold
                .Release => {
                    st.value -= self.params.sustain / (self.params.release * sr);
                    if (st.value <= 0.0) {
                        st.value = 0.0;
                        st.stage = .Idle;
                    }
                },
            }
            o.* = x * st.value;
        }
    }
};
