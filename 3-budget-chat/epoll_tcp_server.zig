const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const testing = std.testing;
const c = @cImport({
    @cInclude("arpa/inet.h");
});

fn is_valid_client_name(buffer: []u8) bool {
    if (buffer.len == 0 or buffer.len > 16) return false;
    for (buffer) |char| {
        if (!std.ascii.isAlphanumeric(char)) return false;
    }

    return true;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // i32 -> client's fd
    var clients = std.AutoHashMap(i32, ?[]const u8).init(allocator);
    defer clients.deinit();

    const address = try std.net.Address.parseIp("127.0.0.1", 8000);
    const sockfd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
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
    events.events = linux.EPOLL.IN;
    events.data = linux.epoll_data{ .fd = sockfd };

    const max_event_len = 100;
    const polled_events: []linux.epoll_event = try allocator.alloc(linux.epoll_event, max_event_len);
    defer allocator.free(polled_events);

    try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, sockfd, &events);

    std.debug.print("Server is listening on port {d}\n", .{address.getPort()});

    while (true) {
        const avail_events_len = posix.epoll_wait(epfd, polled_events, -1);
        if (avail_events_len == 0) {
            continue;
        }

        for (0..avail_events_len) |i| {
            const event = polled_events[i];
            if (event.data.fd == sockfd) {
                // Accept new incoming connection
                const client_sockfd = try posix.accept(sockfd, null, null, posix.SOCK.CLOEXEC);
                std.debug.print("Accepting new incoming connection with fd {d}\n", .{client_sockfd});

                events.events = linux.EPOLL.IN;
                events.data.fd = client_sockfd;
                try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, client_sockfd, &events);

                if (!clients.contains(client_sockfd)) {
                    _ = posix.write(client_sockfd, "Welcome to budgetchat! What shall I call you?\n") catch |err| {
                        std.debug.print("Fail to send welcome message to fd {d} with error: {}\n", .{ sockfd, err });
                        std.debug.print("Closing socket {d}\n", .{event.data.fd});
                        posix.close(event.data.fd);
                        if (!clients.remove(event.data.fd)) {
                            std.debug.print("Failed to remove a client from hashmap\n", .{});
                        }
                        try posix.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, event.data.fd, null);
                        continue;
                    };

                    _ = try clients.put(client_sockfd, null);
                }
            } else if (event.events & linux.EPOLL.IN != 0) {
                // Handle incoming data
                const buffer = try allocator.alloc(u8, 1024);
                defer allocator.free(buffer);

                const nread = posix.read(event.data.fd, buffer) catch |err| {
                    std.debug.print("Read error {} \n", .{err});
                    std.debug.print("Closing socket {d}\n", .{event.data.fd});
                    posix.close(event.data.fd);
                    if (!clients.remove(event.data.fd)) {
                        std.debug.print("Failed to remove a client from hashmap\n", .{});
                    }
                    try posix.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, event.data.fd, null);
                    continue;
                };

                if (nread > 0) {
                    std.debug.print("Received data: {}\n", .{std.fmt.fmtSliceHexLower(buffer[0..nread])});
                    std.debug.print("Received length: {d}\n", .{nread});

                    // if (std.mem.eql(u8, std.fmt.fmtSliceHexLower(buffer[0..nread].ptr), "fff4fffd06")) {
                    //     std.debug.print("Closing socket {d}\n", .{event.data.fd});
                    //     posix.close(event.data.fd);
                    //     if (!clients.remove(event.data.fd)) {
                    //         std.debug.print("Failed to remove a client from hashmap\n", .{});
                    //     }
                    //     try posix.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, event.data.fd, null);
                    //     continue;
                    // }

                    var buffer_reader = std.io.fixedBufferStream(buffer);
                    const line = (try nextLine(buffer_reader.reader(), buffer)) orelse "";
                    if (clients.get(event.data.fd).? == null) {
                        const owned_name = try allocator.dupe(u8, line);
                        if (!is_valid_client_name(owned_name)) {
                            _ = posix.write(event.data.fd, "A valid name should be alphanumeric and the max length 16 characters\n") catch |err| {
                                std.debug.print("Fail to send invalid name message to fd {d} with error: {}\n", .{ event.data.fd, err });
                                std.debug.print("Closing socket {d}\n", .{event.data.fd});
                                posix.close(event.data.fd);
                                if (!clients.remove(event.data.fd)) {
                                    std.debug.print("Failed to remove a client from hashmap\n", .{});
                                }
                                try posix.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, event.data.fd, null);
                            };
                        }

                        _ = try clients.put(event.data.fd, owned_name);
                        // std.debug.print("Set a name: {s}\n", .{line});

                        const new_client_entered_msg = try std.fmt.allocPrint(allocator, "* {s} has entered the room\n", .{owned_name});
                        defer allocator.free(new_client_entered_msg);

                        std.debug.print("{s}\n", .{new_client_entered_msg});

                        var client_names = std.ArrayList([]const u8).init(allocator);
                        defer client_names.deinit();

                        var current_clients_iter = clients.iterator();
                        while (current_clients_iter.next()) |entry| {
                            if (entry.key_ptr.* == event.data.fd or entry.value_ptr.* == null) continue;
                            try client_names.append(entry.value_ptr.*.?);
                            _ = posix.write(entry.key_ptr.*, new_client_entered_msg) catch |err| {
                                std.debug.print("Fail to send broadcast a new client entered message to fd {d} with error: {}\n", .{ entry.key_ptr.*, err });
                            };
                        }

                        const client_names_slice = try client_names.toOwnedSlice();
                        const client_names_with_sep = try std.mem.join(allocator, ", ", client_names_slice);

                        const client_names_msg = try std.fmt.allocPrint(allocator, "* The room contains: {s}\n", .{client_names_with_sep});
                        defer allocator.free(client_names_msg);

                        _ = posix.write(event.data.fd, client_names_msg) catch |err| {
                            std.debug.print("Fail to send broadcast message to fd {d} with error: {}\n", .{ event.data.fd, err });
                        };

                        continue;
                    }

                    const sender_name = clients.get(event.data.fd).?;
                    const len_total = sender_name.?.len + line.len + 10;
                    const resp_msg = try allocator.alloc(u8, len_total);
                    defer allocator.free(resp_msg);

                    _ = try std.fmt.bufPrint(resp_msg, "[{s}] {s}\n", .{ sender_name.?, line });
                    var client_iter = clients.keyIterator();
                    while (client_iter.next()) |fd_entry| {
                        if (fd_entry.* == event.data.fd) continue;
                        _ = posix.write(fd_entry.*, resp_msg) catch |err| {
                            std.debug.print("Fail to send broadcast message to fd {d} with error: {}\n", .{ fd_entry.*, err });
                            continue;
                        };
                    }
                }
            } else {
                std.debug.print("Closing socket {d}\n", .{event.data.fd});
                posix.close(event.data.fd);
                const closed_client_name = clients.get(event.data.fd).?.?;
                const closed_client_msg = try std.fmt.allocPrint(allocator, "* {s} has left the room\n", .{closed_client_name});
                defer allocator.free(closed_client_msg);

                var client_iter = clients.keyIterator();
                while (client_iter.next()) |fd_entry| {
                    if (fd_entry.* == event.data.fd) continue;
                    _ = posix.write(fd_entry.*, closed_client_msg) catch |err| {
                        std.debug.print("Fail to send broadcast message to fd {d} with error: {}\n", .{ fd_entry.*, err });
                        continue;
                    };
                }

                if (!clients.remove(event.data.fd)) {
                    std.debug.print("Failed to remove a client from hashmap\n", .{});
                }

                try posix.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, event.data.fd, null);
            }
        }
    }
}

fn nextLine(reader: anytype, buffer: []u8) !?[]const u8 {
    const line = (try reader.readUntilDelimiterOrEof(buffer, '\n')) orelse return null;

    // Check if the last character is \r and trim it
    if (line.len > 0 and buffer[line.len - 1] == '\r') {
        return std.mem.trimRight(u8, line, "\r");
    }

    return line;
}

test "nextLine function" {
    // Declare buffer as a const slice of bytes
    var buffer: []u8 = @constCast("lorem kodko oss\n");

    // Use fixedBufferStream with a const slice
    var buffer_reader = std.io.fixedBufferStream(buffer);
    const line = (try nextLine(buffer_reader.reader(), buffer)).?;
    try testing.expectEqualStrings("lorem kodko oss\n", line);

    buffer = "";
}
