const std = @import("std");
const rl = @import("raylib");

pub const WIDTH = 128;
pub const HEIGHT = 128;

var target: rl.RenderTexture2D = undefined;
var ocr_target: rl.RenderTexture2D = undefined;
var dual_mode: bool = false;

pub fn init() !void {
    // rl.setConfigFlags(.{ .window_resizable = true }); // commented because it looks weird with aerospace window manager
    rl.initWindow(512, 512, "LeDaw");

    target = try rl.loadRenderTexture(WIDTH, HEIGHT);
    rl.setTargetFPS(60);
    rl.setExitKey(.null); // ESC doesn't close program
}

pub fn initDual() !void {
    rl.initWindow(1024, 512, "LeDaw Art");
    target = try rl.loadRenderTexture(WIDTH, HEIGHT);
    ocr_target = try rl.loadRenderTexture(WIDTH, HEIGHT);
    dual_mode = true;
    rl.setTargetFPS(60);
    rl.setExitKey(.null);
}

pub fn deinit() void {
    rl.unloadRenderTexture(target);
    if (dual_mode) rl.unloadRenderTexture(ocr_target);
    rl.closeWindow();
}

pub fn preRender() void {
    rl.beginTextureMode(target);
    rl.clearBackground(rl.Color.black);
}

pub fn preRenderOcr() void {
    rl.endTextureMode();
    rl.beginTextureMode(ocr_target);
    rl.clearBackground(rl.Color.black);
}

pub fn postRender() void {
    const screen_width = rl.getScreenWidth();
    const screen_height = rl.getScreenHeight();

    rl.endTextureMode();
    rl.beginDrawing();
    defer rl.endDrawing();
    rl.clearBackground(rl.Color.black);

    if (dual_mode) {
        const half_width = @divTrunc(screen_width, 2);
        const square_len = @min(half_width, screen_height);
        const square_len_f: f32 = @floatFromInt(square_len);

        // left: DAW
        const left_x: f32 = @floatFromInt(@divTrunc(half_width - square_len, 2));
        const left_y: f32 = @floatFromInt(@divTrunc(screen_height - square_len, 2));
        drawSquare(target.texture, left_x, left_y, square_len_f);

        // right: OCR boxes
        const right_x: f32 = @as(f32, @floatFromInt(half_width)) + left_x;
        const right_y: f32 = left_y;
        drawSquare(ocr_target.texture, right_x, right_y, square_len_f);
    } else {
        const square_len = @min(screen_width, screen_height);
        const pos_x: f32 = @floatFromInt(@divTrunc(screen_width - square_len, 2));
        const pos_y: f32 = @floatFromInt(@divTrunc(screen_height - square_len, 2));
        const square_len_f: f32 = @floatFromInt(square_len);
        drawSquare(target.texture, pos_x, pos_y, square_len_f);
    }
}

fn drawSquare(texture: rl.Texture2D, x: f32, y: f32, size: f32) void {
    rl.drawTexturePro(
        texture,
        rl.Rectangle{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(texture.width),
            .height = -@as(f32, @floatFromInt(texture.height)), // flip Y
        },
        rl.Rectangle{
            .x = x,
            .y = y,
            .width = size,
            .height = size,
        },
        rl.Vector2{ .x = 0, .y = 0 },
        0.0,
        rl.Color.white,
    );
}

// ---------------------------------------
// utility stuff
// ---------------------------------------

pub fn drawTextCentered(text: [:0]const u8, center_x: i32, center_y: i32, font_size: i32, color: rl.Color) void {
    const text_width = rl.measureText(text, font_size);
    rl.drawText(text, center_x - @divTrunc(text_width, 2), center_y - @divTrunc(font_size, 2), font_size, color);
}

pub fn toString(comptime T: type, value: T) [20:0]u8 {
    var buf: [20:0]u8 = .{0} ** 20;
    _ = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    return buf;
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

pub const poll_keys = [_]rl.KeyboardKey{
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
