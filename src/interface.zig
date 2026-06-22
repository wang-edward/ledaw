const std = @import("std");
const rl = @import("raylib");
const Ssd1351 = @import("oled").Ssd1351;
const config = @import("config");

pub const WIDTH = 128;
pub const HEIGHT = 128;

var target: rl.RenderTexture2D = undefined;
var oled: Ssd1351 = undefined;

pub fn init() !void {
    // rl.setConfigFlags(.{ .window_resizable = true }); // commented because it looks weird with aerospace window manager
    rl.initWindow(512, 512, "LeDaw");
    oled = Ssd1351.init();

    target = try rl.loadRenderTexture(WIDTH, HEIGHT);
    rl.setTargetFPS(60);
    rl.setExitKey(.null); // ESC doesn't close program
}

pub fn deinit() void {
    rl.unloadRenderTexture(target);
    rl.closeWindow();

    oled.deinit();
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

    if (config.hw) {
        // copy target texture to oled
        const image = rl.loadImageFromTexture(target.texture);
        defer rl.unloadImage(image);
        const rgb8888: [*]const u8 = @ptrCast(image.data);
        var fb = rgb8888_to_rgb565(rgb8888);
        oled.show(&fb);
    } else {
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
}

// ---------------------------------------
// utility stuff
// ---------------------------------------

fn rgb8888_to_rgb565(px: []const u8) []u16 {
    var ans: [WIDTH * HEIGHT]u16 = undefined;
    var y: usize = 0;
    while (y < HEIGHT) : (y += 1) {
        const src_y = HEIGHT - 1 - y; // flip: GL bottom-origin -> OLED top-origin
        var x: usize = 0;
        while (x < WIDTH) : (x += 1) {
            const i = (src_y * WIDTH + x) * 4;
            const r = px[i];
            const g = px[i + 1];
            const b = px[i + 2];
            ans[y * WIDTH + x] = (@as(u16, r >> 3) << 11) | (@as(u16, g >> 2) << 5) | (b >> 3);
        }
    }
    return ans;
}

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
