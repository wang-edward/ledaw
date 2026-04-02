const std = @import("std");
const audio = @import("audio.zig");

const NoteState = union(enum) {
    off,
    on: u8,
};

const Voice = struct {
    osc: audio.Osc,
    lpf: audio.Lpf,
    adsr: audio.Adsr,

    noteState: NoteState = .off,

    pub fn init(alloc: std.mem.Allocator, freq: f32) !*Voice {
        const v = try alloc.create(Voice);
        v.osc = audio.Osc.init(freq, .{ .saw = .{} });
        v.lpf = audio.Lpf.init(v.osc.asNode());
        v.adsr = audio.Adsr.init(v.lpf.asNode());
        v.noteState = .off;
        return v;
    }
    pub fn deinit(self: *Voice, alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
    pub fn asNode(self: *Voice) audio.Node {
        return self.adsr.asNode();
    }
    pub fn setNoteOn(self: *Voice, note: u8) void {
        self.noteState = .{ .on = note };
        const freq = noteToFreq(note);
        self.osc.resetPhase();
        self.osc.freq = freq;
        self.adsr.noteOn();
    }
    pub fn setNoteOff(self: *Voice, note: u8) void {
        switch (self.noteState) {
            .on => |on| if (on == note) {
                self.noteState = .off;
                self.adsr.noteOff();
            },
            else => {},
        }
    }
    pub fn setLpfCutoff(self: *Voice, cutoff: f32) void {
        self.lpf.cutoff.set(cutoff);
    }
};

pub const Uni = struct {
    cutoff: f32 = 5000.0, // TODO Param-ify?
    voices: []*Voice,
    vt: audio.VTable = .{ .process = Uni._process },
    next_idx: usize = 0,

    // synth params (applied to all voices)
    waveform: audio.Param, // 0=sine, 1=pwm, 2=saw, 3=sub
    attack: audio.Param,
    decay: audio.Param,
    release: audio.Param,

    const SYNTH_TUNING: f32 = 440.0;
    const NUM_VOICES = 16;

    pub fn init(alloc: std.mem.Allocator) !*Uni {
        const s = try alloc.create(Uni);
        s.cutoff = 5000.0;
        s.vt = .{ .process = Uni._process };
        s.voices = try alloc.alloc(*Voice, NUM_VOICES);
        for (s.voices) |*v| v.* = try Voice.init(alloc, 0.0);
        s.next_idx = 0;
        s.waveform = .{ .val = 2, .min = 0, .max = 3 }; // default saw
        s.attack = .{ .val = 0.01, .min = 0.001, .max = 1.0 };
        s.decay = .{ .val = 0.1, .min = 0.001, .max = 1.0 };
        s.release = .{ .val = 0.6, .min = 0.01, .max = 2.0 };
        return s;
    }

    pub fn applyParams(self: *Uni) void {
        const wf: u8 = @intFromFloat(@round(self.waveform.get()));
        const kind: audio.Osc.Kind = switch (wf) {
            0 => .{ .sine = .{} },
            1 => .{ .pwm = .{} },
            2 => .{ .saw = .{} },
            else => .{ .sub = .{} },
        };
        for (self.voices) |v| {
            v.osc.kind = kind;
            v.adsr.attack = self.attack.get();
            v.adsr.decay = self.decay.get();
            v.adsr.sustain = 1.0;
            v.adsr.release = self.release.get();
        }
    }
    pub fn deinit(self: *Uni, alloc: std.mem.Allocator) void {
        for (self.voices) |v| v.deinit(alloc);
        alloc.free(self.voices);
        alloc.destroy(self);
    }
    pub fn asNode(self: *Uni) audio.Node {
        return .{ .ptr = self, .v = &self.vt };
    }
    fn findFreeVoice(self: *Uni) ?*Voice {
        for (self.voices) |v| {
            switch (v.noteState) {
                .off => return v,
                else => {},
            }
        }
        return null;
    }
    pub fn noteOn(self: *Uni, note: u8) void {
        const freeVoice = findFreeVoice(self);
        if (freeVoice) |v| {
            v.setNoteOn(note);
        } else {
            const idx = self.next_idx;
            self.next_idx = (self.next_idx + 1) % self.voices.len;
            self.voices[idx].setNoteOn(note);
        }
    }
    pub fn noteOff(self: *Uni, note: u8) void {
        for (self.voices) |v| v.setNoteOff(note);
    }
    pub fn allNotesOff(self: *Uni) void {
        for (self.voices) |v| {
            switch (v.noteState) {
                .on => |note| v.setNoteOff(note),
                .off => {},
            }
        }
    }
    fn _process(p: *anyopaque, ctx: *audio.Context, out: []audio.Sample) void {
        const self: *Uni = @ptrCast(@alignCast(p));
        self.applyParams();
        @memset(out, 0);
        for (self.voices) |v| {
            v.lpf.cutoff.set(self.cutoff);
            const tmp = ctx.tmp().alloc(audio.Sample, out.len) catch unreachable;
            const node = v.asNode();
            node.v.process(node.ptr, ctx, tmp);
            for (out, tmp) |*o, t| o.* += t;
        }
    }
};

fn noteToFreq(note: u8) f32 {
    const semitone_offset = @as(f32, @floatFromInt(@as(i16, @intCast(note)) - 69));
    return Uni.SYNTH_TUNING * std.math.exp2(semitone_offset / 12.0);
}
