const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const testing = std.testing;
const c = @cImport({
    @cInclude("arpa/inet.h");
});

const User = struct {
    name: []const u8,
    fn new(allocator: std.mem.Allocator, name: []const u8) !*User {
        const user = try allocator.create(User);
        user.* = .{ .name = name };

        return user;
    }

    fn is_valid_name(buffer: []const u8) bool {
        if (buffer.len == 0 or buffer.len > 16) return false;
        for (buffer) |char| {
            if (!std.ascii.isAlphanumeric(char)) return false;
        }

        return true;
    }
};

const ClientStream = struct {
    buffer: []u8,
    stream: std.net.Stream,
    pos: usize,
    done: bool,

    fn new(fd: i32, allocator: std.mem.Allocator) !*ClientStream {
        const buffer = try allocator.alloc(u8, 1024);
        const client_stream: *ClientStream = try allocator.create(ClientStream);
        client_stream.* = ClientStream{ .buffer = buffer, .stream = std.net.Stream{ .handle = fd }, .pos = 0, .done = false };
        return client_stream;
    }

    fn stripLineEndings(line: []u8) []u8 {
        if (std.mem.endsWith(u8, line, "\r\n")) {
            return line[0 .. line.len - 2];
        } else if (std.mem.endsWith(u8, line, "\n")) {
            return line[0 .. line.len - 1];
        } else {
            return line;
        }
    }

    fn read_line(self: *ClientStream, allocator: std.mem.Allocator) !usize {
        if (self.done) {
            allocator.free(self.buffer);
            self.pos = 0;
            self.done = false;
        }

        var tmp_buffer = try allocator.alloc(u8, 1024);
        defer allocator.free(tmp_buffer);

        while (true) {
            const received_size = self.stream.read(tmp_buffer) catch |err| {
                switch (err) {
                    std.posix.ReadError.WouldBlock => return self.pos, // Not an error, just non-blocking behavior
                    else => return err,
                }
            };

            if (received_size == 0) {
                return 0; // Connection closed by client
            }

            const n_index = std.mem.indexOf(u8, tmp_buffer[0..received_size], "\n");
            if (n_index) |index| {
                const strippedLine = stripLineEndings(tmp_buffer[0 .. index + 1]);
                @memcpy(self.buffer[self.pos .. self.pos + strippedLine.len], strippedLine);
                self.pos += strippedLine.len;
                self.done = true;
                return self.pos; // Return the number of bytes processed up to the newline
            } else {
                // No newline found, append all read data to buffer
                @memcpy(self.buffer[self.pos .. self.pos + received_size], tmp_buffer[0..received_size]);
                self.pos += received_size;
            }
        }
    }

    // fn read_line(self: *ClientStream, allocator: std.mem.Allocator) !usize {
    //     if (self.done) {
    //         allocator.free(self.buffer);
    //         self.pos = 0;
    //         self.done = false;
    //     }
    //
    //     var tmp_buffer = try allocator.alloc(u8, 1024);
    //     defer allocator.free(tmp_buffer);
    //
    //     const received_size = try self.stream.read(tmp_buffer);
    //     const n_index = std.mem.indexOf(u8, tmp_buffer, "\n");
    //     if (n_index != null) {
    //         const strippedLine = stripLineEndings(tmp_buffer[0..received_size]);
    //         @memcpy(self.buffer[self.pos .. self.pos + strippedLine.len], strippedLine);
    //         self.pos += strippedLine.len;
    //         self.done = true;
    //
    //         return self.pos;
    //     }
    //
    //     if (received_size <= 0) {
    //         return 0;
    //     }
    //
    //     @memcpy(self.buffer[self.pos .. self.pos + received_size], tmp_buffer[0..received_size]);
    //     self.pos += received_size;
    //     return self.pos;
    // }
};

const ClientManager = struct {
    clients: std.AutoHashMap(i32, ?*User),

    fn init(allocator: std.mem.Allocator) ClientManager {
        return ClientManager{
            .clients = std.AutoHashMap(i32, ?*User).init(allocator),
        };
    }

    fn remove(self: *ClientManager, fd: i32) void {
        if (self.clients.remove(fd)) {
            std.log.info("Client removed: {}\n", .{fd});
        } else {
            std.log.err("Failed to remove client: {}\n", .{fd});
            unreachable;
        }
    }

    fn get(self: *ClientManager, fd: i32) ?*User {
        return self.clients.get(fd) orelse null;
    }

    fn deinit(self: *ClientManager) void {
        self.clients.deinit();
    }

    fn clean(self: *ClientManager, allocator: std.mem.Allocator, fd: i32) void {
        const client_value = self.clients.get(fd);
        if (client_value != null) {
            allocator.free(client_value.?.?.name);
            // destroy user type
            allocator.destroy(client_value.?.?);
        }
    }
};

fn handle_connection(allocator: std.mem.Allocator, event: linux.epoll_event, clients: *ClientManager, epfd: i32) !void {
    var stream: *ClientStream = @ptrFromInt(event.data.ptr);
    const client_fd = stream.*.stream.handle;

    const nread = stream.read_line(allocator) catch |err| {
        std.log.err("Read error {} \n", .{err});
        return err;
    };

    if (nread > 0 and stream.done) {
        // std.debug.print("Received data: {}\n", .{std.fmt.fmtSliceHexLower(stream.buffer[0..nread])});
        // std.debug.print("Received length: {d}\n", .{nread});

        // Taking new joined clients
        if (clients.get(client_fd) == null) {
            const owned_name = try allocator.dupe(u8, stream.buffer[0..stream.pos]);
            if (!User.is_valid_name(owned_name)) {
                _ = posix.write(client_fd, "A valid name should be alphanumeric and the max length 16 characters\n") catch |err| {
                    std.debug.print("Fail to send invalid name message to fd {d} with error: {}\n", .{ client_fd, err });
                    return err;
                };

                std.debug.print("Closing socket {d}\n", .{client_fd});
                try posix.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, client_fd, null);
                posix.close(client_fd);
                clients.remove(client_fd);
                return;
            }

            // std.debug.print("owned name: {s}\n", .{owned_name});

            const new_user = try User.new(allocator, owned_name);
            errdefer allocator.destroy(new_user);

            _ = try clients.clients.put(client_fd, new_user);

            const new_client_entered_msg = try std.fmt.allocPrint(allocator, "* {s} has entered the room\n", .{new_user.name});
            defer allocator.free(new_client_entered_msg);

            std.debug.print("{s}", .{new_client_entered_msg});

            var client_names = std.ArrayList([]const u8).init(allocator);
            defer client_names.deinit();

            var current_clients_iter = clients.clients.iterator();
            while (current_clients_iter.next()) |entry| {
                if (entry.key_ptr.* == client_fd or entry.value_ptr.* == null) continue;
                // std.debug.print("client: {s}\n", .{entry.value_ptr.*.?.name});
                try client_names.append(entry.value_ptr.*.?.name);
                _ = posix.write(entry.key_ptr.*, new_client_entered_msg) catch |err| {
                    std.debug.print("Fail to send broadcast a new client entered message to fd {d} with error: {}\n", .{ entry.key_ptr.*, err });
                    continue;
                };
            }

            const client_names_slice = try client_names.toOwnedSlice();
            const client_names_with_sep = try std.mem.join(allocator, ", ", client_names_slice);

            const client_names_msg = try std.fmt.allocPrint(allocator, "* The room contains: {s}\n", .{client_names_with_sep});
            defer allocator.free(client_names_msg);
            std.debug.print("{s}\n", .{client_names_msg});

            _ = posix.write(client_fd, client_names_msg) catch |err| {
                std.debug.print("Fail to send client names message to fd {d} with error: {}\n", .{ client_fd, err });
            };

            return;
        }

        const sender_name = clients.get(client_fd).?;
        std.debug.print("sender: {s}\n", .{sender_name.name});
        const len_total = sender_name.*.name.len + stream.pos + 4;
        const resp_msg = try allocator.alloc(u8, len_total);
        defer allocator.free(resp_msg);

        _ = try std.fmt.bufPrint(resp_msg, "[{s}] {s}\n", .{ sender_name.name, stream.buffer[0..stream.pos] });
        std.debug.print("{s}\n", .{resp_msg});
        var client_iter = clients.clients.iterator();
        while (client_iter.next()) |entry| {
            const key = entry.key_ptr;
            const val = entry.value_ptr;
            if (key.* == client_fd or val.* == null) continue;
            _ = posix.write(key.*, resp_msg) catch |err| {
                std.debug.print("Fail to send broadcast a message to fd {d} with error: {}\n", .{ key.*, err });
                continue;
            };
        }
    }

    // closing client socket
    if (nread == 0 and stream.pos == 0) {
        const closed_client_name = clients.get(client_fd);
        if (closed_client_name != null) {
            std.debug.print("Closing socket {d}\n", .{client_fd});
            const closed_client_msg = try std.fmt.allocPrint(allocator, "* {s} has left the room\n", .{closed_client_name.?.name});
            std.debug.print("{s}", .{closed_client_msg});
            defer allocator.free(closed_client_msg);

            var client_iter = clients.clients.keyIterator();
            while (client_iter.next()) |fd_entry| {
                if (fd_entry.* == client_fd) continue;
                _ = posix.write(fd_entry.*, closed_client_msg) catch |err| {
                    std.debug.print("Fail to send broadcast message to fd {d} with error: {}\n", .{ fd_entry.*, err });
                    continue;
                };
            }
            clients.clean(allocator, client_fd);
        }
        clients.remove(client_fd);
        try posix.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, client_fd, null);
        posix.close(client_fd);
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // i32 -> client's fd
    var clients = ClientManager.init(allocator);
    defer clients.deinit();

    const address = try std.net.Address.parseIp("127.0.0.1", 8000);
    const sockfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
    try posix.setsockopt(
        sockfd,
        posix.SOL.SOCKET,
        posix.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );

    const socklen = address.getOsSockLen();
    try posix.bind(sockfd, &address.any, socklen);
    try posix.listen(sockfd, 100);

    const epfd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
    var events: linux.epoll_event = undefined;
    events.events = linux.EPOLL.IN | linux.EPOLL.ET;
    events.data = linux.epoll_data{ .fd = sockfd };

    const max_event_len = 100;
    const polled_events: []linux.epoll_event = try allocator.alloc(linux.epoll_event, max_event_len);
    defer allocator.free(polled_events);

    try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, sockfd, &events);

    std.log.info("Server is listening on port {d}\n", .{address.getPort()});

    while (true) {
        const avail_events_len = posix.epoll_wait(epfd, polled_events, -1);
        if (avail_events_len == 0) {
            continue;
        }

        for (0..avail_events_len) |i| {
            const event = polled_events[i];

            if (event.data.fd == sockfd) {
                // Accept new incoming connection
                const client_sockfd = try posix.accept(sockfd, null, null, posix.SOCK.NONBLOCK);
                std.debug.print("Accepting new incoming connection with fd {d}\n", .{client_sockfd});

                if (!clients.clients.contains(client_sockfd)) {
                    _ = posix.write(client_sockfd, "Welcome to budgetchat! What shall I call you?\n") catch |err| {
                        std.debug.print("Fail to send welcome message to fd {d} with error: {}\n", .{ sockfd, err });
                        std.debug.print("Closing socket {d}\n", .{event.data.fd});
                        clients.remove(event.data.fd);
                        try posix.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, event.data.fd, null);
                        posix.close(event.data.fd);
                        continue;
                    };

                    _ = try clients.clients.put(client_sockfd, null);
                }

                events.events = linux.EPOLL.IN | linux.EPOLL.ET;
                const client_stream = try ClientStream.new(client_sockfd, allocator);
                events.data.ptr = @intFromPtr(client_stream);
                try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, client_sockfd, &events);
                // client data is avaialable to read
            } else if (event.events & linux.EPOLL.IN != 0) {
                // try pool.spawn(handle_connection, .{ allocator, event, &clients, epfd });
                // const thread = std.Thread.spawn(.{}, handle_connection, .{ allocator, event, &clients, epfd }) catch continue;
                // thread.detach();
                try handle_connection(allocator, event, &clients, epfd);
            }
        }
    }
}
