const builtin = @import("builtin");
const std = @import("std");
const net = std.net;
const mem = std.mem;
const io = std.io;

const Client = @import("client.zig").Client;
const client = @import("client.zig").client;

const common = @import("common.zig");
const Opcode = common.Opcode;
const Message = common.Message;

const READ_BUFFER_SIZE: usize = 1024 * 8;
const WRITE_BUFFER_SIZE: usize = 1024 * 4;

/// This is the direct implementation of ws over regular net.Stream.
/// The Connection object will always use the current Stream implementation of net namespace.
pub const Connection = struct {
    underlying_stream: net.Stream,
    ws_client: *WsClient,
    buffered_reader: *BufferedReader,
    headers: std.StringHashMapUnmanaged([]const u8),
    deinited: bool = false,

    /// general types
    const WsClient = Client(Reader, Writer, READ_BUFFER_SIZE, WRITE_BUFFER_SIZE);
    const BufferedReader = io.BufferedReader(4096, net.Stream.Reader);
    const Reader = BufferedReader.Reader;
    const Writer = net.Stream.Writer;

    pub fn init(
        allocator: mem.Allocator,
        underlying_stream: net.Stream,
        uri: std.Uri,
        request_headers: ?[]const [2][]const u8,
    ) !Connection {
        const buffered_reader = try allocator.create(BufferedReader);
        errdefer allocator.destroy(buffered_reader);

        const ws_client = try allocator.create(WsClient);
        errdefer allocator.destroy(ws_client);

        buffered_reader.* = BufferedReader{ .unbuffered_reader = underlying_stream.reader() };

        ws_client.* = client(
            buffered_reader.reader(),
            underlying_stream.writer(),
            READ_BUFFER_SIZE,
            WRITE_BUFFER_SIZE,
        );

        var self = Connection{
            .underlying_stream = underlying_stream,
            .ws_client = ws_client,
            .buffered_reader = buffered_reader,
            .headers = .{},
        };

        try self.ws_client.handshake(allocator, uri, request_headers, &self.headers);
        return self;
    }

    pub fn deinit(self: *Connection, allocator: mem.Allocator) void {
        if (!self.deinited)
        {
            self.deinited = true;
            defer allocator.destroy(self.buffered_reader);
            defer allocator.destroy(self.ws_client);
            self.ws_client.deinit(allocator, &self.headers);
            self.underlying_stream.close();
        }
    }

    /// Set read timeout in milliseconds
    pub fn setReadTimeout(self: *Connection, durationMilliseconds: u32) !void {
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
    pub fn send(self: Connection, opcode: Opcode, data: []const u8) !void {
        return self.ws_client.send(opcode, data);
    }

    /// Send a ping message to the server.
    pub fn ping(self: Connection) !void {
        return self.send(.ping, "");
    }

    /// Send a pong message to the server.
    pub fn pong(self: Connection) !void {
        return self.send(.pong, "");
    }

    /// Send a close message to the server.
    pub fn close(self: Connection) !void {
        return self.ws_client.close();
    }

    /// TODO: Add usage example
    /// Send send continuation frames or streaming messages to the server.
    pub fn stream(self: Connection, opcode: Opcode, payload: ?[]const u8) !void {
        return self.ws_client.stream(opcode, payload);
    }

    /// Receive a message from the server.
    ///
    /// If a timeout occurs after `setReadTimeout` has been called, the error
    /// `std.net.Stream.ReadError.WouldBlock` is returned on Posix-flavored
    /// systems. This is equivalent to a Posix `EAGAIN` or `EWOULDBLOCK` error.
    ///
    /// Due to API limitations, `setReadTimeout` does not work on Windows.
    pub fn receive(self: Connection) !Message {
        return self.ws_client.receive();
    }
};
