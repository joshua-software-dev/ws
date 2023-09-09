const std = @import("std");
const io = std.io;
const mem = std.mem;

const common = @import("../common.zig");
const UnbufferedMessage = common.UnbufferedMessage;
const Opcode = common.Opcode;

const UnbufferedReceiver = @import("receiver.zig").UnbufferedReceiver;
const UnbufferedSender = @import("sender.zig").UnbufferedSender;

pub fn create_unbuffered_client(
    reader: anytype,
    writer: anytype,
) UnbufferedClient(@TypeOf(reader), @TypeOf(writer)) {
    var mask: [4]u8 = undefined;
    std.crypto.random.bytes(&mask);

    return .{
        .receiver = .{ .reader = reader },
        .sender = .{ .writer = writer, .mask = mask },
    };
}

pub fn UnbufferedClient(
    comptime Reader: type,
    comptime Writer: type,
) type {
    return struct {
        const Self = @This();

        receiver: UnbufferedReceiver(Reader),
        sender: UnbufferedSender(Writer),

        pub fn handshake(
            self: *Self,
            uri: std.Uri,
            request_headers: ?[]const [2][]const u8,
        ) !void {
            // create a random Sec-WebSocket-Key
            var buf: [24]u8 = undefined;
            std.crypto.random.bytes(buf[0..16]);
            const key = std.base64.standard.Encoder.encode(&buf, buf[0..16]);

            try self.sender.sendRequest(uri, request_headers, key);
            const sec_ws_accept = try self.receiver.receiveResponse();

            try checkWebSocketAcceptKey(sec_ws_accept, key);
        }

        const WsAcceptKeyError = error{KeyControlFailed, AcceptKeyNotFound};

        /// Controls the accept key received from the server
        fn checkWebSocketAcceptKey(
            sec_websocket_accept: []const u8,
            key: []const u8,
        ) WsAcceptKeyError!void {
            if (sec_websocket_accept.len < 1) return error.AcceptKeyNotFound;
            const magic_string = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

            var hash_buf: [20]u8 = undefined;
            var h = std.crypto.hash.Sha1.init(.{});
            h.update(key);
            h.update(magic_string);
            h.final(&hash_buf);

            var encoded_hash_buf: [28]u8 = undefined;
            const our_accept = std.base64.standard.Encoder.encode(&encoded_hash_buf, &hash_buf);

            if (!mem.eql(u8, our_accept, sec_websocket_accept))
                return error.KeyControlFailed;
        }

        /// Send a WebSocket message to the server.
        /// The `opcode` field can be text, binary, ping, pong or close.
        /// In order to send continuation frames or streaming messages, check out `stream` function.
        pub fn send(self: *Self, opcode: Opcode, data: []const u8) !void {
            return self.sender.send(opcode, data);
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
            return self.sender.close();
        }

        /// TODO: Add usage example
        /// Send send continuation frames or streaming messages to the server.
        pub fn stream(self: *Self, opcode: Opcode, payload: ?[]const u8) !void {
            return self.sender.stream(opcode, payload);
        }

        // Recommend against using this method directly, but it is exposed for
        // completeness.
        pub fn recieveRaw(
            self: *Self,
            out_stream: ?*io.FixedBufferStream([]u8),
            writer: anytype,
            max_msg_length: u64,
        ) !UnbufferedMessage {
            return self.receiver.receiveRaw(out_stream, writer, max_msg_length);
        }

        /// Receive the next message from the network stream. Incomplete
        /// messages sent from the server will be written into the writer until
        /// the server finishes delivering all parts.
        /// A `max_msg_length` of 0 disables message length limits
        pub fn receiveIntoWriter(self: *Self, writer: anytype, max_msg_length: u64) !UnbufferedMessage {
            return self.receiver.receiveIntoWriter(writer, max_msg_length);
        }

        /// Receive the next message from the network stream. Incomplete
        /// messages sent from the server will be written into the stream until
        /// the server finishes delivering all parts.
        pub fn receiveIntoStream(self: *Self, out_stream: *io.FixedBufferStream([]u8)) !UnbufferedMessage {
            return self.receiver.receiveIntoStream(out_stream);
        }

        /// Receive the next message from the network stream. Incomplete
        /// messages sent from the server will be written into the buffer until
        /// the server finishes delivering all parts.
        pub fn receiveIntoBuffer(self: *Self, out_buf: []u8) !UnbufferedMessage {
            return self.receiver.receiveIntoBuffer(out_buf);
        }

        /// Receive the next message from the stream. Incomplete messages sent
        /// from the server will be returned as they are received.
        /// A `max_msg_length` of 0 disables message length limits
        pub fn receiveUnbuffered(self: *Self, max_msg_length: u64) !UnbufferedMessage {
            return self.receiver.receiveUnbuffered(max_msg_length);
        }
    };
}
