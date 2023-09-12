const builtin = @import("builtin");
const std = @import("std");
const net = std.net;
const mem = std.mem;
const io = std.io;
const os = std.os;

const client = @import("client.zig");
const create_unbuffered_client = client.create_unbuffered_client;
const UnbufferedClient = client.UnbufferedClient;

const common = @import("../common.zig");
const Opcode = common.Opcode;
const UnbufferedMessage = common.UnbufferedMessage;

pub const UnbufferedConnection = struct {
    /// general types
    const Self = @This();
    const WsClient = UnbufferedClient(net.Stream.Reader, net.Stream.Writer);

    underlying_stream: net.Stream,
    ws_client: WsClient,

    pub fn init(
        underlying_stream: net.Stream,
        uri: std.Uri,
        request_headers: ?[]const [2][]const u8,
    ) !Self {
        var new_client = create_unbuffered_client(
            underlying_stream.handle,
            underlying_stream.reader(),
            underlying_stream.writer(),
        );

        var self = UnbufferedConnection
        {
            .underlying_stream = underlying_stream,
            .ws_client = new_client,
        };

        try self.ws_client.handshake(uri, request_headers);
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.underlying_stream.close();
    }

    /// Send a WebSocket message to the server.
    /// The `opcode` field can be text, binary, ping, pong or close.
    /// In order to send continuation frames or streaming messages, check out `stream` function.
    pub fn send(self: *Self, opcode: Opcode, data: []const u8) !void {
        return self.ws_client.send(opcode, data);
    }

    /// Send a ping message to the server.
    pub fn ping(self: *Self) !void {
        return self.send(.ping, "");
    }

    /// Send a pong message to the server.
    pub fn pong(self: *Self) !void {
        return self.send(.pong, "");
    }

    /// Send a close message to the server.
    pub fn close(self: *Self) !void {
        return self.ws_client.close();
    }

    /// TODO: Add usage example
    /// Send send continuation frames or streaming messages to the server.
    pub fn stream(self: *Self, opcode: Opcode, payload: ?[]const u8) !void {
        return self.ws_client.stream(opcode, payload);
    }

    /// Recommend against using this method directly, but it is exposed for
    /// completeness.
    ///
    /// A `max_msg_length` of 0 disables message length limits
    ///
    /// If `timeout_nano_seconds` is greater than `0`, and no data is read
    /// in the timeout period, then `std.net.Stream.ReadError.WouldBlock`
    /// is returned. This is equivalent to a Posix `EAGAIN` or `EWOULDBLOCK`
    /// error.
    pub fn recieveRaw(
        self: *Self,
        out_stream: ?*io.FixedBufferStream([]u8),
        writer: anytype,
        max_msg_length: u64,
        timeout_nano_seconds: u64,
    ) !UnbufferedMessage {
        return self.ws_client.recieveRaw(out_stream, writer, max_msg_length, timeout_nano_seconds);
    }

    /// Receive the next message from the network stream. Incomplete
    /// messages sent from the server will be written into the writer until
    /// the server finishes delivering all parts.
    ///
    /// A `max_msg_length` of 0 disables message length limits
    ///
    /// If `timeout_nano_seconds` is greater than `0`, and no data is read
    /// in the timeout period, then `std.net.Stream.ReadError.WouldBlock`
    /// is returned. This is equivalent to a Posix `EAGAIN` or `EWOULDBLOCK`
    /// error.
    pub fn receiveIntoWriter(
        self: *Self,
        writer: anytype,
        max_msg_length: u64,
        timeout_nano_seconds: u64,
    ) !UnbufferedMessage {
        return self.ws_client.receiveIntoWriter(writer, max_msg_length, timeout_nano_seconds);
    }

    /// Receive the next message from the network stream. Incomplete
    /// messages sent from the server will be written into the stream until
    /// the server finishes delivering all parts.
    ///
    /// If `timeout_nano_seconds` is greater than `0`, and no data is read
    /// in the timeout period, then `std.net.Stream.ReadError.WouldBlock`
    /// is returned. This is equivalent to a Posix `EAGAIN` or `EWOULDBLOCK`
    /// error.
    pub fn receiveIntoStream(
        self: *Self,
        out_stream: *io.FixedBufferStream([]u8),
        timeout_nano_seconds: u64,
    ) !UnbufferedMessage {
        return self.ws_client.receiveIntoStream(out_stream, timeout_nano_seconds);
    }

    /// Receive the next message from the network stream. Incomplete
    /// messages sent from the server will be written into the buffer until
    /// the server finishes delivering all parts.
    ///
    /// If `timeout_nano_seconds` is greater than `0`, and no data is read
    /// in the timeout period, then `std.net.Stream.ReadError.WouldBlock`
    /// is returned. This is equivalent to a Posix `EAGAIN` or `EWOULDBLOCK`
    /// error.
    pub fn receiveIntoBuffer(self: *Self, out_buf: []u8, timeout_nano_seconds: u64) !UnbufferedMessage {
        return self.ws_client.receiveIntoBuffer(out_buf, timeout_nano_seconds);
    }

    /// Receive the next message from the stream. Incomplete messages sent
    /// from the server will be returned as they are received.
    ///
    /// A `max_msg_length` of 0 disables message length limits
    ///
    /// If `timeout_nano_seconds` is greater than `0`, and no data is read
    /// in the timeout period, then `std.net.Stream.ReadError.WouldBlock`
    /// is returned. This is equivalent to a Posix `EAGAIN` or `EWOULDBLOCK`
    /// error.
    pub fn receiveUnbuffered(self: *Self, max_msg_length: u64, timeout_nano_seconds: u64) !UnbufferedMessage {
        return self.ws_client.receiveUnbuffered(max_msg_length, timeout_nano_seconds);
    }
};
