const std = @import("std");


/// maximum control frame length
pub const MAX_CTL_FRAME_LENGTH = 125;

/// The max length accepted/sent by common HTTP servers, although the the
/// specification mandates no specific limit, this is the max commonly used in
/// practice.
pub const MAX_HTTP_HEADER_LENGTH = 16384;

pub fn timeval_from_ns(timeout_nano_seconds: ?u64) std.os.timeval
{
    return if (timeout_nano_seconds) |tout| block: {
        const secs = @divFloor(tout, std.time.ns_per_s);
        const usecs = @divFloor(tout - secs * std.time.ns_per_s, 1000);
        break :block .{ .tv_sec = @intCast(secs), .tv_usec = @intCast(usecs) };
    } else .{ .tv_sec = 0, .tv_usec = 0 };
}

pub const Opcode = enum (u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    // this one is custom for this implementation.
    // see how it's used in sender.zig.
    end = 0xF,
    _,
};

pub const Header = packed struct {
    len: u64,
    opcode: Opcode,
    fin: bool,
    rsv1: bool = false,
    rsv2: bool = false,
    rsv3: bool = false,

    pub const Error = error{MaskedMessageFromServer};
};

pub const Message = struct {
    type: Opcode,
    data: []const u8,
    code: ?u16, // only used in close messages

    pub const Error = error{FragmentedMessage, UnknownOpcode};

    /// Create a WebSocket message from given fields.
    pub fn from(opcode: Opcode, data: []const u8, code: ?u16) Message.Error!Message {
        switch (opcode) {
            .text, .binary,
            .ping, .pong,
            .close => {},

            .continuation => return error.FragmentedMessage,
            else => return error.UnknownOpcode,
        }

        return Message{ .type = opcode, .data = data, .code = code };
    }
};

pub const UnbufferedData = union(enum) {
    slice: []const u8,
    reader: struct {
        message_complete: bool,
        message_reader: std.io.LimitedReader(std.net.Stream.Reader)
    },
    written: u64,
};

pub const UnbufferedMessage = struct {
    type: Opcode,
    data: UnbufferedData,
    code: ?u16, // only used in close messages

    pub const Error = error{FragmentedMessage, UnknownOpcode};

    /// Create a WebSocket message from given fields.
    pub fn from(
        opcode: Opcode,
        data: UnbufferedData,
        code: ?u16,
    ) UnbufferedMessage.Error!UnbufferedMessage {

        switch (opcode) {
            .text, .binary,
            .ping, .pong,
            .close => {},

            .continuation => return error.FragmentedMessage,
            else => return error.UnknownOpcode,
        }

        return UnbufferedMessage{
            .type = opcode,
            .data = data,
            .code = code,
        };
    }
};
