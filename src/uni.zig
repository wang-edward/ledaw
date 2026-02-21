const std = @import("std");
const audio = @import("audio.zig");

const NoteState = union(enum) {
    Off,
    On: u8,
};

const Voice = struct {
    osc_state: audio.Osc.State,
    lpf_state: audio.Lpf.State,
    adsr_state: audio.Adsr.State,

    osc: audio.Osc,
    lpf: audio.Lpf,
    adsr: audio.Adsr,

    noteState: NoteState = .Off,

    pub fn init(alloc: std.mem.Allocator, freq: f32) !*Voice {
        const v = try alloc.create(Voice);
        v.osc_state = .{};
        v.lpf_state = .{};
        v.adsr_state = .{};
        v.osc = audio.Osc.init(freq, .{ .saw = .{} }, &v.osc_state);
        v.lpf = audio.Lpf.init(v.osc.asNode(), 1.0, 0.5, 5000.0, &v.lpf_state);
        v.adsr = audio.Adsr.init(v.lpf.asNode(), .{ .attack = 0.01, .decay = 0.1, .sustain = 0.4, .release = 0.6 }, &v.adsr_state);
        v.noteState = .Off;
        return v;
    }
    pub fn deinit(self: *Voice, alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
    pub fn asNode(self: *Voice) audio.Node {
        return self.adsr.asNode();
    }
    pub fn setNoteOn(self: *Voice, note: u8) void {
        self.noteState = .{ .On = note };
        const freq = noteToFreq(note);
        self.osc.resetPhase();
        self.osc.freq = freq;
        self.adsr.noteOn();
    }
    pub fn setNoteOff(self: *Voice, note: u8) void {
        switch (self.noteState) {
            .On => |on| if (on == note) {
                self.noteState = .Off;
                self.adsr.noteOff();
            },
            else => {},
        }
    }
    pub fn setLpfCutoff(self: *Voice, cutoff: f32) void {
        self.lpf.cutoff = cutoff;
    }
};

pub const Uni = struct {
    cutoff: f32 = 5000.0,
    voices: []*Voice,
    vt: audio.VTable = .{ .process = Uni._process },
    next_idx: usize = 0,
    const SYNTH_TUNING: f32 = 440.0;

    pub fn init(alloc: std.mem.Allocator, count: usize) !*Uni {
        const s = try alloc.create(Uni);
        s.cutoff = 5000.0;
        s.vt = .{ .process = Uni._process };
        s.voices = try alloc.alloc(*Voice, count);
        for (s.voices) |*v| v.* = try Voice.init(alloc, 0.0);
        s.next_idx = 0;
        return s;
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
                .Off => return v,
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
                .On => |note| v.setNoteOff(note),
                .Off => {},
            }
        }
    }
    fn _process(p: *anyopaque, ctx: *audio.Context, out: []audio.Sample) void {
        const self: *Uni = @ptrCast(@alignCast(p));
        @memset(out, 0);
        for (self.voices) |v| {
            v.lpf.cutoff = self.cutoff;
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
