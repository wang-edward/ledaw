const std = @import("std");
const rl = @import("raylib");

pub const WIDTH = 128;
pub const HEIGHT = 128;

var target: rl.RenderTexture2D = undefined;

pub fn init() !void {
    // rl.setConfigFlags(.{ .window_resizable = true }); // commented because it looks weird with aerospace window manager
    rl.initWindow(512, 512, "LeDaw");

    target = try rl.loadRenderTexture(WIDTH, HEIGHT);
    rl.setTargetFPS(60);
    rl.setExitKey(.null); // ESC doesn't close program
}

pub fn deinit() void {
    rl.unloadRenderTexture(target);
    rl.closeWindow();
}

pub fn preRender() void {
    rl.beginTextureMode(target);
    rl.clearBackground(rl.Color.black);
}

pub fn postRender() void {
    const screen_width = rl.getScreenWidth();
    const screen_height = rl.getScreenHeight();
    const square_len = @min(screen_width, screen_height);
    const pos_x: f32 = @floatFromInt(@divTrunc(screen_width - square_len, 2));
    const pos_y: f32 = @floatFromInt(@divTrunc(screen_height - square_len, 2));
    const square_len_f: f32 = @floatFromInt(square_len);

    rl.endTextureMode();
    rl.beginDrawing();
    defer rl.endDrawing();

    // render the 128x128 square
    rl.drawTexturePro(
        target.texture,
        rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(target.texture.width),
            .height = -@as(f32, @floatFromInt(target.texture.height)), // flip Y
        },
        rl.Rectangle{
            .x = pos_x,
            .y = pos_y,
            .width = square_len_f,
            .height = square_len_f,
        },
        rl.Vector2{ .x = 0, .y = 0 },
        0.0,
        rl.Color.white,
    );
}

pub fn shouldClose() bool {
    return rl.windowShouldClose();
}

pub const EventType = enum {
    key_press,
    key_release,
};

pub const Event = struct {
    type: EventType,
    key: rl.KeyboardKey,
};

const poll_keys = [_]rl.KeyboardKey{
    .a,             .b,         .c,         .d,          .e,          .f,           .g,            .h,             .i,        .j,         .k,          .l,           .m,
    .n,             .o,         .p,         .q,          .r,          .s,           .t,            .u,             .v,        .w,         .x,          .y,           .z,
    .zero,          .one,       .two,       .three,      .four,       .five,        .six,          .seven,         .eight,    .nine,      .escape,     .grave,       .minus,
    .equal,         .backspace, .tab,       .caps_lock,  .left_shift, .right_shift, .left_control, .right_control, .left_alt, .right_alt, .left_super, .right_super, .left_bracket,
    .right_bracket, .backslash, .semicolon, .apostrophe, .enter,      .comma,       .period,       .slash,         .space,    .up,        .down,       .left,        .right,
    .delete,
};

var poll_index: usize = 0;
var poll_phase: enum { press, release } = .press;

pub fn nextEvent() ?Event {
    while (true) {
        if (poll_phase == .press) {
            while (poll_index < poll_keys.len) {
                const key = poll_keys[poll_index];
                poll_index += 1;
                if (rl.isKeyPressed(key)) {
                    return .{ .type = .key_press, .key = key };
                }
            }
            poll_index = 0;
            poll_phase = .release;
        }
        if (poll_phase == .release) {
            while (poll_index < poll_keys.len) {
                const key = poll_keys[poll_index];
                poll_index += 1;
                if (rl.isKeyReleased(key)) {
                    return .{ .type = .key_release, .key = key };
                }
            }
            poll_index = 0;
            poll_phase = .press;
            return null;
        }
    }
}
