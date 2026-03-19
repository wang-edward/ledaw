const std = @import("std");
const rl = @import("raylib");
const ledaw = @import("main");
const c = ledaw.c;

const interface = ledaw.interface;
const project = ledaw.project;
const midi = ledaw.midi;

pub fn main() !void {
    const A = ledaw.A;
    const tempo: f32 = 120;
    const SR = ledaw.SAMPLE_RATE;

    const notes = [_]midi.Note{
        .{ .start = midi.beatsToFrames(0.0, tempo, SR), .end = midi.beatsToFrames(0.9, tempo, SR), .note = 60 },
        .{ .start = midi.beatsToFrames(1.0, tempo, SR), .end = midi.beatsToFrames(1.9, tempo, SR), .note = 60 },
        .{ .start = midi.beatsToFrames(2.0, tempo, SR), .end = midi.beatsToFrames(2.9, tempo, SR), .note = 67 },
        .{ .start = midi.beatsToFrames(3.0, tempo, SR), .end = midi.beatsToFrames(3.9, tempo, SR), .note = 67 },
    };

    ledaw.g_app = try project.App.init(A, &ledaw.g_playhead, &ledaw.context);
    ledaw.g_app.timeline.addTrack(try project.Track.init(A, &ledaw.g_app.timeline.active_track, &notes));
    ledaw.g_app.timeline.addTrack(try project.Track.init(A, &ledaw.g_app.timeline.active_track, &.{}));
    defer ledaw.g_app.deinit();
    ledaw.root = ledaw.g_app.timeline.asNode();
    defer ledaw.g_record_buffer.deinit(A);

    const audio_thread = try std.Thread.spawn(.{}, ledaw.audioThreadMain, .{});
    defer {
        ledaw.g_run_audio.store(false, .release);
        if (ledaw.g_sio_ptr.load(.acquire)) |p| c.soundio_wakeup(p);
        audio_thread.join();
    }

    try interface.init();
    defer interface.deinit();

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    const NUM_EVENTS = 100_000;
    std.debug.print("fuzz: sending {d} random events...\n", .{NUM_EVENTS});

    for (0..NUM_EVENTS) |i| {
        const key = interface.poll_keys[rand.intRangeAtMost(usize, 0, interface.poll_keys.len - 1)];
        const event_type: interface.EventType = if (rand.boolean()) .key_press else .key_release;
        const ev = interface.Event{ .type = event_type, .key = key };

        const action = ledaw.g_app.handleEvent(ev);

        if (action) |ac| {
            switch (ac) {
                .op => |o| while (!ledaw.g_op_queue.push(o)) {},
                else => {},
            }
        }

        // drain garbage periodically
        if (i % 1000 == 0) {
            while (ledaw.g_garbage_queue.pop()) |item| {
                switch (item) {
                    .plugin => |p| p.deinit(A),
                    .track => |t| {
                        t.deinit(A);
                        A.destroy(t);
                    },
                }
            }
        }
    }

    while (ledaw.g_garbage_queue.pop()) |item| {
        switch (item) {
            .plugin => |p| p.deinit(A),
            .track => |t| {
                t.deinit(A);
                A.destroy(t);
            },
        }
    }

    std.debug.print("fuzz: completed {d} events without crash\n", .{NUM_EVENTS});
}
