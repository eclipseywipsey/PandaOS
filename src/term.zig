//! Tiny terminal I/O layer built on raw file descriptors.
//! Deliberately avoids std.io reader/writer types, whose API changed
//! between Zig releases, so this file stays stable across versions.

const std = @import("std");
const posix = std.posix;
const out_fd = if (@import("builtin").is_test) posix.STDERR_FILENO else posix.STDOUT_FILENO;

pub const LineError = error{ EndOfStream, LineTooLong };
pub const ReadLineError = LineError || posix.ReadError;

pub fn write(s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) {
        const n = posix.write(out_fd, s[i..]) catch return;
        if (n == 0) return;
        i += n;
    }
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch {
        write("[output truncated]\n");
        return;
    };
    write(s);
}

/// Reads one line into `buf` (newline stripped). If `trim` is set,
/// surrounding spaces/tabs are removed. Over-long lines are drained and
/// reported as error.LineTooLong so the caller can re-prompt cleanly.
pub fn readLineOpts(buf: []u8, trim: bool) ReadLineError![]u8 {
    var len: usize = 0;
    var overflow = false;
    while (true) {
        var c: [1]u8 = undefined;
        const n = try posix.read(posix.STDIN_FILENO, &c);
        if (n == 0) {
            if (len == 0 and !overflow) return error.EndOfStream;
            break;
        }
        if (c[0] == '\n') break;
        if (c[0] == '\r') continue;
        if (len < buf.len) {
            buf[len] = c[0];
            len += 1;
        } else {
            overflow = true;
        }
    }
    if (overflow) {
        std.crypto.secureZero(u8, buf[0..]);
        return error.LineTooLong;
    }
    const line = buf[0..len];
    if (!trim) return line;
    return @constCast(std.mem.trim(u8, line, " \t"));
}

pub fn readLine(buf: []u8) ReadLineError![]u8 {
    return readLineOpts(buf, true);
}

/// Reads a secret with terminal echo disabled (when stdin is a tty).
/// Caller owns `buf` and should wipe it with std.crypto.secureZero.
pub fn readPassword(buf: []u8) ReadLineError![]u8 {
    const fd = posix.STDIN_FILENO;
    const orig: ?posix.termios = posix.tcgetattr(fd) catch null;
    if (orig) |o| {
        var raw = o;
        raw.lflag.ECHO = false;
        posix.tcsetattr(fd, .FLUSH, raw) catch {};
    }
    defer {
        if (orig) |o| posix.tcsetattr(fd, .FLUSH, o) catch {};
    }
    const line = readLineOpts(buf, false);
    write("\n");
    return line;
}
