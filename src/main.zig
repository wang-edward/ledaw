const std = @import("std");
const rl = @import("raylib");
pub const c = @cImport(@cInclude("soundio/soundio.h"));
pub const audio = @import("audio.zig");
pub const midi = @import("midi.zig");
pub const ops = @import("ops.zig");
pub const interface = @import("interface.zig");
pub const project = @import("project.zig");
pub const plugin = @import("plugin.zig");

pub var g_playhead: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_playing: bool = false;
pub var g_recording: bool = false;
pub var g_app: project.App = undefined;
pub var g_op_queue: ops.OpQueue = .{};

// Recording state
pub var g_held_notes: [128]?midi.Frame = .{null} ** 128; // note -> start frame
pub var g_record_buffer: std.ArrayListUnmanaged(midi.Note) = .{};

// Garbage queue: audio thread pushes removed items, UI thread frees them
pub var g_garbage_queue: ops.GarbageQueue = .{};

inline fn getActiveTrack() ?*project.Track {
    const tl = &g_app.timeline;
    if (tl.track_count == 0) return null;
    if (tl.active_track >= tl.track_count) return null;
    return tl.tracks[tl.active_track];
}

pub var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const A = gpa.allocator();

// temp allocator for audio callback
pub var scratch_mem: [512 * 1024]u8 = undefined;
pub var scratch_fba = std.heap.FixedBufferAllocator.init(&scratch_mem);
pub var context: audio.Context = undefined;

pub var root: audio.Node = undefined;

// libsoundio
var sio: ?*c.SoundIo = null;
var out: ?*c.SoundIoOutStream = null;

// shared sio pointer to allow main to kill sio
pub var g_sio_ptr = std.atomic.Value(?*c.SoundIo).init(null);

// run flag for audio thread
pub var g_run_audio = std.atomic.Value(bool).init(true);

pub const SAMPLE_RATE: f32 = 48_000;

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

        // process Ops (before notes, so track list is up-to-date)
        while (g_op_queue.pop()) |op| {
            switch (op) {
                .playback => |p| switch (p) {
                    .toggle_play => {
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
                    .reset => {
                        for (g_app.timeline.activeTracks()) |t| {
                            t.synth.allNotesOff();
                        }
                        g_playhead.store(0, .monotonic);
                    },
                },
                .record => |r| switch (r) {
                    .toggle_record => |track_idx| {
                        if (g_recording) {
                            if (g_record_buffer.items.len > 0 and track_idx < g_app.timeline.trackCount()) {
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
                .graph => |g| switch (g) {
                    .add_track => |track| {
                        g_app.timeline.addTrack(track);
                    },
                    .remove_track => |idx| {
                        if (idx < g_app.timeline.trackCount()) {
                            const removed = g_app.timeline.removeTrack(idx);
                            removed.synth.allNotesOff();
                            _ = g_garbage_queue.push(.{ .track = removed });
                        }
                    },
                    .add_plugin => |ap| {
                        const tracks = g_app.timeline.activeTracks();
                        std.debug.print("add_plugin: track_idx={d} tracks.len={d}\n,", .{ ap.track_idx, tracks.len });
                        if (ap.track_idx < tracks.len) {
                            tracks[ap.track_idx].addPlugin(ap.plugin);
                        }
                    },
                },
            }
        }

        // process notes (after ops so track list is current)
        while (g_app.note_queue.pop()) |msg| {
            switch (msg) {
                .off => |note| {
                    const track = getActiveTrack() orelse continue;
                    track.synth.noteOff(note);
                    if (g_recording and g_playing) {
                        if (g_held_notes[note]) |start| {
                            g_record_buffer.append(A, .{
                                .start = start,
                                .end = g_playhead.raw,
                                .note = note,
                            }) catch {};
                            g_held_notes[note] = null;
                        }
                    }
                },
                .on => |note| {
                    const track = getActiveTrack() orelse continue;
                    track.synth.noteOn(note);
                    if (g_recording and g_playing) {
                        g_held_notes[note] = g_playhead.raw;
                    }
                },
            }
        }

        // render one block (mono) from the graph
        context.beginBlock();
        const mono = context.tmp().alloc(audio.Sample, @intCast(frame_count)) catch unreachable;
        root.v.process(root.ptr, &context, mono);

        for (mono[0..@intCast(frame_count)]) |s| {
            if (!std.math.isFinite(s)) {
                std.debug.print("NaN/inf detected\n", .{});
                @panic("NaN/inf detected");
            }
        }

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
            const start = g_playhead.raw;
            _ = g_playhead.fetchAdd(@intCast(frame_count), .monotonic);

            for (g_app.timeline.activeTracks()) |track| {
                const n = track.player.advance(start, g_playhead.raw, &midi_notes);
                for (midi_notes[0..n]) |msg| {
                    switch (msg) {
                        .off => |note| track.synth.noteOff(note),
                        .on => |note| track.synth.noteOn(note),
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
pub fn audioThreadMain() !void {
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
    out.?.*.sample_rate = @intFromFloat(SAMPLE_RATE);
    out.?.*.software_latency = 0.02;
    must(c.soundio_outstream_open(out.?));

    std.debug.assert(out.?.*.sample_rate == SAMPLE_RATE); // assert write succeeded
    context = audio.Context.init(scratch_fba.allocator(), SAMPLE_RATE, 120);

    must(c.soundio_outstream_start(out.?));

    while (g_run_audio.load(.acquire)) {
        c.soundio_wait_events(sio);
    }

    // close outstream before g_timeline.deinit(). this prevents audio callbacks from running when there's nothing to fill the buffer
    // defer doesn't work in this case because the notes depend on context.sr
    // TODO can be fixed by creating g_timeline first and then appending notes instead of doing it in place like this
    if (out) |p| c.soundio_outstream_destroy(p);
    out = null;
}

pub fn main() !void {
    defer _ = gpa.deinit();

    // Init app on main thread (before audio thread starts)
    const tempo: f32 = 120;
    const notes = [_]midi.Note{
        .{ .start = midi.beatsToFrames(0.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(0.9, tempo, SAMPLE_RATE), .note = 60 },
        .{ .start = midi.beatsToFrames(1.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(1.9, tempo, SAMPLE_RATE), .note = 60 },
        .{ .start = midi.beatsToFrames(2.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(2.9, tempo, SAMPLE_RATE), .note = 67 },
        .{ .start = midi.beatsToFrames(3.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(3.9, tempo, SAMPLE_RATE), .note = 67 },
        .{ .start = midi.beatsToFrames(4.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(4.9, tempo, SAMPLE_RATE), .note = 69 },
        .{ .start = midi.beatsToFrames(5.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(5.9, tempo, SAMPLE_RATE), .note = 69 },
        .{ .start = midi.beatsToFrames(6.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(7.9, tempo, SAMPLE_RATE), .note = 67 },
        .{ .start = midi.beatsToFrames(8.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(8.9, tempo, SAMPLE_RATE), .note = 65 },
        .{ .start = midi.beatsToFrames(9.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(9.9, tempo, SAMPLE_RATE), .note = 65 },
        .{ .start = midi.beatsToFrames(10.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(10.9, tempo, SAMPLE_RATE), .note = 64 },
        .{ .start = midi.beatsToFrames(11.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(11.9, tempo, SAMPLE_RATE), .note = 64 },
        .{ .start = midi.beatsToFrames(12.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(12.9, tempo, SAMPLE_RATE), .note = 62 },
        .{ .start = midi.beatsToFrames(13.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(13.9, tempo, SAMPLE_RATE), .note = 62 },
        .{ .start = midi.beatsToFrames(14.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(15.9, tempo, SAMPLE_RATE), .note = 60 },
    };
    const bass_notes = [_]midi.Note{
        .{ .start = midi.beatsToFrames(0.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(2.0, tempo, SAMPLE_RATE), .note = 48 },
        .{ .start = midi.beatsToFrames(2.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(4.0, tempo, SAMPLE_RATE), .note = 48 },
        .{ .start = midi.beatsToFrames(4.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(6.0, tempo, SAMPLE_RATE), .note = 43 },
        .{ .start = midi.beatsToFrames(6.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(8.0, tempo, SAMPLE_RATE), .note = 43 },
        .{ .start = midi.beatsToFrames(8.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(10.0, tempo, SAMPLE_RATE), .note = 41 },
        .{ .start = midi.beatsToFrames(10.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(12.0, tempo, SAMPLE_RATE), .note = 40 },
        .{ .start = midi.beatsToFrames(12.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(14.0, tempo, SAMPLE_RATE), .note = 38 },
        .{ .start = midi.beatsToFrames(14.0, tempo, SAMPLE_RATE), .end = midi.beatsToFrames(16.0, tempo, SAMPLE_RATE), .note = 36 },
    };

    g_app = try project.App.init(A, &g_playhead, &context);
    g_app.timeline.addTrack(try project.Track.init(A, &g_app.timeline.active_track, &notes));
    g_app.timeline.addTrack(try project.Track.init(A, &g_app.timeline.active_track, &bass_notes));
    defer g_app.deinit();
    root = g_app.timeline.asNode();
    defer g_record_buffer.deinit(A);

    var audio_thread = try std.Thread.spawn(.{}, audioThreadMain, .{});
    defer {
        g_run_audio.store(false, .release);
        if (g_sio_ptr.load(.acquire)) |p| c.soundio_wakeup(p);
        audio_thread.join();
    }

    try interface.init();
    defer interface.deinit();

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

        // draw UI
        interface.preRender();
        defer interface.postRender();
        {
            g_app.render();
        }
    }
}
