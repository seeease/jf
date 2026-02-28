/// Storage 层
/// 封装 SQLite 操作和文件系统存储
const std = @import("std");
const id = @import("id.zig");
const c = @cImport({
    @cInclude("sqlite3.h");
});

/// 销毁模式
pub const DestroyMode = enum { count, time };

/// 内容类型
pub const ContentType = enum { text, file };

/// 创建分享参数
pub const CreateParams = struct {
    content_type: ContentType,
    text_body: ?[]const u8 = null,
    file_data: ?[]const u8 = null,
    file_name: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    destroy_mode: DestroyMode,
    destroy_value: u64,
};

/// 创建分享结果
pub const ShareResult = struct {
    id: [22]u8,
};

/// 获取内容结果
pub const Content = struct {
    content_type: ContentType,
    text_body: ?[]const u8, // 调用方需释放
    file_data: ?[]const u8, // 调用方需释放
    mime_type: ?[]const u8, // 调用方需释放
};

/// 统计信息
pub const Stats = struct {
    active_contents: u32,
    storage_bytes: u64,
};

/// 创建分享错误
pub const CreateError = error{
    EmptyContent,
    FileTooLarge,
    DestroyValueExceedsLimit,
    SqlError,
    IoError,
};

/// SQLite 错误
pub const SqliteError = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    StepFailed,
    BindFailed,
};

pub const Storage = struct {
    db: ?*c.sqlite3,
    data_dir: []const u8,
    allocator: std.mem.Allocator,
    max_ttl: u64,
    max_view_count: u32,
    max_file_size: u64,

    /// 初始化 Storage：创建数据目录、打开 SQLite、建表
    pub fn init(
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        max_ttl: u64,
        max_view_count: u32,
        max_file_size: u64,
    ) !Storage {
        // 创建数据目录（如果不存在）
        std.fs.cwd().makePath(data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // 拼接数据库路径
        const db_path = try std.fs.path.joinZ(allocator, &.{ data_dir, "jfai.db" });
        defer allocator.free(db_path);

        // 打开 SQLite 数据库
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(db_path.ptr, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return SqliteError.OpenFailed;
        }

        var storage = Storage{
            .db = db,
            .data_dir = data_dir,
            .allocator = allocator,
            .max_ttl = max_ttl,
            .max_view_count = max_view_count,
            .max_file_size = max_file_size,
        };

        // 建表和索引
        try storage.initDb();

        return storage;
    }

    /// 使用内存数据库初始化（测试用）
    pub fn initInMemory(
        allocator: std.mem.Allocator,
        max_ttl: u64,
        max_view_count: u32,
        max_file_size: u64,
    ) !Storage {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(":memory:", &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return SqliteError.OpenFailed;
        }

        var storage = Storage{
            .db = db,
            .data_dir = "",
            .allocator = allocator,
            .max_ttl = max_ttl,
            .max_view_count = max_view_count,
            .max_file_size = max_file_size,
        };

        try storage.initDb();

        return storage;
    }

    /// 创建 contents 表和索引
    fn initDb(self: *Storage) !void {
        const sql =
            \\CREATE TABLE IF NOT EXISTS contents (
            \\    id          TEXT PRIMARY KEY,
            \\    type        TEXT NOT NULL,
            \\    text_body   TEXT,
            \\    file_path   TEXT,
            \\    mime_type   TEXT,
            \\    destroy_mode TEXT NOT NULL,
            \\    destroy_value INTEGER NOT NULL,
            \\    view_count  INTEGER NOT NULL DEFAULT 0,
            \\    created_at  INTEGER NOT NULL,
            \\    expires_at  INTEGER NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_expires_at ON contents(expires_at);
        ;
        try execSql(self.db.?, sql);
    }

    /// 创建分享记录
    pub fn createShare(self: *Storage, params: CreateParams) CreateError!ShareResult {
        // 参数校验
        switch (params.content_type) {
            .text => {
                const body = params.text_body orelse return CreateError.EmptyContent;
                if (body.len == 0) return CreateError.EmptyContent;
            },
            .file => {
                const data = params.file_data orelse return CreateError.EmptyContent;
                if (data.len == 0) return CreateError.EmptyContent;
                if (data.len > self.max_file_size) return CreateError.FileTooLarge;
            },
        }
        switch (params.destroy_mode) {
            .count => {
                if (params.destroy_value > self.max_view_count) return CreateError.DestroyValueExceedsLimit;
            },
            .time => {
                if (params.destroy_value > self.max_ttl) return CreateError.DestroyValueExceedsLimit;
            },
        }

        // 生成 ID 和时间戳
        const share_id = id.generate();
        const created_at: i64 = std.time.timestamp();
        const expires_at: i64 = switch (params.destroy_mode) {
            .time => created_at + @as(i64, @intCast(@min(params.destroy_value, self.max_ttl))),
            .count => created_at + @as(i64, @intCast(self.max_ttl)),
        };

        // 文件类型：写入文件系统
        var file_path_buf: [22]u8 = undefined;
        const file_path_slice: ?[]const u8 = if (params.content_type == .file) blk: {
            file_path_buf = id.generate();
            const data = params.file_data.?;

            // 写入文件
            const full_path = std.fs.path.join(self.allocator, &.{ self.data_dir, &file_path_buf }) catch return CreateError.IoError;
            defer self.allocator.free(full_path);

            const file = std.fs.cwd().createFile(full_path, .{}) catch return CreateError.IoError;
            defer file.close();
            file.writeAll(data) catch return CreateError.IoError;

            break :blk &file_path_buf;
        } else null;

        // 插入 SQLite
        const sql =
            \\INSERT INTO contents (id, type, text_body, file_path, mime_type, destroy_mode, destroy_value, view_count, created_at, expires_at)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?);
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db.?, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return CreateError.SqlError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const s = stmt.?;
        // 绑定参数
        if (c.sqlite3_bind_text(s, 1, &share_id, 22, c.SQLITE_STATIC) != c.SQLITE_OK) return CreateError.SqlError;

        const type_str: [*:0]const u8 = switch (params.content_type) {
            .text => "text",
            .file => "file",
        };
        if (c.sqlite3_bind_text(s, 2, type_str, -1, c.SQLITE_STATIC) != c.SQLITE_OK) return CreateError.SqlError;

        // text_body
        if (params.text_body) |body| {
            if (c.sqlite3_bind_text(s, 3, body.ptr, @intCast(body.len), c.SQLITE_STATIC) != c.SQLITE_OK) return CreateError.SqlError;
        } else {
            if (c.sqlite3_bind_null(s, 3) != c.SQLITE_OK) return CreateError.SqlError;
        }

        // file_path
        if (file_path_slice) |fp| {
            if (c.sqlite3_bind_text(s, 4, fp.ptr, @intCast(fp.len), c.SQLITE_STATIC) != c.SQLITE_OK) return CreateError.SqlError;
        } else {
            if (c.sqlite3_bind_null(s, 4) != c.SQLITE_OK) return CreateError.SqlError;
        }

        // mime_type
        if (params.mime_type) |mt| {
            if (c.sqlite3_bind_text(s, 5, mt.ptr, @intCast(mt.len), c.SQLITE_STATIC) != c.SQLITE_OK) return CreateError.SqlError;
        } else {
            if (c.sqlite3_bind_null(s, 5) != c.SQLITE_OK) return CreateError.SqlError;
        }

        const mode_str: [*:0]const u8 = switch (params.destroy_mode) {
            .count => "count",
            .time => "time",
        };
        if (c.sqlite3_bind_text(s, 6, mode_str, -1, c.SQLITE_STATIC) != c.SQLITE_OK) return CreateError.SqlError;
        if (c.sqlite3_bind_int64(s, 7, @intCast(params.destroy_value)) != c.SQLITE_OK) return CreateError.SqlError;
        if (c.sqlite3_bind_int64(s, 8, created_at) != c.SQLITE_OK) return CreateError.SqlError;
        if (c.sqlite3_bind_int64(s, 9, expires_at) != c.SQLITE_OK) return CreateError.SqlError;

        if (c.sqlite3_step(s) != c.SQLITE_DONE) return CreateError.SqlError;

        return ShareResult{ .id = share_id };
    }

    /// 获取内容，过期或不存在返回 null
    /// count 模式下自动递增 view_count，达到上限时删除记录
    pub fn getContent(self: *Storage, content_id: []const u8) ?Content {
        // 查询记录
        const select_sql =
            \\SELECT type, text_body, file_path, mime_type, destroy_mode, destroy_value, view_count, expires_at
            \\FROM contents WHERE id = ?;
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db.?, select_sql, -1, &stmt, null) != c.SQLITE_OK) return null;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_text(stmt.?, 1, content_id.ptr, @intCast(content_id.len), c.SQLITE_STATIC) != c.SQLITE_OK) return null;
        if (c.sqlite3_step(stmt.?) != c.SQLITE_ROW) return null;

        // 检查过期
        const expires_at = c.sqlite3_column_int64(stmt.?, 7);
        const now = std.time.timestamp();
        if (now >= expires_at) return null;

        // 解析字段
        const type_raw = std.mem.span(c.sqlite3_column_text(stmt.?, 0));
        const content_type: ContentType = if (std.mem.eql(u8, type_raw, "file")) .file else .text;

        const mode_raw = std.mem.span(c.sqlite3_column_text(stmt.?, 4));
        const is_count_mode = std.mem.eql(u8, mode_raw, "count");
        const destroy_value = c.sqlite3_column_int(stmt.?, 5);
        const view_count = c.sqlite3_column_int(stmt.?, 6);

        // count 模式：递增 view_count
        const should_delete = if (is_count_mode) blk: {
            const new_count = view_count + 1;
            const update_sql = "UPDATE contents SET view_count = ? WHERE id = ?;";
            var upd: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db.?, update_sql, -1, &upd, null) != c.SQLITE_OK) return null;
            defer _ = c.sqlite3_finalize(upd);
            if (c.sqlite3_bind_int(upd.?, 1, new_count) != c.SQLITE_OK) return null;
            if (c.sqlite3_bind_text(upd.?, 2, content_id.ptr, @intCast(content_id.len), c.SQLITE_STATIC) != c.SQLITE_OK) return null;
            if (c.sqlite3_step(upd.?) != c.SQLITE_DONE) return null;
            break :blk new_count >= destroy_value;
        } else false;

        // 先构造返回值（读取文件内容），再删除
        const result: ?Content = switch (content_type) {
            .text => blk: {
                const body_ptr = c.sqlite3_column_text(stmt.?, 1);
                const body_len: usize = @intCast(c.sqlite3_column_bytes(stmt.?, 1));
                const body = self.allocator.dupe(u8, body_ptr[0..body_len]) catch break :blk null;
                break :blk Content{
                    .content_type = .text,
                    .text_body = body,
                    .file_data = null,
                    .mime_type = null,
                };
            },
            .file => blk: {
                const fp_ptr = c.sqlite3_column_text(stmt.?, 2);
                const fp_len: usize = @intCast(c.sqlite3_column_bytes(stmt.?, 2));
                const file_path = fp_ptr[0..fp_len];

                const mt_ptr = c.sqlite3_column_text(stmt.?, 3);
                const mt_len: usize = @intCast(c.sqlite3_column_bytes(stmt.?, 3));
                const mime = self.allocator.dupe(u8, mt_ptr[0..mt_len]) catch break :blk null;

                const full_path = std.fs.path.join(self.allocator, &.{ self.data_dir, file_path }) catch {
                    self.allocator.free(mime);
                    break :blk null;
                };
                defer self.allocator.free(full_path);

                const file = std.fs.cwd().openFile(full_path, .{}) catch {
                    self.allocator.free(mime);
                    break :blk null;
                };
                defer file.close();

                const data = file.readToEndAlloc(self.allocator, 1024 * 1024 * 100) catch {
                    self.allocator.free(mime);
                    break :blk null;
                };

                break :blk Content{
                    .content_type = .file,
                    .text_body = null,
                    .file_data = data,
                    .mime_type = mime,
                };
            },
        };

        // 达到次数上限，读完内容后再删除记录和文件
        if (should_delete) {
            self.deleteContent(content_id);
        }

        return result;
    }

    /// 释放 Content 中分配的内存
    pub fn freeContent(self: *Storage, content: *Content) void {
        if (content.text_body) |b| self.allocator.free(b);
        if (content.file_data) |d| self.allocator.free(d);
        if (content.mime_type) |m| self.allocator.free(m);
        content.text_body = null;
        content.file_data = null;
        content.mime_type = null;
    }

    /// 删除内容：删除 SQLite 记录，如果是文件类型同时删除文件系统中的文件
    pub fn deleteContent(self: *Storage, content_id: []const u8) void {
        std.log.info("destroyed content: id={s}", .{content_id});
        // 先查 file_path
        const sel_sql = "SELECT type, file_path FROM contents WHERE id = ?;";
        var sel: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db.?, sel_sql, -1, &sel, null) != c.SQLITE_OK) return;
        defer _ = c.sqlite3_finalize(sel);
        if (c.sqlite3_bind_text(sel.?, 1, content_id.ptr, @intCast(content_id.len), c.SQLITE_STATIC) != c.SQLITE_OK) return;
        if (c.sqlite3_step(sel.?) != c.SQLITE_ROW) return;

        const type_raw = std.mem.span(c.sqlite3_column_text(sel.?, 0));
        if (std.mem.eql(u8, type_raw, "file")) {
            const fp_ptr = c.sqlite3_column_text(sel.?, 1);
            if (fp_ptr) |fp| {
                const fp_len: usize = @intCast(c.sqlite3_column_bytes(sel.?, 1));
                const full_path = std.fs.path.join(self.allocator, &.{ self.data_dir, fp[0..fp_len] }) catch return;
                defer self.allocator.free(full_path);
                std.fs.cwd().deleteFile(full_path) catch {};
            }
        }

        // 删除数据库记录
        const del_sql = "DELETE FROM contents WHERE id = ?;";
        var del: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db.?, del_sql, -1, &del, null) != c.SQLITE_OK) return;
        defer _ = c.sqlite3_finalize(del);
        if (c.sqlite3_bind_text(del.?, 1, content_id.ptr, @intCast(content_id.len), c.SQLITE_STATIC) != c.SQLITE_OK) return;
        _ = c.sqlite3_step(del.?);
    }

    /// 清理所有过期内容，返回删除数量
    pub fn cleanExpired(self: *Storage) u32 {
        const now = std.time.timestamp();

        // 查询所有过期记录的 ID
        const sql = "SELECT id FROM contents WHERE expires_at < ?;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db.?, sql, -1, &stmt, null) != c.SQLITE_OK) return 0;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_bind_int64(stmt.?, 1, now) != c.SQLITE_OK) return 0;

        // 收集过期 ID（需要先收集，因为 deleteContent 会修改数据库）
        var ids: std.ArrayList([]u8) = .empty;
        defer {
            for (ids.items) |item| self.allocator.free(item);
            ids.deinit(self.allocator);
        }

        while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
            const id_ptr = c.sqlite3_column_text(stmt.?, 0);
            const id_len: usize = @intCast(c.sqlite3_column_bytes(stmt.?, 0));
            const duped = self.allocator.dupe(u8, id_ptr[0..id_len]) catch continue;
            ids.append(self.allocator, duped) catch {
                self.allocator.free(duped);
                continue;
            };
        }

        // 逐条删除
        var count: u32 = 0;
        for (ids.items) |expired_id| {
            self.deleteContent(expired_id);
            count += 1;
        }

        return count;
    }

    /// 获取统计信息：活跃内容数量和存储使用量
    pub fn getStats(self: *Storage) Stats {
        // 查询活跃内容数量
        var active: u32 = 0;
        {
            const sql = "SELECT COUNT(*) FROM contents WHERE expires_at >= ?;";
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db.?, sql, -1, &stmt, null) == c.SQLITE_OK) {
                defer _ = c.sqlite3_finalize(stmt);
                const now = std.time.timestamp();
                if (c.sqlite3_bind_int64(stmt.?, 1, now) == c.SQLITE_OK) {
                    if (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
                        active = @intCast(c.sqlite3_column_int(stmt.?, 0));
                    }
                }
            }
        }

        // 计算存储使用量：SQLite page_count * page_size
        var storage_bytes: u64 = 0;
        {
            const sql = "SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size();";
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db.?, sql, -1, &stmt, null) == c.SQLITE_OK) {
                defer _ = c.sqlite3_finalize(stmt);
                if (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
                    storage_bytes = @intCast(c.sqlite3_column_int64(stmt.?, 0));
                }
            }
        }

        // 累加 data_dir 中的文件大小
        if (self.data_dir.len > 0) {
            if (std.fs.cwd().openDir(self.data_dir, .{ .iterate = true })) |*dir| {
                defer @constCast(dir).close();
                var iter = @constCast(dir).iterate();
                while (iter.next() catch null) |entry| {
                    if (entry.kind == .file) {
                        if (@constCast(dir).statFile(entry.name)) |stat| {
                            storage_bytes += stat.size;
                        } else |_| {}
                    }
                }
            } else |_| {}
        }

        return Stats{
            .active_contents = active,
            .storage_bytes = storage_bytes,
        };
    }

    /// 关闭数据库
    pub fn deinit(self: *Storage) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
            self.db = null;
        }
    }
};

/// 执行简单 SQL 语句（无参数、无返回值）
pub fn execSql(db: *c.sqlite3, sql: [*:0]const u8) SqliteError!void {
    var err_msg: [*c]u8 = null;
    const rc = c.sqlite3_exec(db, sql, null, null, &err_msg);
    if (rc != c.SQLITE_OK) {
        if (err_msg) |msg| c.sqlite3_free(msg);
        return SqliteError.ExecFailed;
    }
}

// ============ 测试 ============

test "Storage: 内存数据库初始化和关闭" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer storage.deinit();

    // 验证数据库已打开
    try std.testing.expect(storage.db != null);
    try std.testing.expectEqual(@as(u64, 86400), storage.max_ttl);
    try std.testing.expectEqual(@as(u32, 100), storage.max_view_count);
    try std.testing.expectEqual(@as(u64, 10485760), storage.max_file_size);
}

test "Storage: 表已创建（插入一条记录验证）" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer storage.deinit();

    // 插入一条测试记录，如果表不存在会报错
    const insert_sql =
        \\INSERT INTO contents (id, type, text_body, destroy_mode, destroy_value, view_count, created_at, expires_at)
        \\VALUES ('test123', 'text', 'hello', 'count', 1, 0, 1000, 2000);
    ;
    try execSql(storage.db.?, insert_sql);

    // 查询验证
    var stmt: ?*c.sqlite3_stmt = null;
    const select_sql = "SELECT id, text_body FROM contents WHERE id = 'test123';";
    const rc = c.sqlite3_prepare_v2(storage.db.?, select_sql, -1, &stmt, null);
    try std.testing.expectEqual(c.SQLITE_OK, rc);
    defer _ = c.sqlite3_finalize(stmt);

    const step_rc = c.sqlite3_step(stmt.?);
    try std.testing.expectEqual(c.SQLITE_ROW, step_rc);

    const id_ptr = c.sqlite3_column_text(stmt.?, 0);
    const body_ptr = c.sqlite3_column_text(stmt.?, 1);
    try std.testing.expectEqualStrings("test123", std.mem.span(id_ptr));
    try std.testing.expectEqualStrings("hello", std.mem.span(body_ptr));
}

test "Storage: 文件系统初始化（临时目录）" {
    // 使用临时目录测试文件系统初始化
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpath(".", &tmp_buf);

    const data_sub = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "jfai_test_data" });
    defer std.testing.allocator.free(data_sub);

    var storage = try Storage.init(
        std.testing.allocator,
        data_sub,
        3600,
        50,
        1048576,
    );
    defer storage.deinit();

    // 验证数据库已打开
    try std.testing.expect(storage.db != null);
    try std.testing.expectEqual(@as(u64, 3600), storage.max_ttl);

    // 验证数据目录已创建
    var dir = try std.fs.cwd().openDir(data_sub, .{});
    dir.close();
}

test "Storage: deinit 后 db 为 null" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    storage.deinit();
    try std.testing.expect(storage.db == null);
}

test "execSql: 无效 SQL 返回错误" {
    var db: ?*c.sqlite3 = null;
    _ = c.sqlite3_open(":memory:", &db);
    defer _ = c.sqlite3_close(db);

    const result = execSql(db.?, "THIS IS NOT VALID SQL;");
    try std.testing.expectError(SqliteError.ExecFailed, result);
}

// ============ createShare 测试 ============

test "createShare: 创建文字分享成功" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer storage.deinit();

    const result = try storage.createShare(.{
        .content_type = .text,
        .text_body = "hello world",
        .destroy_mode = .count,
        .destroy_value = 3,
    });

    // ID 长度为 22
    try std.testing.expectEqual(@as(usize, 22), result.id.len);

    // 验证数据库中有记录
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT type, text_body, destroy_mode, destroy_value FROM contents WHERE id = ?;";
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(storage.db.?, sql, -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);

    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_text(stmt.?, 1, &result.id, 22, c.SQLITE_STATIC));
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt.?));
    try std.testing.expectEqualStrings("text", std.mem.span(c.sqlite3_column_text(stmt.?, 0)));
    try std.testing.expectEqualStrings("hello world", std.mem.span(c.sqlite3_column_text(stmt.?, 1)));
    try std.testing.expectEqualStrings("count", std.mem.span(c.sqlite3_column_text(stmt.?, 2)));
    try std.testing.expectEqual(@as(i32, 3), c.sqlite3_column_int(stmt.?, 3));
}

test "createShare: 空文字内容返回 EmptyContent" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer storage.deinit();

    // text_body 为 null
    try std.testing.expectError(CreateError.EmptyContent, storage.createShare(.{
        .content_type = .text,
        .text_body = null,
        .destroy_mode = .count,
        .destroy_value = 1,
    }));

    // text_body 为空字符串
    try std.testing.expectError(CreateError.EmptyContent, storage.createShare(.{
        .content_type = .text,
        .text_body = "",
        .destroy_mode = .count,
        .destroy_value = 1,
    }));
}

test "createShare: 空文件内容返回 EmptyContent" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer storage.deinit();

    try std.testing.expectError(CreateError.EmptyContent, storage.createShare(.{
        .content_type = .file,
        .file_data = null,
        .destroy_mode = .time,
        .destroy_value = 60,
    }));
}

test "createShare: 文件过大返回 FileTooLarge" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 100, 100); // max_file_size = 100
    defer storage.deinit();

    const big_data = "x" ** 101;
    try std.testing.expectError(CreateError.FileTooLarge, storage.createShare(.{
        .content_type = .file,
        .file_data = big_data,
        .mime_type = "text/plain",
        .destroy_mode = .count,
        .destroy_value = 1,
    }));
}

test "createShare: 次数超限返回 DestroyValueExceedsLimit" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 10, 10485760); // max_view_count = 10
    defer storage.deinit();

    try std.testing.expectError(CreateError.DestroyValueExceedsLimit, storage.createShare(.{
        .content_type = .text,
        .text_body = "test",
        .destroy_mode = .count,
        .destroy_value = 11,
    }));
}

test "createShare: 时间超限返回 DestroyValueExceedsLimit" {
    var storage = try Storage.initInMemory(std.testing.allocator, 3600, 100, 10485760); // max_ttl = 3600
    defer storage.deinit();

    try std.testing.expectError(CreateError.DestroyValueExceedsLimit, storage.createShare(.{
        .content_type = .text,
        .text_body = "test",
        .destroy_mode = .time,
        .destroy_value = 3601,
    }));
}

test "createShare: time 模式 expires_at 计算正确" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer storage.deinit();

    const result = try storage.createShare(.{
        .content_type = .text,
        .text_body = "test",
        .destroy_mode = .time,
        .destroy_value = 300, // 5 分钟
    });

    // 查询 created_at 和 expires_at
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT created_at, expires_at FROM contents WHERE id = ?;";
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(storage.db.?, sql, -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_text(stmt.?, 1, &result.id, 22, c.SQLITE_STATIC));
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt.?));

    const created_at = c.sqlite3_column_int64(stmt.?, 0);
    const expires_at = c.sqlite3_column_int64(stmt.?, 1);
    // time 模式：expires_at = created_at + min(300, 86400) = created_at + 300
    try std.testing.expectEqual(created_at + 300, expires_at);
}

test "createShare: count 模式 expires_at = created_at + max_ttl" {
    var storage = try Storage.initInMemory(std.testing.allocator, 7200, 100, 10485760);
    defer storage.deinit();

    const result = try storage.createShare(.{
        .content_type = .text,
        .text_body = "test",
        .destroy_mode = .count,
        .destroy_value = 5,
    });

    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT created_at, expires_at FROM contents WHERE id = ?;";
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(storage.db.?, sql, -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_text(stmt.?, 1, &result.id, 22, c.SQLITE_STATIC));
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt.?));

    const created_at = c.sqlite3_column_int64(stmt.?, 0);
    const expires_at = c.sqlite3_column_int64(stmt.?, 1);
    // count 模式：expires_at = created_at + max_ttl
    try std.testing.expectEqual(created_at + 7200, expires_at);
}

test "createShare: 文件类型写入文件系统" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &tmp_buf);

    const data_sub = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "file_test" });
    defer std.testing.allocator.free(data_sub);

    var storage = try Storage.init(std.testing.allocator, data_sub, 86400, 100, 10485760);
    defer storage.deinit();

    const file_content = "binary file data here";
    const result = try storage.createShare(.{
        .content_type = .file,
        .file_data = file_content,
        .file_name = "secret.pdf",
        .mime_type = "application/pdf",
        .destroy_mode = .time,
        .destroy_value = 600,
    });

    // 验证数据库记录
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT type, file_path, mime_type FROM contents WHERE id = ?;";
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(storage.db.?, sql, -1, &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_text(stmt.?, 1, &result.id, 22, c.SQLITE_STATIC));
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt.?));

    try std.testing.expectEqualStrings("file", std.mem.span(c.sqlite3_column_text(stmt.?, 0)));
    const stored_path = std.mem.span(c.sqlite3_column_text(stmt.?, 1));
    // 存储路径不应包含原始文件名
    try std.testing.expect(std.mem.indexOf(u8, stored_path, "secret") == null);
    try std.testing.expectEqualStrings("application/pdf", std.mem.span(c.sqlite3_column_text(stmt.?, 2)));

    // 验证文件内容
    const full_path = try std.fs.path.join(std.testing.allocator, &.{ data_sub, stored_path });
    defer std.testing.allocator.free(full_path);
    const file = try std.fs.cwd().openFile(full_path, .{});
    defer file.close();
    var buf: [256]u8 = undefined;
    const n = try file.readAll(&buf);
    try std.testing.expectEqualStrings(file_content, buf[0..n]);
}

// ============ getContent 测试 ============

test "getContent: 获取文字内容成功" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer storage.deinit();

    const result = try storage.createShare(.{
        .content_type = .text,
        .text_body = "hello world",
        .destroy_mode = .time,
        .destroy_value = 3600,
    });

    var content = storage.getContent(&result.id) orelse return error.TestUnexpectedResult;
    defer storage.freeContent(&content);

    try std.testing.expectEqual(ContentType.text, content.content_type);
    try std.testing.expectEqualStrings("hello world", content.text_body.?);
    try std.testing.expect(content.file_data == null);
    try std.testing.expect(content.mime_type == null);
}

test "getContent: 不存在的 ID 返回 null" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer storage.deinit();

    const content = storage.getContent("nonexistent_id_1234567");
    try std.testing.expect(content == null);
}

test "getContent: count 模式查看次数耗尽后返回 null" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer storage.deinit();

    const result = try storage.createShare(.{
        .content_type = .text,
        .text_body = "secret",
        .destroy_mode = .count,
        .destroy_value = 2,
    });

    // 第 1 次：成功
    {
        var c1 = storage.getContent(&result.id) orelse return error.TestUnexpectedResult;
        defer storage.freeContent(&c1);
        try std.testing.expectEqualStrings("secret", c1.text_body.?);
    }

    // 第 2 次：成功（达到上限，触发删除）
    {
        var c2 = storage.getContent(&result.id) orelse return error.TestUnexpectedResult;
        defer storage.freeContent(&c2);
        try std.testing.expectEqualStrings("secret", c2.text_body.?);
    }

    // 第 3 次：已删除，返回 null
    try std.testing.expect(storage.getContent(&result.id) == null);
}

test "getContent: 文件类型返回文件内容" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &tmp_buf);

    const data_sub = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "get_file_test" });
    defer std.testing.allocator.free(data_sub);

    var storage = try Storage.init(std.testing.allocator, data_sub, 86400, 100, 10485760);
    defer storage.deinit();

    const file_content = "PDF binary data";
    const result = try storage.createShare(.{
        .content_type = .file,
        .file_data = file_content,
        .file_name = "doc.pdf",
        .mime_type = "application/pdf",
        .destroy_mode = .time,
        .destroy_value = 3600,
    });

    var content = storage.getContent(&result.id) orelse return error.TestUnexpectedResult;
    defer storage.freeContent(&content);

    try std.testing.expectEqual(ContentType.file, content.content_type);
    try std.testing.expect(content.text_body == null);
    try std.testing.expectEqualStrings("PDF binary data", content.file_data.?);
    try std.testing.expectEqualStrings("application/pdf", content.mime_type.?);
}

// ============ deleteContent 测试 ============

test "deleteContent: 删除后 getContent 返回 null" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer storage.deinit();

    // 创建一条文字分享
    const result = try storage.createShare(.{
        .content_type = .text,
        .text_body = "to be deleted",
        .destroy_mode = .time,
        .destroy_value = 3600,
    });

    // 确认能获取到
    {
        var content = storage.getContent(&result.id) orelse return error.TestUnexpectedResult;
        defer storage.freeContent(&content);
        try std.testing.expectEqualStrings("to be deleted", content.text_body.?);
    }

    // 删除
    storage.deleteContent(&result.id);

    // 删除后应返回 null
    try std.testing.expect(storage.getContent(&result.id) == null);
}

// ============ cleanExpired 测试 ============

test "cleanExpired: 清理过期记录，保留未过期记录" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer storage.deinit();

    const now = std.time.timestamp();

    // 插入 2 条已过期记录（expires_at 在过去）
    const insert_sql =
        \\INSERT INTO contents (id, type, text_body, destroy_mode, destroy_value, view_count, created_at, expires_at)
        \\VALUES (?, 'text', 'expired', 'time', 60, 0, ?, ?);
    ;

    const expired_ids = [_][]const u8{ "expired_id_000000001a", "expired_id_000000001b" };
    for (expired_ids) |eid| {
        var stmt: ?*c.sqlite3_stmt = null;
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(storage.db.?, insert_sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_text(stmt.?, 1, eid.ptr, @intCast(eid.len), c.SQLITE_STATIC));
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_int64(stmt.?, 2, now - 3600));
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_int64(stmt.?, 3, now - 100)); // 已过期
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(stmt.?));
    }

    // 插入 1 条未过期记录（expires_at 在未来）
    {
        var stmt: ?*c.sqlite3_stmt = null;
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(storage.db.?, insert_sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_text(stmt.?, 1, "active_id_0000000001ab", 22, c.SQLITE_STATIC));
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_int64(stmt.?, 2, now - 60));
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_int64(stmt.?, 3, now + 3600)); // 未过期
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(stmt.?));
    }

    // 执行清理
    const deleted = storage.cleanExpired();

    // 验证删除了 2 条过期记录
    try std.testing.expectEqual(@as(u32, 2), deleted);

    // 验证过期记录已删除
    for (expired_ids) |eid| {
        var stmt: ?*c.sqlite3_stmt = null;
        const sel = "SELECT id FROM contents WHERE id = ?;";
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(storage.db.?, sel, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_text(stmt.?, 1, eid.ptr, @intCast(eid.len), c.SQLITE_STATIC));
        try std.testing.expect(c.sqlite3_step(stmt.?) != c.SQLITE_ROW);
    }

    // 验证未过期记录仍存在
    {
        var stmt: ?*c.sqlite3_stmt = null;
        const sel = "SELECT id FROM contents WHERE id = 'active_id_0000000001ab';";
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(storage.db.?, sel, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt.?));
    }
}

test "cleanExpired: 无过期记录时返回 0" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer storage.deinit();

    // 插入一条未过期记录
    const now = std.time.timestamp();
    const insert_sql =
        \\INSERT INTO contents (id, type, text_body, destroy_mode, destroy_value, view_count, created_at, expires_at)
        \\VALUES ('future_id_0000000001ab', 'text', 'still alive', 'time', 60, 0, ?, ?);
    ;
    {
        var stmt: ?*c.sqlite3_stmt = null;
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(storage.db.?, insert_sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_int64(stmt.?, 1, now));
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_int64(stmt.?, 2, now + 86400));
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(stmt.?));
    }

    const deleted = storage.cleanExpired();
    try std.testing.expectEqual(@as(u32, 0), deleted);
}

// ============ getStats 测试 ============

test "getStats: 空数据库返回 0 活跃内容" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer storage.deinit();

    const stats = storage.getStats();
    try std.testing.expectEqual(@as(u32, 0), stats.active_contents);
    // 内存数据库也有 page 开销
    try std.testing.expect(stats.storage_bytes > 0);
}

test "getStats: 创建分享后活跃数量正确" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer storage.deinit();

    // 创建 3 条分享
    for (0..3) |_| {
        _ = try storage.createShare(.{
            .content_type = .text,
            .text_body = "test content",
            .destroy_mode = .time,
            .destroy_value = 3600,
        });
    }

    const stats = storage.getStats();
    try std.testing.expectEqual(@as(u32, 3), stats.active_contents);
    try std.testing.expect(stats.storage_bytes > 0);
}

test "getStats: 删除后活跃数量减少" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer storage.deinit();

    // 创建 3 条
    var ids: [3][22]u8 = undefined;
    for (0..3) |i| {
        const result = try storage.createShare(.{
            .content_type = .text,
            .text_body = "content",
            .destroy_mode = .time,
            .destroy_value = 3600,
        });
        ids[i] = result.id;
    }

    // 删除 1 条
    storage.deleteContent(&ids[0]);

    const stats = storage.getStats();
    try std.testing.expectEqual(@as(u32, 2), stats.active_contents);
}

test "getStats: 过期记录不计入活跃数量" {
    var storage = try Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer storage.deinit();

    const now = std.time.timestamp();

    // 插入 1 条已过期记录
    const insert_sql =
        \\INSERT INTO contents (id, type, text_body, destroy_mode, destroy_value, view_count, created_at, expires_at)
        \\VALUES ('expired_stats_test_01a', 'text', 'old', 'time', 60, 0, ?, ?);
    ;
    {
        var stmt: ?*c.sqlite3_stmt = null;
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(storage.db.?, insert_sql, -1, &stmt, null));
        defer _ = c.sqlite3_finalize(stmt);
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_int64(stmt.?, 1, now - 3600));
        try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_bind_int64(stmt.?, 2, now - 100));
        try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(stmt.?));
    }

    // 创建 1 条未过期记录
    _ = try storage.createShare(.{
        .content_type = .text,
        .text_body = "active",
        .destroy_mode = .time,
        .destroy_value = 3600,
    });

    const stats = storage.getStats();
    // 只有 1 条活跃
    try std.testing.expectEqual(@as(u32, 1), stats.active_contents);
}
