const std = @import("std");
const types = @import("types.zig");

const c = @cImport({
    @cDefine("SQLITE_ENABLE_FTS5", "1");
    @cInclude("sqlite3.h");
});

pub const MemoryCategory = types.MemoryCategory;
pub const MemoryEntry = types.MemoryEntry;
pub const ExportFilter = types.ExportFilter;
pub const MemoryError = types.MemoryError;

const EntryColumns =
    "id, key, content, category, created_at, session_id, namespace, importance, superseded_by";
const DefaultListLimit: i64 = 1000;

const ScoredId = struct {
    id: []u8,
    score: f64,

    fn deinit(self: *ScoredId, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        self.* = undefined;
    }
};

pub const SqliteMemory = struct {
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    db_path: []u8,
    stmt_cache: std.StringHashMap(*c.sqlite3_stmt),
    mutex: std.Thread.Mutex = .{},

    pub fn new(allocator: std.mem.Allocator, workspace_dir: []const u8) !SqliteMemory {
        return newNamed(allocator, workspace_dir, "brain");
    }

    pub fn newNamed(
        allocator: std.mem.Allocator,
        workspace_dir: []const u8,
        db_name: []const u8,
    ) !SqliteMemory {
        const memory_dir = try std.fs.path.join(allocator, &.{ workspace_dir, "memory" });
        defer allocator.free(memory_dir);
        try std.fs.cwd().makePath(memory_dir);

        const db_file = try std.fmt.allocPrint(allocator, "{s}.db", .{db_name});
        defer allocator.free(db_file);
        const db_path = try std.fs.path.join(allocator, &.{ memory_dir, db_file });
        errdefer allocator.free(db_path);

        var db_opt: ?*c.sqlite3 = null;
        const path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(path_z);
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(path_z.ptr, &db_opt, flags, null) != c.SQLITE_OK) {
            if (db_opt) |db| _ = c.sqlite3_close(db);
            return MemoryError.Sqlite;
        }

        var self = SqliteMemory{
            .allocator = allocator,
            .db = db_opt.?,
            .db_path = db_path,
            .stmt_cache = std.StringHashMap(*c.sqlite3_stmt).init(allocator),
        };
        errdefer self.deinit();

        try self.execBatch(
            \\PRAGMA journal_mode = WAL;
            \\PRAGMA synchronous  = NORMAL;
            \\PRAGMA mmap_size    = 8388608;
            \\PRAGMA cache_size   = -2000;
            \\PRAGMA temp_store   = MEMORY;
        );
        try self.initSchema();
        return self;
    }

    pub fn deinit(self: *SqliteMemory) void {
        self.mutex.lock();
        self.finalizeCachedStatements();
        _ = c.sqlite3_close(self.db);
        self.allocator.free(self.db_path);
        self.mutex.unlock();
        self.* = undefined;
    }

    pub fn name(_: *SqliteMemory) []const u8 {
        return "sqlite";
    }

    pub fn store(
        self: *SqliteMemory,
        allocator: std.mem.Allocator,
        key: []const u8,
        content: []const u8,
        category: MemoryCategory,
        session_id: ?[]const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = try self.currentTimestamp(allocator);
        defer allocator.free(now);
        const id = try newUuid(allocator);
        defer allocator.free(id);
        const cat = category.asString();

        const stmt = try self.cachedPrepare(
            \\INSERT INTO memories (id, key, content, category, embedding, created_at, updated_at, session_id, namespace, importance)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'default', 0.5)
            \\ON CONFLICT(key) DO UPDATE SET
            \\   content = excluded.content,
            \\   category = excluded.category,
            \\   embedding = excluded.embedding,
            \\   updated_at = excluded.updated_at,
            \\   session_id = excluded.session_id
        );
        try bindText(stmt, 1, id);
        try bindText(stmt, 2, key);
        try bindText(stmt, 3, content);
        try bindText(stmt, 4, cat);
        try bindNull(stmt, 5);
        try bindText(stmt, 6, now);
        try bindText(stmt, 7, now);
        try bindOptionalText(stmt, 8, session_id);
        try expectDone(stmt);
    }

    pub fn storeWithMetadata(
        self: *SqliteMemory,
        allocator: std.mem.Allocator,
        key: []const u8,
        content: []const u8,
        category: MemoryCategory,
        session_id: ?[]const u8,
        namespace: ?[]const u8,
        importance: ?f64,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = try self.currentTimestamp(allocator);
        defer allocator.free(now);
        const id = try newUuid(allocator);
        defer allocator.free(id);
        const cat = category.asString();
        const ns = namespace orelse "default";
        const imp = importance orelse 0.5;

        const stmt = try self.cachedPrepare(
            \\INSERT INTO memories (id, key, content, category, embedding, created_at, updated_at, session_id, namespace, importance)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            \\ON CONFLICT(key) DO UPDATE SET
            \\   content = excluded.content,
            \\   category = excluded.category,
            \\   embedding = excluded.embedding,
            \\   updated_at = excluded.updated_at,
            \\   session_id = excluded.session_id,
            \\   namespace = excluded.namespace,
            \\   importance = excluded.importance
        );
        try bindText(stmt, 1, id);
        try bindText(stmt, 2, key);
        try bindText(stmt, 3, content);
        try bindText(stmt, 4, cat);
        try bindNull(stmt, 5);
        try bindText(stmt, 6, now);
        try bindText(stmt, 7, now);
        try bindOptionalText(stmt, 8, session_id);
        try bindText(stmt, 9, ns);
        try bindDouble(stmt, 10, imp);
        try expectDone(stmt);
    }

    pub fn recall(
        self: *SqliteMemory,
        allocator: std.mem.Allocator,
        query: []const u8,
        limit: usize,
        session_id: ?[]const u8,
        since: ?[]const u8,
        until: ?[]const u8,
    ) ![]MemoryEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (std.mem.trim(u8, query, " \t\r\n").len == 0) {
            return self.recallByTimeOnly(allocator, limit, session_id, since, until);
        }

        var results = std.ArrayList(MemoryEntry).init(allocator);
        errdefer freeEntryList(allocator, &results);

        const scored = self.fts5Search(allocator, query, limit * 2) catch blk: {
            break :blk try allocator.alloc(ScoredId, 0);
        };
        defer freeScoredSlice(allocator, scored);

        for (scored) |item| {
            if (try self.getById(allocator, item.id, item.score)) |entry| {
                var owned = entry;
                errdefer owned.deinit(allocator);
                if (since) |value| {
                    if (std.mem.order(u8, owned.timestamp, value) == .lt) {
                        owned.deinit(allocator);
                        continue;
                    }
                }
                if (until) |value| {
                    if (std.mem.order(u8, owned.timestamp, value) == .gt) {
                        owned.deinit(allocator);
                        continue;
                    }
                }
                if (session_id) |sid| {
                    if (owned.session_id == null or !std.mem.eql(u8, owned.session_id.?, sid)) {
                        owned.deinit(allocator);
                        continue;
                    }
                }
                try results.append(owned);
            }
        }

        if (results.items.len == 0) {
            try self.likeFallback(allocator, &results, query, limit, session_id, since, until);
        }

        if (results.items.len > limit) {
            for (results.items[limit..]) |*entry| entry.deinit(allocator);
            results.shrinkRetainingCapacity(limit);
        }
        return results.toOwnedSlice();
    }

    pub fn recallNamespaced(
        self: *SqliteMemory,
        allocator: std.mem.Allocator,
        namespace: []const u8,
        query: []const u8,
        limit: usize,
        session_id: ?[]const u8,
        since: ?[]const u8,
        until: ?[]const u8,
    ) ![]MemoryEntry {
        const entries = try self.recall(allocator, query, limit * 2, session_id, since, until);
        defer allocator.free(entries);

        var filtered = std.ArrayList(MemoryEntry).init(allocator);
        errdefer freeEntryList(allocator, &filtered);
        for (entries) |*entry| {
            if (filtered.items.len >= limit) {
                entry.deinit(allocator);
                continue;
            }
            if (std.mem.eql(u8, entry.namespace, namespace)) {
                try filtered.append(entry.*);
                entry.* = undefined;
            } else {
                entry.deinit(allocator);
            }
        }
        return filtered.toOwnedSlice();
    }

    pub fn get(
        self: *SqliteMemory,
        allocator: std.mem.Allocator,
        key: []const u8,
    ) !?MemoryEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stmt = try self.cachedPrepare(
            "SELECT " ++ EntryColumns ++ " FROM memories WHERE key = ?1",
        );
        try bindText(stmt, 1, key);

        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return MemoryError.Sqlite;
        return try rowToEntry(allocator, stmt, null);
    }

    pub fn list(
        self: *SqliteMemory,
        allocator: std.mem.Allocator,
        category: ?MemoryCategory,
        session_id: ?[]const u8,
    ) ![]MemoryEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        var results = std.ArrayList(MemoryEntry).init(allocator);
        errdefer freeEntryList(allocator, &results);

        if (category) |cat| {
            const stmt = try self.cachedPrepare("SELECT " ++ EntryColumns ++
                \\ FROM memories
                \\ WHERE superseded_by IS NULL AND category = ?1 ORDER BY updated_at DESC LIMIT ?2
            );
            try bindText(stmt, 1, cat.asString());
            try bindInt64(stmt, 2, DefaultListLimit);
            try collectRows(allocator, stmt, &results, null, session_id);
        } else {
            const stmt = try self.cachedPrepare("SELECT " ++ EntryColumns ++
                \\ FROM memories
                \\ WHERE superseded_by IS NULL ORDER BY updated_at DESC LIMIT ?1
            );
            try bindInt64(stmt, 1, DefaultListLimit);
            try collectRows(allocator, stmt, &results, null, session_id);
        }

        return results.toOwnedSlice();
    }

    pub fn forget(self: *SqliteMemory, key: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stmt = try self.cachedPrepare("DELETE FROM memories WHERE key = ?1");
        try bindText(stmt, 1, key);
        try expectDone(stmt);
        return c.sqlite3_changes(self.db) > 0;
    }

    pub fn purgeNamespace(self: *SqliteMemory, namespace: []const u8) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stmt = try self.cachedPrepare("DELETE FROM memories WHERE category = ?1");
        try bindText(stmt, 1, namespace);
        try expectDone(stmt);
        return @intCast(c.sqlite3_changes(self.db));
    }

    pub fn purgeSession(self: *SqliteMemory, session_id: []const u8) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stmt = try self.cachedPrepare("DELETE FROM memories WHERE session_id = ?1");
        try bindText(stmt, 1, session_id);
        try expectDone(stmt);
        return @intCast(c.sqlite3_changes(self.db));
    }

    pub fn count(self: *SqliteMemory) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stmt = try self.cachedPrepare("SELECT COUNT(*) FROM memories");
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return MemoryError.Sqlite;
        return @intCast(c.sqlite3_column_int64(stmt, 0));
    }

    pub fn healthCheck(self: *SqliteMemory) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stmt = self.cachedPrepare("SELECT 1") catch return false;
        return c.sqlite3_step(stmt) == c.SQLITE_ROW;
    }

    pub fn exportEntries(
        self: *SqliteMemory,
        allocator: std.mem.Allocator,
        filter: ExportFilter,
    ) ![]MemoryEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        var sql = std.ArrayList(u8).init(allocator);
        defer sql.deinit();
        try sql.appendSlice("SELECT " ++ EntryColumns ++ " FROM memories WHERE 1=1");

        var param_idx: c_int = 1;
        const ns_idx = try appendTextFilter(&sql, &param_idx, "namespace", filter.namespace);
        const sid_idx = try appendTextFilter(&sql, &param_idx, "session_id", filter.session_id);
        var cat_idx: ?c_int = null;
        if (filter.category) |_| {
            try sql.writer().print(" AND category = ?{d}", .{param_idx});
            cat_idx = param_idx;
            param_idx += 1;
        }
        const since_idx = try appendTextFilterOp(&sql, &param_idx, "created_at", ">=", filter.since);
        const until_idx = try appendTextFilterOp(&sql, &param_idx, "created_at", "<=", filter.until);
        try sql.appendSlice(" ORDER BY created_at ASC");

        const stmt = try self.cachedPrepare(sql.items);
        if (ns_idx) |idx| try bindText(stmt, idx, filter.namespace.?);
        if (sid_idx) |idx| try bindText(stmt, idx, filter.session_id.?);
        if (cat_idx) |idx| try bindText(stmt, idx, filter.category.?.asString());
        if (since_idx) |idx| try bindText(stmt, idx, filter.since.?);
        if (until_idx) |idx| try bindText(stmt, idx, filter.until.?);

        var results = std.ArrayList(MemoryEntry).init(allocator);
        errdefer freeEntryList(allocator, &results);
        try collectRows(allocator, stmt, &results, null, null);
        return results.toOwnedSlice();
    }

    fn initSchema(self: *SqliteMemory) !void {
        try self.execBatch(
            \\-- Core memories table
            \\CREATE TABLE IF NOT EXISTS memories (
            \\    id          TEXT PRIMARY KEY,
            \\    key         TEXT NOT NULL UNIQUE,
            \\    content     TEXT NOT NULL,
            \\    category    TEXT NOT NULL DEFAULT 'core',
            \\    embedding   BLOB,
            \\    created_at  TEXT NOT NULL,
            \\    updated_at  TEXT NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_memories_category ON memories(category);
            \\CREATE INDEX IF NOT EXISTS idx_memories_key ON memories(key);
            \\
            \\-- FTS5 full-text search (BM25 scoring)
            \\CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
            \\    key, content, content=memories, content_rowid=rowid
            \\);
            \\
            \\-- FTS5 triggers: keep in sync with memories table
            \\CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
            \\    INSERT INTO memories_fts(rowid, key, content)
            \\    VALUES (new.rowid, new.key, new.content);
            \\END;
            \\CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
            \\    INSERT INTO memories_fts(memories_fts, rowid, key, content)
            \\    VALUES ('delete', old.rowid, old.key, old.content);
            \\END;
            \\CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
            \\    INSERT INTO memories_fts(memories_fts, rowid, key, content)
            \\    VALUES ('delete', old.rowid, old.key, old.content);
            \\    INSERT INTO memories_fts(rowid, key, content)
            \\    VALUES (new.rowid, new.key, new.content);
            \\END;
            \\
            \\-- Embedding cache with LRU eviction
            \\CREATE TABLE IF NOT EXISTS embedding_cache (
            \\    content_hash TEXT PRIMARY KEY,
            \\    embedding    BLOB NOT NULL,
            \\    created_at   TEXT NOT NULL,
            \\    accessed_at  TEXT NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_cache_accessed ON embedding_cache(accessed_at);
        );

        const schema_sql = try self.scalarText(
            self.allocator,
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='memories'",
        );
        defer self.allocator.free(schema_sql);

        if (std.mem.indexOf(u8, schema_sql, "session_id") == null) {
            try self.execBatch(
                \\ALTER TABLE memories ADD COLUMN session_id TEXT;
                \\CREATE INDEX IF NOT EXISTS idx_memories_session ON memories(session_id);
            );
        }
        if (std.mem.indexOf(u8, schema_sql, "namespace") == null) {
            try self.execBatch(
                \\ALTER TABLE memories ADD COLUMN namespace TEXT DEFAULT 'default';
                \\CREATE INDEX IF NOT EXISTS idx_memories_namespace ON memories(namespace);
            );
        }
        if (std.mem.indexOf(u8, schema_sql, "importance") == null) {
            try self.execBatch("ALTER TABLE memories ADD COLUMN importance REAL DEFAULT 0.5;");
        }
        if (std.mem.indexOf(u8, schema_sql, "superseded_by") == null) {
            try self.execBatch("ALTER TABLE memories ADD COLUMN superseded_by TEXT;");
        }
    }

    fn recallByTimeOnly(
        self: *SqliteMemory,
        allocator: std.mem.Allocator,
        limit: usize,
        session_id: ?[]const u8,
        since: ?[]const u8,
        until: ?[]const u8,
    ) ![]MemoryEntry {
        var sql = std.ArrayList(u8).init(allocator);
        defer sql.deinit();
        try sql.appendSlice(
            "SELECT " ++ EntryColumns ++ " FROM memories WHERE superseded_by IS NULL AND 1=1",
        );
        var param_idx: c_int = 1;
        const sid_idx = try appendTextFilter(&sql, &param_idx, "session_id", session_id);
        const since_idx = try appendTextFilterOp(&sql, &param_idx, "created_at", ">=", since);
        const until_idx = try appendTextFilterOp(&sql, &param_idx, "created_at", "<=", until);
        try sql.writer().print(" ORDER BY updated_at DESC LIMIT ?{d}", .{param_idx});
        const limit_idx = param_idx;

        const stmt = try self.cachedPrepare(sql.items);
        if (sid_idx) |idx| try bindText(stmt, idx, session_id.?);
        if (since_idx) |idx| try bindText(stmt, idx, since.?);
        if (until_idx) |idx| try bindText(stmt, idx, until.?);
        try bindInt64(stmt, limit_idx, @intCast(limit));

        var results = std.ArrayList(MemoryEntry).init(allocator);
        errdefer freeEntryList(allocator, &results);
        try collectRows(allocator, stmt, &results, null, null);
        return results.toOwnedSlice();
    }

    fn fts5Search(
        self: *SqliteMemory,
        allocator: std.mem.Allocator,
        query: []const u8,
        limit: usize,
    ) ![]ScoredId {
        var fts_query = std.ArrayList(u8).init(allocator);
        defer fts_query.deinit();

        var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
        var first = true;
        while (words.next()) |word| {
            if (!first) try fts_query.appendSlice(" OR ");
            first = false;
            try fts_query.append('"');
            try fts_query.appendSlice(word);
            try fts_query.append('"');
        }
        if (fts_query.items.len == 0) return try allocator.alloc(ScoredId, 0);

        const stmt = try self.cachedPrepare(
            \\SELECT m.id, bm25(memories_fts) as score
            \\FROM memories_fts f
            \\JOIN memories m ON m.rowid = f.rowid
            \\WHERE memories_fts MATCH ?1
            \\ORDER BY score
            \\LIMIT ?2
        );
        try bindText(stmt, 1, fts_query.items);
        try bindInt64(stmt, 2, @intCast(limit));

        var results = std.ArrayList(ScoredId).init(allocator);
        errdefer {
            for (results.items) |*item| item.deinit(allocator);
            results.deinit();
        }

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return MemoryError.Sqlite;
            const id = try columnTextDup(allocator, stmt, 0);
            errdefer allocator.free(id);
            const score_f32: f32 = @floatCast(-c.sqlite3_column_double(stmt, 1));
            const score: f64 = score_f32;
            try results.append(.{ .id = id, .score = score });
        }
        return results.toOwnedSlice();
    }

    fn getById(
        self: *SqliteMemory,
        allocator: std.mem.Allocator,
        id: []const u8,
        score: f64,
    ) !?MemoryEntry {
        const stmt = try self.cachedPrepare(
            "SELECT " ++ EntryColumns ++
                " FROM memories WHERE superseded_by IS NULL AND id = ?1",
        );
        try bindText(stmt, 1, id);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return MemoryError.Sqlite;
        return try rowToEntry(allocator, stmt, score);
    }

    fn likeFallback(
        self: *SqliteMemory,
        allocator: std.mem.Allocator,
        results: *std.ArrayList(MemoryEntry),
        query: []const u8,
        limit: usize,
        session_id: ?[]const u8,
        since: ?[]const u8,
        until: ?[]const u8,
    ) !void {
        var patterns = std.ArrayList([]u8).init(allocator);
        defer {
            for (patterns.items) |pattern| allocator.free(pattern);
            patterns.deinit();
        }

        var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
        while (words.next()) |word| {
            if (patterns.items.len >= 8) break;
            try patterns.append(try std.fmt.allocPrint(allocator, "%{s}%", .{word}));
        }
        if (patterns.items.len == 0) return;

        var sql = std.ArrayList(u8).init(allocator);
        defer sql.deinit();
        try sql.appendSlice(
            "SELECT " ++ EntryColumns ++ " FROM memories WHERE superseded_by IS NULL AND (",
        );
        var param_idx: c_int = 1;
        for (patterns.items, 0..) |_, i| {
            if (i != 0) try sql.appendSlice(" OR ");
            try sql.writer().print(
                "(content LIKE ?{d} OR key LIKE ?{d})",
                .{ param_idx, param_idx + 1 },
            );
            param_idx += 2;
        }
        try sql.append(')');
        const since_idx = try appendTextFilterOp(&sql, &param_idx, "created_at", ">=", since);
        const until_idx = try appendTextFilterOp(&sql, &param_idx, "created_at", "<=", until);
        try sql.writer().print(" ORDER BY updated_at DESC LIMIT ?{d}", .{param_idx});
        const limit_idx = param_idx;

        const stmt = try self.cachedPrepare(sql.items);
        var bind_idx: c_int = 1;
        for (patterns.items) |pattern| {
            try bindText(stmt, bind_idx, pattern);
            bind_idx += 1;
            try bindText(stmt, bind_idx, pattern);
            bind_idx += 1;
        }
        if (since_idx) |idx| try bindText(stmt, idx, since.?);
        if (until_idx) |idx| try bindText(stmt, idx, until.?);
        try bindInt64(stmt, limit_idx, @intCast(limit));

        try collectRows(allocator, stmt, results, 1.0, session_id);
    }

    fn execBatch(self: *SqliteMemory, sql: [:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql.ptr, null, null, &err_msg);
        if (err_msg != null) c.sqlite3_free(err_msg);
        if (rc != c.SQLITE_OK) return MemoryError.Sqlite;
    }

    fn prepare(self: *SqliteMemory, sql: []const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(
            self.db,
            sql.ptr,
            @intCast(sql.len),
            &stmt,
            null,
        );
        if (rc != c.SQLITE_OK) return MemoryError.Sqlite;
        return stmt.?;
    }

    fn cachedPrepare(self: *SqliteMemory, sql: []const u8) !*c.sqlite3_stmt {
        if (self.stmt_cache.get(sql)) |stmt| {
            if (c.sqlite3_reset(stmt) != c.SQLITE_OK) return MemoryError.Sqlite;
            if (c.sqlite3_clear_bindings(stmt) != c.SQLITE_OK) return MemoryError.Sqlite;
            return stmt;
        }

        const key = try self.allocator.dupe(u8, sql);
        errdefer self.allocator.free(key);
        const stmt = try self.prepare(sql);
        errdefer finalize(stmt);
        try self.stmt_cache.put(key, stmt);
        return stmt;
    }

    fn finalizeCachedStatements(self: *SqliteMemory) void {
        var iterator = self.stmt_cache.iterator();
        while (iterator.next()) |entry| {
            finalize(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.stmt_cache.deinit();
    }

    fn scalarText(
        self: *SqliteMemory,
        allocator: std.mem.Allocator,
        sql: []const u8,
    ) ![]u8 {
        const stmt = try self.cachedPrepare(sql);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return MemoryError.Sqlite;
        return columnTextDup(allocator, stmt, 0);
    }

    fn currentTimestamp(self: *SqliteMemory, allocator: std.mem.Allocator) ![]u8 {
        return self.scalarText(allocator, "SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now')");
    }
};

pub fn contentHash(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const first = std.mem.readInt(u64, digest[0..8], .big);
    return std.fmt.allocPrint(allocator, "{x:0>16}", .{first});
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []MemoryEntry) void {
    for (entries) |*entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn finalize(stmt: *c.sqlite3_stmt) void {
    _ = c.sqlite3_finalize(stmt);
}

fn bindText(stmt: *c.sqlite3_stmt, idx: c_int, value: []const u8) !void {
    const rc = c.sqlite3_bind_text(
        stmt,
        idx,
        value.ptr,
        @intCast(value.len),
        c.SQLITE_TRANSIENT,
    );
    if (rc != c.SQLITE_OK) return MemoryError.Sqlite;
}

fn bindOptionalText(stmt: *c.sqlite3_stmt, idx: c_int, value: ?[]const u8) !void {
    if (value) |text| {
        try bindText(stmt, idx, text);
    } else {
        try bindNull(stmt, idx);
    }
}

fn bindNull(stmt: *c.sqlite3_stmt, idx: c_int) !void {
    if (c.sqlite3_bind_null(stmt, idx) != c.SQLITE_OK) return MemoryError.Sqlite;
}

fn bindInt64(stmt: *c.sqlite3_stmt, idx: c_int, value: i64) !void {
    if (c.sqlite3_bind_int64(stmt, idx, value) != c.SQLITE_OK) return MemoryError.Sqlite;
}

fn bindDouble(stmt: *c.sqlite3_stmt, idx: c_int, value: f64) !void {
    if (c.sqlite3_bind_double(stmt, idx, value) != c.SQLITE_OK) return MemoryError.Sqlite;
}

fn expectDone(stmt: *c.sqlite3_stmt) !void {
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return MemoryError.Sqlite;
}

fn columnTextDup(
    allocator: std.mem.Allocator,
    stmt: *c.sqlite3_stmt,
    col: c_int,
) ![]u8 {
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    const ptr = c.sqlite3_column_text(stmt, col);
    if (ptr == null) return try allocator.alloc(u8, 0);
    const bytes: [*]const u8 = @ptrCast(ptr);
    return allocator.dupe(u8, bytes[0..len]);
}

fn columnOptionalTextDup(
    allocator: std.mem.Allocator,
    stmt: *c.sqlite3_stmt,
    col: c_int,
) !?[]u8 {
    if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
    return try columnTextDup(allocator, stmt, col);
}

fn rowToEntry(
    allocator: std.mem.Allocator,
    stmt: *c.sqlite3_stmt,
    score: ?f64,
) !MemoryEntry {
    const id = try columnTextDup(allocator, stmt, 0);
    errdefer allocator.free(id);
    const key = try columnTextDup(allocator, stmt, 1);
    errdefer allocator.free(key);
    const content = try columnTextDup(allocator, stmt, 2);
    errdefer allocator.free(content);
    const cat_str = try columnTextDup(allocator, stmt, 3);
    defer allocator.free(cat_str);
    var category = try MemoryCategory.fromString(allocator, cat_str);
    errdefer category.deinit(allocator);
    const timestamp = try columnTextDup(allocator, stmt, 4);
    errdefer allocator.free(timestamp);
    const session_id = try columnOptionalTextDup(allocator, stmt, 5);
    errdefer if (session_id) |value| allocator.free(value);
    const namespace_opt = try columnOptionalTextDup(allocator, stmt, 6);
    errdefer if (namespace_opt) |value| allocator.free(value);
    const importance: ?f64 = if (c.sqlite3_column_type(stmt, 7) == c.SQLITE_NULL)
        null
    else
        c.sqlite3_column_double(stmt, 7);
    const superseded_by = try columnOptionalTextDup(allocator, stmt, 8);
    errdefer if (superseded_by) |value| allocator.free(value);

    return .{
        .id = id,
        .key = key,
        .content = content,
        .category = category,
        .timestamp = timestamp,
        .session_id = session_id,
        .score = score,
        .namespace = namespace_opt orelse try allocator.dupe(u8, "default"),
        .importance = importance,
        .superseded_by = superseded_by,
    };
}

fn collectRows(
    allocator: std.mem.Allocator,
    stmt: *c.sqlite3_stmt,
    results: *std.ArrayList(MemoryEntry),
    score: ?f64,
    session_filter: ?[]const u8,
) !void {
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return MemoryError.Sqlite;
        var entry = try rowToEntry(allocator, stmt, score);
        errdefer entry.deinit(allocator);
        if (session_filter) |sid| {
            if (entry.session_id == null or !std.mem.eql(u8, entry.session_id.?, sid)) {
                entry.deinit(allocator);
                continue;
            }
        }
        try results.append(entry);
    }
}

fn appendTextFilter(
    sql: *std.ArrayList(u8),
    param_idx: *c_int,
    column: []const u8,
    value: ?[]const u8,
) !?c_int {
    if (value == null) return null;
    try sql.writer().print(" AND {s} = ?{d}", .{ column, param_idx.* });
    const idx = param_idx.*;
    param_idx.* += 1;
    return idx;
}

fn appendTextFilterOp(
    sql: *std.ArrayList(u8),
    param_idx: *c_int,
    column: []const u8,
    op: []const u8,
    value: ?[]const u8,
) !?c_int {
    if (value == null) return null;
    try sql.writer().print(" AND {s} {s} ?{d}", .{ column, op, param_idx.* });
    const idx = param_idx.*;
    param_idx.* += 1;
    return idx;
}

fn freeEntryList(allocator: std.mem.Allocator, list: *std.ArrayList(MemoryEntry)) void {
    for (list.items) |*entry| entry.deinit(allocator);
    list.deinit();
}

fn freeScoredSlice(allocator: std.mem.Allocator, items: []ScoredId) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn newUuid(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var out = try allocator.alloc(u8, 36);
    var j: usize = 0;
    for (bytes, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[j] = '-';
            j += 1;
        }
        out[j] = hex[byte >> 4];
        out[j + 1] = hex[byte & 0x0f];
        j += 2;
    }
    return out;
}

test "content hash matches Rust shape" {
    const allocator = std.testing.allocator;
    const hash = try contentHash(allocator, "hello");
    defer allocator.free(hash);
    try std.testing.expectEqual(@as(usize, 16), hash.len);
}
