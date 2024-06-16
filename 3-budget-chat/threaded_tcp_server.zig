const std = @import("std");
const posix = std.posix;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;

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

const Room = struct {
    clients: std.AutoHashMap(i32, ?*User),
    mutex: Mutex,

    fn init(allocator: std.mem.Allocator) Room {
        return Room{
            .clients = std.AutoHashMap(i32, ?*User).init(allocator),
            .mutex = Mutex{},
        };
    }

    fn remove(self: *Room, fd: i32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.clients.remove(fd)) {
            std.log.info("Client removed: {}\n", .{fd});
        } else {
            std.log.err("Failed to remove client: {}\n", .{fd});
            unreachable;
        }
    }

    fn clean(self: *Room, allocator: std.mem.Allocator, fd: i32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const client_value = self.clients.get(fd);
        if (client_value != null) {
            allocator.free(client_value.?.?.name);
            // destroy User type
            allocator.destroy(client_value.?.?);
        }
    }
};

const ClientConn = struct {
    buffer: []u8,
    stream: std.net.Stream,
    pos: usize,
    // to indicate there is a new line suffix
    done: bool,

    fn new(fd: i32, allocator: std.mem.Allocator) !*ClientConn {
        const buffer = try allocator.alloc(u8, 1024);
        const client_conn: *ClientConn = try allocator.create(ClientConn);
        client_conn.* = ClientConn{ .buffer = buffer, .stream = std.net.Stream{ .handle = fd }, .pos = 0, .done = false };
        return client_conn;
    }

    fn get_fd(self: *ClientConn) i32 {
        return self.stream.handle;
    }

    fn strip_line_suffix(line: []u8) []u8 {
        if (std.mem.endsWith(u8, line, "\r\n")) {
            return line[0 .. line.len - 2];
        } else if (std.mem.endsWith(u8, line, "\n")) {
            return line[0 .. line.len - 1];
        } else {
            return line;
        }
    }

    fn read_line(self: *ClientConn, allocator: std.mem.Allocator) !usize {
        if (self.done) {
            allocator.free(self.buffer);
            self.pos = 0;
            self.done = false;
        }

        var tmp_buffer = try allocator.alloc(u8, 1024);
        defer allocator.free(tmp_buffer);

        const received_size = try self.stream.read(tmp_buffer);

        if (received_size == 0) {
            return 0;
        }

        const n_index = std.mem.indexOf(u8, tmp_buffer[0..received_size], "\n");
        if (n_index) |index| {
            const strippedLine = strip_line_suffix(tmp_buffer[0 .. index + 1]);
            @memcpy(self.buffer[self.pos .. self.pos + strippedLine.len], strippedLine);
            self.pos += strippedLine.len;
            self.done = true;
            return self.pos; // Return the number of bytes processed up to the newline
        } else {
            // No newline found, append all read data to buffer
            @memcpy(self.buffer[self.pos .. self.pos + received_size], tmp_buffer[0..received_size]);
            self.pos += received_size;
            return self.pos;
        }
    }
};

pub fn main() !void {
    const address = try std.net.Address.parseIp("0.0.0.0", 8000);
    var listener = try std.net.Address.listen(address, .{
        .kernel_backlog = 1024,
        .reuse_address = true,
    });

    std.log.info("Server is listening on port {d}\n", .{address.getPort()});

    defer listener.deinit();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // i32 -> client's fd
    var room = Room.init(allocator);
    defer room.clients.deinit();
    defer allocator.destroy(&room);

    while (true) {
        const conn = try listener.accept();
        if (conn.stream.handle > 0) {
            const client_conn = try ClientConn.new(conn.stream.handle, allocator);

            const thread = try std.Thread.spawn(.{}, handler, .{ client_conn, allocator, &room });
            thread.detach();
        }
    }
}

fn handler(client_conn: *ClientConn, allocator: std.mem.Allocator, room: *Room) !void {
    if (!room.clients.contains(client_conn.get_fd())) {
        _ = client_conn.stream.write("Welcome to budgetchat! What shall I call you?\n") catch |err| {
            std.debug.print("Fail to send welcome message to fd {d} with error: {}\n", .{ client_conn.get_fd(), err });
            std.debug.print("Closing socket {d}\n", .{client_conn.get_fd()});
            room.remove(client_conn.get_fd());
            client_conn.stream.close();
            return;
        };

        _ = try room.clients.put(client_conn.get_fd(), null);
    }

    while (true) {
        const nread = client_conn.read_line(allocator) catch |err| {
            std.log.err("Read error {} \n", .{err});
            return err;
        };

        std.debug.print("Received data: {}\n", .{std.fmt.fmtSliceHexLower(client_conn.buffer[0..nread])});
        std.debug.print("Received length: {d}\n", .{nread});

        if (nread > 0 and client_conn.done) {
            if (room.clients.get(client_conn.get_fd()).? == null) {
                const owned_name = try allocator.dupe(u8, client_conn.buffer[0..client_conn.pos]);
                if (!User.is_valid_name(owned_name)) {
                    _ = client_conn.stream.write("A valid name should be alphanumeric and the max length 16 characters\n") catch |err| {
                        std.debug.print("Fail to send invalid name message with error: {}\n", .{err});
                        return err;
                    };

                    std.debug.print("Closing a socket\n", .{});
                    room.remove(client_conn.get_fd());
                    client_conn.stream.close();
                    return;
                }

                const new_user = try User.new(allocator, owned_name);
                errdefer allocator.destroy(new_user);

                _ = try room.clients.put(client_conn.get_fd(), new_user);

                const new_client_entered_msg = try std.fmt.allocPrint(allocator, "* {s} has entered the room\n", .{new_user.name});
                defer allocator.free(new_client_entered_msg);

                std.debug.print("{s}", .{new_client_entered_msg});

                var client_names = std.ArrayList([]const u8).init(allocator);
                defer client_names.deinit();

                var current_clients_iter = room.clients.iterator();
                while (current_clients_iter.next()) |entry| {
                    if (entry.key_ptr.* == client_conn.stream.handle or entry.value_ptr.* == null) continue;
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

                _ = client_conn.stream.write(client_names_msg) catch |err| {
                    std.debug.print("Fail to send client names message with error: {}\n", .{err});
                };

                continue;
            }

            const sender = room.clients.get(client_conn.get_fd()).?;
            if (sender == null) {
                continue;
            }
            std.debug.print("sender: {s}\n", .{sender.?.name});
            const len_total = sender.?.*.name.len + client_conn.pos + 4;
            const resp_msg = try allocator.alloc(u8, len_total);
            defer allocator.free(resp_msg);

            _ = try std.fmt.bufPrint(resp_msg, "[{s}] {s}\n", .{ sender.?.name, client_conn.buffer[0..client_conn.pos] });
            std.debug.print("{s}\n", .{resp_msg});
            var client_iter = room.clients.iterator();
            while (client_iter.next()) |entry| {
                const key = entry.key_ptr;
                const val = entry.value_ptr;
                if (key.* == client_conn.stream.handle or val.* == null) continue;
                _ = posix.write(key.*, resp_msg) catch |err| {
                    std.debug.print("Fail to send broadcast a message to fd {d} with error: {}\n", .{ key.*, err });
                    continue;
                };
            }
        }

        // closing client socket
        if (nread == 0 and client_conn.pos == 0) {
            const closed_client_name = room.clients.get(client_conn.get_fd()).?;
            if (closed_client_name != null) {
                std.debug.print("Closing socket {d}\n", .{client_conn.get_fd()});
                const closed_client_msg = try std.fmt.allocPrint(allocator, "* {s} has left the room\n", .{closed_client_name.?.name});
                std.debug.print("{s}", .{closed_client_msg});
                defer allocator.free(closed_client_msg);

                var client_iter = room.clients.keyIterator();
                while (client_iter.next()) |fd_entry| {
                    if (fd_entry.* == client_conn.stream.handle) continue;
                    _ = posix.write(fd_entry.*, closed_client_msg) catch |err| {
                        std.debug.print("Fail to send broadcast message to fd {d} with error: {}\n", .{ fd_entry.*, err });
                        continue;
                    };
                }
                room.clean(allocator, client_conn.get_fd());
            }
            room.remove(client_conn.get_fd());
            client_conn.stream.close();
            return;
        }
    }
}
