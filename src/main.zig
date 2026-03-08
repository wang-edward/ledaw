const std = @import("std");
const rl = @import("raylib");
const c = @cImport(@cInclude("soundio/soundio.h"));
const audio = @import("audio.zig");
const midi = @import("midi.zig");
const ops = @import("ops.zig");
const interface = @import("interface.zig");
const project = @import("project.zig");
const plugin = @import("plugin.zig");

var g_note_queue: midi.NoteQueue = .{};
var g_playhead: u64 = 0;
var g_playing: bool = false;
var g_recording: bool = false;
var g_app: project.App = undefined;
var g_op_queue: ops.OpQueue = .{};

// Recording state
var g_held_notes: [128]?midi.Frame = .{null} ** 128; // note -> start frame
var g_record_buffer: std.ArrayListUnmanaged(midi.Note) = .{};

// Garbage queue: audio thread pushes removed items, UI thread frees them
var g_garbage_queue: ops.GarbageQueue = .{};

inline fn getActiveTrack() *project.Track {
    return g_app.timeline.activeTrack();
}

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const A = gpa.allocator();

// temp allocator for audio callback
var scratch_mem: [512 * 1024]u8 = undefined;
var scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_mem);
var context: audio.Context = undefined;

var root: audio.Node = undefined;

// libsoundio
var sio: ?*c.SoundIo = null;
var out: ?*c.SoundIoOutStream = null;

// shared sio pointer to allow main to kill sio
var g_sio_ptr = std.atomic.Value(?*c.SoundIo).init(null);

// run flag for audio thread
var g_run_audio = std.atomic.Value(bool).init(true);

fn must(ok: c_int) void {
    if (ok != c.SoundIoErrorNone) @panic("soundio error");
}

fn write_callback(
    maybe_outstream: ?[*]c.SoundIoOutStream,
    _min: c_int,
    max: c_int,
) callconv(.c) void {
    // exit early if program ended
    if (!g_run_audio.load(.acquire)) return;

    _ = _min;
    const outstream: *c.SoundIoOutStream = &maybe_outstream.?[0];
    const layout = &outstream.layout;
    const chans: usize = @intCast(layout.channel_count);

    var frames_left = max;
    var midi_notes: [midi.MAX_NOTES_PER_BLOCK]midi.NoteMsg = undefined;

    // Rebuild the temp arena for this callback
    scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_mem);
    context.arena = std.heap.ArenaAllocator.init(scratch_fba.allocator());

    while (frames_left > 0) {
        var frame_count = frames_left;

        var areas: [*]c.SoundIoChannelArea = undefined;
        must(c.soundio_outstream_begin_write(maybe_outstream, @ptrCast(&areas), &frame_count));
        if (frame_count == 0) break;

        // process note
        while (g_note_queue.pop()) |msg| {
            switch (msg) {
                .Off => |note| {
                    getActiveTrack().synth.noteOff(note);
                    // Record note off
                    if (g_recording and g_playing) {
                        if (g_held_notes[note]) |start| {
                            g_record_buffer.append(A, .{
                                .start = start,
                                .end = g_playhead,
                                .note = note,
                            }) catch {};
                            g_held_notes[note] = null;
                        }
                    }
                },
                .On => |note| {
                    getActiveTrack().synth.noteOn(note);
                    // Record note on
                    if (g_recording and g_playing) {
                        g_held_notes[note] = g_playhead;
                    }
                },
            }
        }

        // process Ops
        while (g_op_queue.pop()) |op| {
            switch (op) {
                .Playback => |p| switch (p) {
                    .TogglePlay => {
                        for (g_app.timeline.activeTracks()) |t| {
                            t.synth.allNotesOff();
                        }
                        if (g_recording and g_playing) {
                            g_recording = false;
                            g_playing = false;
                            g_held_notes = .{null} ** 128;
                            g_record_buffer.clearRetainingCapacity();
                        } else {
                            g_playing = !g_playing;
                        }
                    },
                    .Reset => {
                        for (g_app.timeline.activeTracks()) |t| {
                            t.synth.allNotesOff();
                        }
                        g_playhead = 0;
                    },
                },
                .Record => |r| switch (r) {
                    .ToggleRecord => |track_idx| {
                        if (g_recording) {
                            if (g_record_buffer.items.len > 0) {
                                g_app.timeline.activeTracks()[track_idx].player.appendNotes(
                                    A,
                                    g_record_buffer.items,
                                ) catch {};
                                g_record_buffer.clearRetainingCapacity();
                            }
                            g_held_notes = .{null} ** 128;
                            g_recording = false;
                            if (g_playing) g_playing = false;
                        } else if (!g_playing) {
                            g_playing = true;
                            g_recording = true;
                        } else {
                            g_recording = true;
                        }
                    },
                },
                .Graph => |g| switch (g) {
                    .AddTrack => |track| {
                        g_app.timeline.addTrack(track);
                    },
                    .RemoveTrack => |idx| {
                        if (idx < g_app.timeline.trackCount()) {
                            const removed = g_app.timeline.removeTrack(idx);
                            _ = g_garbage_queue.push(.{ .track = removed });
                        }
                    },
                    .AddPlugin => |ap| {
                        const tracks = g_app.timeline.activeTracks();
                        if (ap.track_idx < tracks.len) {
                            tracks[ap.track_idx].addPlugin(ap.plugin);
                        }
                    },
                    .RemovePluginByTag => |rp| {
                        const tracks = g_app.timeline.activeTracks();
                        if (rp.track_idx < tracks.len) {
                            if (tracks[rp.track_idx].removePluginByTag(rp.tag)) |old| {
                                _ = g_garbage_queue.push(.{ .plugin = old });
                            }
                        }
                    },
                },
            }
        }

        // render one block (mono) from the graph
        context.beginBlock();
        const mono = context.tmp().alloc(audio.Sample, @intCast(frame_count)) catch unreachable;
        root.v.process(root.ptr, &context, mono);

        // copy mono audio to all channels
        var f: c_int = 0;
        while (f < frame_count) : (f += 1) {
            const s = mono[@intCast(f)];
            var ch: usize = 0;
            while (ch < chans) : (ch += 1) {
                const step: usize = @intCast(areas[ch].step);
                const fi: usize = @intCast(f);
                const ptr = areas[ch].ptr + step * fi;
                const sample_ptr: *f32 = @ptrCast(@alignCast(ptr));
                sample_ptr.* = s;
            }
        }

        // advance playhead
        if (g_playing) {
            const start = g_playhead;
            g_playhead += @intCast(frame_count);

            for (g_app.timeline.activeTracks()) |track| {
                const n = track.player.advance(start, g_playhead, &midi_notes);
                for (midi_notes[0..n]) |msg| {
                    switch (msg) {
                        .Off => |note| track.synth.noteOff(note),
                        .On => |note| track.synth.noteOn(note),
                    }
                }
            }
        }

        frames_left -= frame_count;
        must(c.soundio_outstream_end_write(maybe_outstream));
    }
}

fn underflow_callback(_: ?[*]c.SoundIoOutStream) callconv(.c) void {
    unreachable;
}

// =============================== Audio thread entry ==================================
fn audioThreadMain() !void {
    // SoundIO setup
    sio = c.soundio_create();
    if (sio == null) return error.NoMem;
    g_sio_ptr.store(sio, .release);
    defer {
        g_sio_ptr.store(null, .release); // clear
        if (sio) |p| c.soundio_destroy(p);
        sio = null;
    }
    must(c.soundio_connect(sio));
    c.soundio_flush_events(sio);
    const idx = c.soundio_default_output_device_index(sio);
    if (idx < 0) return error.NoOutputDeviceFound;
    const dev = c.soundio_get_output_device(sio, idx) orelse return error.NoMem;
    defer c.soundio_device_unref(dev);
    out = c.soundio_outstream_create(dev) orelse return error.NoMem;
    out.?.*.format = c.SoundIoFormatFloat32NE;
    out.?.*.write_callback = write_callback;
    out.?.*.underflow_callback = underflow_callback;
    // TODO make sample rate setting better
    out.?.*.sample_rate = 48_000;
    out.?.*.software_latency = 0.02;
    must(c.soundio_outstream_open(out.?));

    // Init graph context with chosen sample rate
    const sr: f32 = @floatFromInt(out.?.*.sample_rate);
    const bpm: f32 = 120;
    context = audio.Context.init(scratch_fba.allocator(), sr, bpm);

    must(c.soundio_outstream_start(out.?));

    // lesynth setup
    const tempo: f32 = 120;
    const notes = [_]midi.Note{
        .{ .start = midi.beatsToFrames(0.0, tempo, &context), .end = midi.beatsToFrames(0.9, tempo, &context), .note = 60 },
        .{ .start = midi.beatsToFrames(1.0, tempo, &context), .end = midi.beatsToFrames(1.9, tempo, &context), .note = 60 },
        .{ .start = midi.beatsToFrames(2.0, tempo, &context), .end = midi.beatsToFrames(2.9, tempo, &context), .note = 67 },
        .{ .start = midi.beatsToFrames(3.0, tempo, &context), .end = midi.beatsToFrames(3.9, tempo, &context), .note = 67 },
        .{ .start = midi.beatsToFrames(4.0, tempo, &context), .end = midi.beatsToFrames(4.9, tempo, &context), .note = 69 },
        .{ .start = midi.beatsToFrames(5.0, tempo, &context), .end = midi.beatsToFrames(5.9, tempo, &context), .note = 69 },
        .{ .start = midi.beatsToFrames(6.0, tempo, &context), .end = midi.beatsToFrames(7.9, tempo, &context), .note = 67 },
        .{ .start = midi.beatsToFrames(8.0, tempo, &context), .end = midi.beatsToFrames(8.9, tempo, &context), .note = 65 },
        .{ .start = midi.beatsToFrames(9.0, tempo, &context), .end = midi.beatsToFrames(9.9, tempo, &context), .note = 65 },
        .{ .start = midi.beatsToFrames(10.0, tempo, &context), .end = midi.beatsToFrames(10.9, tempo, &context), .note = 64 },
        .{ .start = midi.beatsToFrames(11.0, tempo, &context), .end = midi.beatsToFrames(11.9, tempo, &context), .note = 64 },
        .{ .start = midi.beatsToFrames(12.0, tempo, &context), .end = midi.beatsToFrames(12.9, tempo, &context), .note = 62 },
        .{ .start = midi.beatsToFrames(13.0, tempo, &context), .end = midi.beatsToFrames(13.9, tempo, &context), .note = 62 },
        .{ .start = midi.beatsToFrames(14.0, tempo, &context), .end = midi.beatsToFrames(15.9, tempo, &context), .note = 60 },
    };
    const bass_notes = [_]midi.Note{
        .{ .start = midi.beatsToFrames(0.0, tempo, &context), .end = midi.beatsToFrames(2.0, tempo, &context), .note = 48 },
        .{ .start = midi.beatsToFrames(2.0, tempo, &context), .end = midi.beatsToFrames(4.0, tempo, &context), .note = 48 },
        .{ .start = midi.beatsToFrames(4.0, tempo, &context), .end = midi.beatsToFrames(6.0, tempo, &context), .note = 43 },
        .{ .start = midi.beatsToFrames(6.0, tempo, &context), .end = midi.beatsToFrames(8.0, tempo, &context), .note = 43 },
        .{ .start = midi.beatsToFrames(8.0, tempo, &context), .end = midi.beatsToFrames(10.0, tempo, &context), .note = 41 },
        .{ .start = midi.beatsToFrames(10.0, tempo, &context), .end = midi.beatsToFrames(12.0, tempo, &context), .note = 40 },
        .{ .start = midi.beatsToFrames(12.0, tempo, &context), .end = midi.beatsToFrames(14.0, tempo, &context), .note = 38 },
        .{ .start = midi.beatsToFrames(14.0, tempo, &context), .end = midi.beatsToFrames(16.0, tempo, &context), .note = 36 },
    };
    const notes_per_track = [_][]const midi.Note{ &notes, &bass_notes };

    g_app = try project.App.init(A, 2, 4, &notes_per_track);
    defer g_app.deinit();
    root = g_app.timeline.asNode();

    defer g_record_buffer.deinit(A);

    while (g_run_audio.load(.acquire)) {
        c.soundio_wait_events(sio);
    }

    // close outstream before g_timeline.deinit(). this prevents audio callbacks from running when there's nothing to fill the buffer
    // defer doesn't work in this case because the notes depend on context.sr
    // TODO can be fixed by creating g_timeline first and then appending notes instead of doing it in place like this
    if (out) |p| c.soundio_outstream_destroy(p);
    out = null;
}

fn keyToMidi(key: rl.KeyboardKey) ?u8 {
    return switch (key) {
        // --- white keys (A–L) ---
        .a => 48, // C3
        .s => 50, // D3
        .d => 52, // E3
        .f => 53, // F3
        .g => 55, // G3
        .h => 57, // A3
        .j => 59, // B3
        .k => 60, // C4
        .l => 62, // D4
        .semicolon => 64, // E4
        .apostrophe => 65, // F4

        // --- black keys (W–O) ---
        .w => 49, // C#3
        .e => 51, // D#3
        .t => 54, // F#3
        .y => 56, // G#3
        .u => 58, // A#3
        .o => 61, // C#4
        .p => 63, // D#4
        else => null,
    };
}

pub fn main() !void {
    defer _ = gpa.deinit();

    var audio_thread = try std.Thread.spawn(.{}, audioThreadMain, .{});
    defer {
        g_run_audio.store(false, .release);
        if (g_sio_ptr.load(.acquire)) |p| c.soundio_wakeup(p);
        audio_thread.join();
    }

    try interface.init();
    defer interface.deinit();
    const note_keys = [_]rl.KeyboardKey{
        .a, .w, .s, .e, .d,         .f,          .t, .g, .y, .h, .u, .j,
        .k, .o, .l, .p, .semicolon, .apostrophe,
    };

    var offset: i8 = 0;
    var key_state = std.AutoHashMap(rl.KeyboardKey, ?u8).init(A);
    defer key_state.deinit();
    for (note_keys) |k| try key_state.put(k, null);

    while (!rl.windowShouldClose()) {
        // poll events and dispatch to current screen
        while (interface.nextEvent()) |ev| {
            std.debug.print("event: {s} {s}\n", .{ @tagName(ev.type), @tagName(ev.key) });

            const action = g_app.handleEvent(ev);

            if (action) |ac| {
                switch (ac) {
                    .op => |o| while (!g_op_queue.push(o)) {},
                    else => {},
                }
            }
        }

        // drain garbage from audio thread
        while (g_garbage_queue.pop()) |item| {
            switch (item) {
                .plugin => |p| p.deinit(A),
                .track => |t| {
                    t.deinit(A);
                    A.destroy(t);
                },
            }
        }

        for (note_keys) |key| {
            const down = rl.isKeyDown(key);
            const active_note = key_state.get(key).?;

            if (down and active_note == null) {
                if (keyToMidi(key)) |base| {
                    const note: u8 = @intCast(@as(i16, base) + @as(i16, offset));
                    while (!g_note_queue.push(.{ .On = note })) {}
                    try key_state.put(key, note);
                }
            } else if (!down and active_note != null) {
                while (!g_note_queue.push(.{ .Off = active_note.? })) {}
                try key_state.put(key, null);
            }
        }

        // octave shift
        if (rl.isKeyPressed(.x)) offset += 12;
        if (rl.isKeyPressed(.z)) offset -= 12;

        // draw UI
        interface.preRender();
        defer interface.postRender();
        {
            g_app.render();
        }
    }
}
