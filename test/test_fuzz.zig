const std = @import("std");
const rl = @import("raylib");
const app = @import("main");
const c = app.c;

const interface = app.interface;
const project = app.project;
const midi = app.midi;

const poll_keys = [_]rl.KeyboardKey{
    .a,             .b,         .c,         .d,          .e,          .f,           .g,            .h,             .i,        .j,         .k,          .l,           .m,
    .n,             .o,         .p,         .q,          .r,          .s,           .t,            .u,             .v,        .w,         .x,          .y,           .z,
    .zero,          .one,       .two,       .three,      .four,       .five,        .six,          .seven,         .eight,    .nine,      .escape,     .grave,       .minus,
    .equal,         .backspace, .tab,       .caps_lock,  .left_shift, .right_shift, .left_control, .right_control, .left_alt, .right_alt, .left_super, .right_super, .left_bracket,
    .right_bracket, .backslash, .semicolon, .apostrophe, .enter,      .comma,       .period,       .slash,         .space,    .up,        .down,       .left,        .right,
    .delete,
};

pub fn main() !void {
    const A = app.A;
    const tempo: f32 = 120;
    const SR = app.SAMPLE_RATE;

    const notes = [_]midi.Note{
        .{ .start = midi.beatsToFrames(0.0, tempo, SR), .end = midi.beatsToFrames(0.9, tempo, SR), .note = 60 },
        .{ .start = midi.beatsToFrames(1.0, tempo, SR), .end = midi.beatsToFrames(1.9, tempo, SR), .note = 60 },
        .{ .start = midi.beatsToFrames(2.0, tempo, SR), .end = midi.beatsToFrames(2.9, tempo, SR), .note = 67 },
        .{ .start = midi.beatsToFrames(3.0, tempo, SR), .end = midi.beatsToFrames(3.9, tempo, SR), .note = 67 },
    };

    app.g_app = try project.App.init(A, &app.g_playhead, &app.context);
    app.g_app.timeline.addTrack(try project.Track.init(A, &app.g_app.timeline.active_track, &notes));
    app.g_app.timeline.addTrack(try project.Track.init(A, &app.g_app.timeline.active_track, &.{}));
    defer app.g_app.deinit();
    app.root = app.g_app.timeline.asNode();
    defer app.g_record_buffer.deinit(A);

    const audio_thread = try std.Thread.spawn(.{}, app.audioThreadMain, .{});
    defer {
        app.g_run_audio.store(false, .release);
        if (app.g_sio_ptr.load(.acquire)) |p| c.soundio_wakeup(p);
        audio_thread.join();
    }

    try interface.init();
    defer interface.deinit();

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    const NUM_EVENTS = 100_000;
    std.debug.print("fuzz: sending {d} random events...\n", .{NUM_EVENTS});

    for (0..NUM_EVENTS) |i| {
        const key = poll_keys[rand.intRangeAtMost(usize, 0, poll_keys.len - 1)];
        const event_type: interface.EventType = if (rand.boolean()) .key_press else .key_release;
        const ev = interface.Event{ .type = event_type, .key = key };

        const action = app.g_app.handleEvent(ev);

        if (action) |ac| {
            switch (ac) {
                .op => |o| while (!app.g_op_queue.push(o)) {},
                else => {},
            }
        }

        // drain garbage periodically
        if (i % 1000 == 0) {
            while (app.g_garbage_queue.pop()) |item| {
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

    while (app.g_garbage_queue.pop()) |item| {
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
