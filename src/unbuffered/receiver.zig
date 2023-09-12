const builtin = @import("builtin");
const std = @import("std");
const io = std.io;
const mem = std.mem;
const common = @import("../common.zig");
const Opcode = common.Opcode;
const Header = common.Header;
const UnbufferedMessage = common.UnbufferedMessage;
const win_select = if (builtin.os.tag == .windows) @import("../win_select.zig") else null;

const MAX_CTL_FRAME_LENGTH = common.MAX_CTL_FRAME_LENGTH;
// max header size can be 10 * u8,
// if masking is allowed, header size can be up to 14 * u8
// server should not be sending masked messages.
const MAX_HEADER_SIZE = 10;

pub fn UnbufferedReceiver(comptime Reader: type) type {
    return struct {
        const Self = @This();

        handle: std.os.socket_t,
        reader: Reader,
        header_buffer: [MAX_HEADER_SIZE]u8 = undefined,
        fragmentation: Fragmentation = .{},

        const Fragmentation = struct {
            on: bool = false,
            opcode: Opcode = .text,
        };

        /// Scan HTTP headers for first encountered magic "Sec-WebSocket-Accept"
        /// header, does not store any other headers. Perhaps a middle ground
        /// between UnbufferedReceiver's no alloc and BufferedReader's arbitary
        /// alloc can be struck in the future.
        pub fn receiveResponse(self: Self, buf: *std.BoundedArray(u8, common.MAX_HTTP_HEADER_LENGTH)) ![]const u8 {
            var i: usize = 0;
            var state: enum { key, value } = .key;
            var header_is_sec_websocket_accept = false;

            // HTTP/1.1 101 Switching Protocols
            const request_line = try self.reader.readUntilDelimiter(buf.slice(), '\n');
            if (request_line.len < 32) return error.FailedSwitchingProtocols;
            if (!mem.eql(u8, request_line[0..32], "HTTP/1.1 101 Switching Protocols"))
                return error.FailedSwitchingProtocols;

            buf.len = 0;

            while (true) {
                const b = try self.reader.readByte();
                switch (state) {
                    .key => switch (b) {
                        ':' => { // delimiter of key
                            // make sure space comes afterwards
                            if (try self.reader.readByte() == ' ') {
                                if (mem.eql(u8, buf.constSlice(), "Sec-WebSocket-Accept")) {
                                    // not all headers are scanned to see if a duplicate "Sec-WebSocket-Accept" key
                                    // could potentially exist, but since we only need this one header, just let the
                                    // first encountered be the only one.
                                    header_is_sec_websocket_accept = true;
                                }

                                i = 0;
                                state = .value;
                                buf.len = 0;
                            } else {
                                return error.BadHttpResponse;
                            }
                        },
                        '\r' => {
                            if (try self.reader.readByte() == '\n') break;
                            return error.BadHttpResponse;
                        },
                        '\n' => break,

                        else => {
                            buf.append(b) catch return error.HttpHeaderTooLong;
                            i += 1;
                        },
                    },

                    .value => switch (b) {
                        '\r' => {
                            // make sure '\n' comes afterwards
                            if (try self.reader.readByte() == '\n') {
                                if (header_is_sec_websocket_accept) {
                                    // ensure this isn't the last header before the message
                                    const next1 = try self.reader.readByte();
                                    const next2 = try self.reader.readByte();
                                    if (next1 == '\r' and next2 == '\n') {
                                        return buf.constSlice();
                                    }

                                    // skip until we find the characters denoting the beginning of the message
                                    while (true)
                                    {
                                        var end_buf: [4]u8 = undefined;
                                        const amt_read = try self.reader.read(end_buf[0..]);
                                        if (amt_read < 4) return error.BadHttpResponse;
                                        if (mem.eql(u8, &end_buf, "\r\n\r\n")) return buf.constSlice();
                                    }
                                }

                                i = 0;
                                state = .key;
                                buf.len = 0;
                            } else {
                                return error.BadHttpResponse;
                            }
                        },

                        else => {
                            buf.append(b) catch return error.HttpHeaderTooLong;
                            i += 1;
                        },
                    },
                }
            }

            return "";
        }

        fn getHeader(self: *Self) !Header {
            var buf = self.header_buffer[0..2].*;

            const len = try self.reader.readAll(&buf);
            if (len < 2) return error.EndOfStream;

            const is_masked = buf[1] & 0x80 != 0;
            if (is_masked)
                return error.MaskedMessageFromServer; // FIXME: should this be allowed?

            // get length from variable length
            const var_length: u7 = @truncate(buf[1] & 0x7F);
            const length = try self.getLength(var_length);

            const b = buf[0];
            const fin = b & 0x80 != 0;
            const rsv1 = b & 0x40 != 0;
            const rsv2 = b & 0x20 != 0;
            const rsv3 = b & 0x10 != 0;

            const op = b & 0x0F;
            const opcode: Opcode = @enumFromInt(@as(u4, @truncate(op)));

            return Header{
                .len = length,
                .opcode = opcode,
                .fin = fin,
                .rsv1 = rsv1,
                .rsv2 = rsv2,
                .rsv3 = rsv3,
            };
        }

        fn getLength(self: *Self, var_length: u7) !u64 {
            return switch (var_length) {
                126 => {
                    var buf = self.header_buffer[2..4].*;
                    const len = try self.reader.readAll(&buf);
                    if (len < 2) return error.EndOfStream;

                    return @intCast(mem.readIntBig(u16, &buf));
                },

                127 => {
                    var buf = self.header_buffer[2..].*;
                    const len = try self.reader.readAll(&buf);
                    if (len < 8) return error.EndOfStream;

                    return mem.readIntBig(u64, &buf);
                },

                inline else => var_length,
            };
        }

        fn pingPong(self: *Self, header: Header) !UnbufferedMessage {
            if (header.len > MAX_CTL_FRAME_LENGTH)
                return error.PayloadTooBig;

            var buf: [MAX_CTL_FRAME_LENGTH]u8 = undefined;

            const len = try self.reader.readAll(&buf);
            if (len < buf.len)
                return error.EndOfStream;

            return UnbufferedMessage.from(header.opcode, .{ .slice = &buf, } , null);
        }

        fn close(self: *Self, header: Header) !UnbufferedMessage {
            if (header.len > MAX_CTL_FRAME_LENGTH)
                return error.PayloadTooBig;

            var buf: [MAX_CTL_FRAME_LENGTH]u8 = undefined;

            const len = try self.reader.readAll(&buf);
            if (len < buf.len)
                return error.EndOfStream;

            return switch (buf.len) {
                0 => UnbufferedMessage.from(.close, .{ .slice = buf[0..], }, null),

                2 => { // without reason but code
                    const code = mem.readIntBig(u16, buf[0..2]);

                    return UnbufferedMessage.from(.close, .{ .slice = buf[0..], }, code);
                },

                else => { // with reason
                    const code = mem.readIntBig(u16, buf[0..2]);

                    return UnbufferedMessage.from(.close, .{ .slice = buf[2..], }, code);
                }
            };
        }

        // this must be called when continuation frame is received
        fn continuation1(
            self: *Self,
            header: Header,
            stream: ?*io.FixedBufferStream([]u8),
            writer: anytype,
            max_msg_length: u64,
        ) !UnbufferedMessage {
            if (!self.fragmentation.on)
                return error.BadMessageOrder;

            var current_written: u64 = 0;
            var last: Header = header;
            while (true) : (last = try self.getHeader()) {
                switch (last.opcode) {
                    .continuation => {},
                    .text, .binary => return error.BadMessageOrder,
                    .ping, .pong => return self.pingPong(last),
                    .close => return self.close(last),

                    else => return error.UnknownOpcode,
                }

                if (@typeInfo(@TypeOf(writer)) != .Null) {
                    if (max_msg_length > 0 and last.len + current_written > max_msg_length)
                        return error.PayloadTooBig;

                    {
                        var i: u64 = 0;
                        while (i < last.len) : (i += 1) {
                            const byte: u8 = try self.reader.readByte();
                            try writer.writeByte(byte);
                        }
                    }
                    current_written += last.len;

                    if (last.fin) {
                        return UnbufferedMessage.from(
                            self.fragmentation.opcode,
                            if (stream != null)
                                .{ .slice = stream.?.*.getWritten(), }
                            else
                                .{ .written = current_written, },
                            null
                        );
                    }
                    continue;
                }

                return UnbufferedMessage.from(
                    self.fragmentation.opcode,
                    .{
                        .reader = .{
                            .message_complete = last.fin,
                            .message_reader = io.limitedReader(self.reader, last.len),
                        }
                    },
                    null
                );
            }
        }

        // this must be called when text or binary frame without fin is received
        fn continuation(
            self: *Self,
            header: Header,
            stream: ?*io.FixedBufferStream([]u8),
            writer: anytype,
            max_msg_length: u64,
        ) !UnbufferedMessage {
            // keep track of fragmentation
            self.fragmentation.on = true;
            self.fragmentation.opcode = header.opcode;

            var current_written: u64 = 0;
            var last: Header = header;
            // any of the control frames might sneak in to this while loop,
            // beware!
            while (true) : (last = try self.getHeader()) {
                switch (last.opcode) {
                    .text, .binary, .continuation => {},
                    // disturbed
                    .ping, .pong => return self.pingPong(last),
                    .close => return self.close(last),

                    else => return error.UnknownOpcode,
                }

                if (@typeInfo(@TypeOf(writer)) != .Null) {
                    if (max_msg_length > 0 and last.len + current_written > max_msg_length)
                        return error.PayloadTooBig;

                    {
                        var i: u64 = 0;
                        while (i < last.len) : (i += 1) {
                            const byte: u8 = try self.reader.readByte();
                            try writer.writeByte(byte);
                        }
                    }
                    current_written += last.len;

                    if (last.fin) {
                        return UnbufferedMessage.from(
                            self.fragmentation.opcode,
                            if (stream != null)
                                .{ .slice = stream.?.*.getWritten(), }
                            else
                                .{ .written = current_written, },
                            null
                        );
                    }
                    continue;
                }

                return UnbufferedMessage.from(
                    self.fragmentation.opcode,
                    .{
                        .reader = .{
                            .message_complete = last.fin,
                            .message_reader = io.limitedReader(self.reader, last.len),
                        }
                    },
                    null
                );
            }
        }

        fn regular(
            self: Self,
            header: Header,
            stream: ?*io.FixedBufferStream([]u8),
            writer: anytype,
            max_msg_length: u64,
        ) !UnbufferedMessage {
            if (max_msg_length > 0 and header.len > max_msg_length)
                return error.PayloadTooBig;

            if (@typeInfo(@TypeOf(writer)) != .Null) {
                {
                    var i: u64 = 0;
                    while (i < header.len) : (i += 1) {
                        const byte: u8 = try self.reader.readByte();
                        try writer.writeByte(byte);
                    }
                }

                return UnbufferedMessage.from(
                    header.opcode,
                    if (stream == null)
                        .{ .written = header.len, }
                    else
                        .{ .slice = stream.?.getWritten(), },
                    null
                );
            }

            return UnbufferedMessage.from(
                header.opcode,
                .{
                    .reader = .{
                        .message_complete = true,
                        .message_reader = io.limitedReader(self.reader, header.len),
                    }
                },
                null,
            );
        }

        pub fn waitForDataAvailable(self: *Self, timeout_nano_seconds: u64) !bool
        {
            switch (builtin.os.tag)
            {
                .windows =>
                {
                    return try win_select.wait_until_socket_readable(self.handle, timeout_nano_seconds);
                },
                else =>
                {
                    // The timeout is implemented with a socketopt error on non-windows systems
                    const tv = common.timeval_from_ns(timeout_nano_seconds);
                    try std.os.setsockopt(
                        self.handle,
                        std.os.SOL.SOCKET,
                        std.os.SO.RCVTIMEO,
                        mem.toBytes(tv)[0..]
                    );
                    return true;
                },
            }
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
        pub fn receiveRaw(
            self: *Self,
            out_stream: ?*io.FixedBufferStream([]u8),
            writer: anytype,
            max_msg_length: u64,
            timeout_nano_seconds: u64,
        ) !UnbufferedMessage {
            const data_available = try self.waitForDataAvailable(timeout_nano_seconds);
            if (!data_available)
            {
                return std.net.Stream.ReadError.WouldBlock;
            }

            const header = try self.getHeader();
            return switch (header.opcode) {
                .continuation => self.continuation1(header, out_stream, writer, max_msg_length),
                .text, .binary => switch (header.fin) {
                    true => self.regular(header, out_stream, writer, max_msg_length),
                    false => self.continuation(header, out_stream, writer, max_msg_length),
                },

                // control frames
                .ping, .pong => self.pingPong(header),
                .close => self.close(header),

                else => error.UnknownOpcode,
            };
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
            return self.receiveRaw(null, writer, max_msg_length, timeout_nano_seconds);
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
            return self.receiveRaw(
                out_stream,
                out_stream.*.writer(),
                try out_stream.*.getEndPos(),
                timeout_nano_seconds,
            );
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
            var out_stream = io.fixedBufferStream(out_buf);
            return self.receiveIntoStream(&out_stream, timeout_nano_seconds);
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
            return self.receiveRaw(null, null, max_msg_length, timeout_nano_seconds);
        }
    };
}
