const builtin = @import("builtin");
const std = @import("std");
const net = std.net;
const mem = std.mem;
const io = std.io;

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
        var new_client = create_unbuffered_client(underlying_stream.reader(), underlying_stream.writer());

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

    /// Set read timeout in milliseconds
    pub fn setReadTimeout(self: *Self, durationMilliseconds: u32) !void {
        if (builtin.os.tag == .windows) @compileError("Connection.setReadTimeout unsupported on Windows");
        if (durationMilliseconds == 0) return;

        if (builtin.os.tag == .windows) {
            // This implementation should work on Windows per microsoft's docs
            // as far as I can tell, but zig removed it from the std as it
            // didn't work, and zig-network failed to get it to work as well.
            // https://github.com/MasterQ32/zig-network/pull/49#issuecomment-1312793075
            try std.os.setsockopt(
                self.underlying_stream.handle,
                std.os.SOL.SOCKET,
                std.os.SO.RCVTIMEO,
                std.mem.asBytes(&durationMilliseconds)
            );
        } else {
            const timeout = std.os.timeval{
                .tv_sec = @intCast(@divTrunc(durationMilliseconds, std.time.ms_per_s)),
                .tv_usec = @intCast(@mod(durationMilliseconds, std.time.ms_per_s) * std.time.us_per_ms),
            };
            try std.os.setsockopt(
                self.underlying_stream.handle,
                std.os.SOL.SOCKET,
                std.os.SO.RCVTIMEO,
                std.mem.toBytes(timeout)[0..]
            );
        }
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

    // Recommend against using this method directly, but it is exposed for
    // completeness.
    pub fn recieveRaw(
        self: *Self,
        out_stream: ?*std.io.FixedBufferStream([]u8),
        writer: anytype,
        max_msg_length: u64,
    ) !UnbufferedMessage {
        return self.ws_client.recieveRaw(out_stream, writer, max_msg_length);
    }

    /// Receive the next message from the network stream. Incomplete
    /// messages sent from the server will be written into the writer until
    /// the server finishes delivering all parts.
    /// A `max_msg_length` of 0 disables message length limits
    pub fn receiveIntoWriter(self: *Self, writer: anytype, max_msg_length: u64) !UnbufferedMessage {
        return self.ws_client.receiveIntoWriter(writer, max_msg_length);
    }

    /// Receive the next message from the network stream. Incomplete
    /// messages sent from the server will be written into the stream until
    /// the server finishes delivering all parts.
    pub fn receiveIntoStream(self: *Self, out_stream: ?std.io.FixedBufferStream([]u8)) !UnbufferedMessage {
        return self.ws_client.receiveIntoStream(out_stream);
    }

    /// Receive the next message from the network stream. Incomplete
    /// messages sent from the server will be written into the buffer until
    /// the server finishes delivering all parts.
    pub fn receiveIntoBuffer(self: *Self, out_buf: []u8) !UnbufferedMessage {
        return self.ws_client.receiveIntoBuffer(out_buf);
    }

    /// Receive the next message from the stream. Incomplete messages sent
    /// from the server will be returned as they are received.
    /// A `max_msg_length` of 0 disables message length limits
    pub fn receiveUnbuffered(self: *Self, max_msg_length: u64) !UnbufferedMessage {
        return self.ws_client.receiveUnbuffered(max_msg_length);
    }
};
