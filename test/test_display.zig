// Waveshare 1.5" RGB OLED (SSD1351, 128x128) driver — CM4 + IO board, Linux user-space.
//
// Wiring (Waveshare 7-pin -> 40-pin header, BCM):
//     VCC -> 3V3,  GND -> GND
//     DIN -> GPIO10 (MOSI),  CLK -> GPIO11 (SCLK),  CS -> GPIO8 (CE0)
//     DC  -> GPIO25,  RST -> GPIO27
//
// Build: zig build-exe oled.zig
// Run:   sudo ./oled   (or add user to spi+gpio groups)

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

// ---- hardware config ----
const SPI_DEV = "/dev/spidev0.0";
const GPIO_CHIP = "/dev/gpiochip0";
const DC_LINE: u32 = 25;
const RST_LINE: u32 = 27;
const SPI_HZ: u32 = 10_000_000;
const SPI_MODE: u8 = 0b11; // mode 3, matches Waveshare config.py

const WIDTH: u32 = 128;
const HEIGHT: u32 = 128;
const FB_BYTES: usize = WIDTH * HEIGHT * 2; // RGB565 BE

// ============================================================================
// Linux ioctl constants
// ============================================================================

// from <linux/spi/spidev.h>
const SPI_IOC_WR_MODE: u32 = 0x40016b01;
const SPI_IOC_WR_MAX_SPEED_HZ: u32 = 0x40046b04;

// from <linux/gpio.h>  (gpio v2 chardev — required on Bookworm)
const GPIO_V2_LINE_FLAG_OUTPUT: u64 = 1 << 1;
const GPIO_V2_GET_LINE_IOCTL: u32 = 0xc250b407;
const GPIO_V2_LINE_SET_VALUES_IOCTL: u32 = 0xc010b40f;

const gpio_v2_line_attribute = extern struct {
    id: u32,
    padding: u32,
    value: u64,
};
const gpio_v2_line_config_attribute = extern struct {
    attr: gpio_v2_line_attribute,
    mask: u64,
};
const gpio_v2_line_config = extern struct {
    flags: u64,
    num_attrs: u32,
    padding: [5]u32,
    attrs: [10]gpio_v2_line_config_attribute,
};
const gpio_v2_line_request = extern struct {
    offsets: [64]u32,
    consumer: [32]u8,
    config: gpio_v2_line_config,
    num_lines: u32,
    event_buffer_size: u32,
    padding: [5]u32,
    fd: i32,
};
const gpio_v2_line_values = extern struct { bits: u64, mask: u64 };

fn checkIoctl(rc: usize, comptime ctx: []const u8) !void {
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        else => |e| {
            std.log.err("{s}: errno {}", .{ ctx, e });
            return error.IoctlFailed;
        },
    }
}

// ============================================================================
// SPI (write-only)
// ============================================================================
const Spi = struct {
    fd: posix.fd_t,

    fn open(path: []const u8, mode: u8, hz: u32) !Spi {
        const fd = try posix.open(path, .{ .ACCMODE = .RDWR }, 0);
        errdefer posix.close(fd);

        var m = mode;
        try checkIoctl(linux.ioctl(fd, SPI_IOC_WR_MODE, @intFromPtr(&m)), "SPI set mode");
        var s = hz;
        try checkIoctl(linux.ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, @intFromPtr(&s)), "SPI set speed");
        return .{ .fd = fd };
    }

    fn writeAll(self: Spi, data: []const u8) !void {
        // spidev default bufsiz=4096; chunk for portability.
        const CHUNK: usize = 4096;
        var i: usize = 0;
        while (i < data.len) : (i += CHUNK) {
            const end = @min(i + CHUNK, data.len);
            _ = try posix.write(self.fd, data[i..end]);
        }
    }

    fn close(self: Spi) void {
        posix.close(self.fd);
    }
};

// ============================================================================
// GPIO (single output line via gpiochip v2)
// ============================================================================
const Gpio = struct {
    line_fd: posix.fd_t,

    fn open(chip_path: []const u8, line: u32) !Gpio {
        const chip_fd = try posix.open(chip_path, .{ .ACCMODE = .RDWR }, 0);
        defer posix.close(chip_fd);

        var req = std.mem.zeroes(gpio_v2_line_request);
        req.offsets[0] = line;
        req.num_lines = 1;
        req.config.flags = GPIO_V2_LINE_FLAG_OUTPUT;
        const tag = "ssd1351";
        @memcpy(req.consumer[0..tag.len], tag);

        try checkIoctl(linux.ioctl(chip_fd, GPIO_V2_GET_LINE_IOCTL, @intFromPtr(&req)), "GPIO get line");
        return .{ .line_fd = req.fd };
    }

    fn write(self: Gpio, high: bool) !void {
        const v = gpio_v2_line_values{ .bits = if (high) 1 else 0, .mask = 1 };
        try checkIoctl(linux.ioctl(self.line_fd, GPIO_V2_LINE_SET_VALUES_IOCTL, @intFromPtr(&v)), "GPIO set value");
    }

    fn close(self: Gpio) void {
        posix.close(self.line_fd);
    }
};

// ============================================================================
// SSD1351 driver
// ============================================================================
const Ssd1351 = struct {
    spi: Spi,
    dc: Gpio,
    rst: Gpio,

    fn init() !Ssd1351 {
        const self = Ssd1351{
            .spi = try Spi.open(SPI_DEV, SPI_MODE, SPI_HZ),
            .dc = try Gpio.open(GPIO_CHIP, DC_LINE),
            .rst = try Gpio.open(GPIO_CHIP, RST_LINE),
        };
        try self.reset();
        try self.initPanel();
        return self;
    }

    fn deinit(self: Ssd1351) void {
        self.cmd(0xAE) catch {};
        self.spi.close();
        self.dc.close();
        self.rst.close();
    }

    fn reset(self: Ssd1351) !void {
        try self.rst.write(true);
        std.Thread.sleep(100 * std.time.ns_per_ms);
        try self.rst.write(false);
        std.Thread.sleep(100 * std.time.ns_per_ms);
        try self.rst.write(true);
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    fn cmd(self: Ssd1351, c: u8) !void {
        try self.dc.write(false);
        try self.spi.writeAll(&[_]u8{c});
    }
    fn data(self: Ssd1351, d: u8) !void {
        try self.dc.write(true);
        try self.spi.writeAll(&[_]u8{d});
    }
    fn dataBulk(self: Ssd1351, buf: []const u8) !void {
        try self.dc.write(true);
        try self.spi.writeAll(buf);
    }

    // Mirrors Waveshare's official init, with 0xAB fix (their driver mistakenly
    // sends 0x01 as a command instead of a data byte).
    fn initPanel(self: Ssd1351) !void {
        try self.cmd(0xFD);
        try self.data(0x12); // unlock
        try self.cmd(0xFD);
        try self.data(0xB1); // unlock advanced
        try self.cmd(0xAE); // display off
        try self.cmd(0xA4); // normal display

        try self.cmd(0x15);
        try self.data(0x00);
        try self.data(0x7F); // col 0..127
        try self.cmd(0x75);
        try self.data(0x00);
        try self.data(0x7F); // row 0..127

        try self.cmd(0xB3);
        try self.data(0xF1); // clock div
        try self.cmd(0xCA);
        try self.data(0x7F); // mux 1/128
        try self.cmd(0xA0);
        try self.data(0x74); // remap: 65k, BGR, COM split, h-incr
        try self.cmd(0xA1);
        try self.data(0x00); // start line
        try self.cmd(0xA2);
        try self.data(0x00); // offset
        try self.cmd(0xAB);
        try self.data(0x01); // function select: internal Vdd regulator
        try self.cmd(0xB4);
        try self.data(0xA0);
        try self.data(0xB5);
        try self.data(0x55);
        try self.cmd(0xC1);
        try self.data(0xC8);
        try self.data(0x80);
        try self.data(0xC0);
        try self.cmd(0xC7);
        try self.data(0x0F); // master contrast
        try self.cmd(0xB1);
        try self.data(0x32); // precharge
        try self.cmd(0xB2);
        try self.data(0xA4);
        try self.data(0x00);
        try self.data(0x00);
        try self.cmd(0xBB);
        try self.data(0x17);
        try self.cmd(0xB6);
        try self.data(0x01);
        try self.cmd(0xBE);
        try self.data(0x05);
        try self.cmd(0xA6); // normal display

        std.Thread.sleep(100 * std.time.ns_per_ms);
        try self.cmd(0xAF); // display on
    }

    fn setWindow(self: Ssd1351) !void {
        try self.cmd(0x15);
        try self.data(0x00);
        try self.data(0x7F);
        try self.cmd(0x75);
        try self.data(0x00);
        try self.data(0x7F);
        try self.cmd(0x5C); // write RAM
    }

    /// Push a 128*128*2 byte RGB565 BE framebuffer to the panel.
    fn show(self: Ssd1351, fb: []const u8) !void {
        std.debug.assert(fb.len == FB_BYTES);
        try self.setWindow();
        try self.dataBulk(fb);
    }

    fn fill(self: Ssd1351, r: u8, g: u8, b: u8) !void {
        var fb: [FB_BYTES]u8 = undefined;
        const hi: u8 = (r & 0xF8) | (g >> 5);
        const lo: u8 = ((g << 3) & 0xE0) | (b >> 3);
        var i: usize = 0;
        while (i < fb.len) : (i += 2) {
            fb[i] = hi;
            fb[i + 1] = lo;
        }
        try self.show(&fb);
    }
};

// ============================================================================
// demo
// ============================================================================
pub fn main() !void {
    var oled = try Ssd1351.init();
    defer oled.deinit();

    const colors = [_][3]u8{
        .{ 0xFF, 0x00, 0x00 },
        .{ 0x00, 0xFF, 0x00 },
        .{ 0x00, 0x00, 0xFF },
        .{ 0xFF, 0xFF, 0xFF },
    };
    for (colors) |c| {
        try oled.fill(c[0], c[1], c[2]);
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }

    // 8 horizontal color bars
    var fb: [FB_BYTES]u8 = undefined;
    const bars = [_][3]u8{
        .{ 0xFF, 0x00, 0x00 }, .{ 0xFF, 0x80, 0x00 },
        .{ 0xFF, 0xFF, 0x00 }, .{ 0x00, 0xFF, 0x00 },
        .{ 0x00, 0xFF, 0xFF }, .{ 0x00, 0x00, 0xFF },
        .{ 0x80, 0x00, 0xFF }, .{ 0xFF, 0xFF, 0xFF },
    };
    const bar_h = HEIGHT / bars.len;
    for (0..HEIGHT) |y| {
        const idx = @min(y / bar_h, bars.len - 1);
        const c = bars[idx];
        const hi: u8 = (c[0] & 0xF8) | (c[1] >> 5);
        const lo: u8 = ((c[1] << 3) & 0xE0) | (c[2] >> 3);
        for (0..WIDTH) |x| {
            const off = (y * WIDTH + x) * 2;
            fb[off] = hi;
            fb[off + 1] = lo;
        }
    }
    try oled.show(&fb);
    std.Thread.sleep(3 * std.time.ns_per_s);
}
