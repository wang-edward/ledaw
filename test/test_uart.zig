const std = @import("std");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

const disable_flags: c.tcflag_t =
    @as(c.tcflag_t, c.CSTOPB) |
    @as(c.tcflag_t, c.PARENB) |
    @as(c.tcflag_t, c.CRTSCTS);

const enable_flags: c.tcflag_t =
    @as(c.tcflag_t, c.CLOCAL) |
    @as(c.tcflag_t, c.CREAD);

pub fn main() !void {
    const fd = c.open("/dev/ttyAMA4", c.O_RDONLY | c.O_NOCTTY);
    if (fd < 0) return error.CouldNotOpenUart;
    defer _ = c.close(fd);

    var tty: c.struct_termios = undefined;
    if (c.tcgetattr(fd, &tty) != 0)
        return error.CouldNotReadSettings;

    c.cfmakeraw(&tty);

    _ = c.cfsetispeed(&tty, c.B115200);
    _ = c.cfsetospeed(&tty, c.B115200);

    tty.c_cflag &= ~disable_flags;
    tty.c_cflag |= enable_flags;

    tty.c_cc[c.VMIN] = 1;
    tty.c_cc[c.VTIME] = 0;

    if (c.tcsetattr(fd, c.TCSANOW, &tty) != 0)
        return error.CouldNotApplySettings;

    var buffer: [256]u8 = undefined;

    while (true) {
        const count = c.read(fd, &buffer, buffer.len);

        if (count < 0)
            return error.UartReadFailed;

        if (count > 0) {
            const bytes: usize = @intCast(count);
            _ = c.write(c.STDOUT_FILENO, &buffer, bytes);
        }
    }
}
