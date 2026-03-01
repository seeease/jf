/// HTTP Handler
/// 处理各路由的请求逻辑
const std = @import("std");
const storage = @import("storage.zig");
const router = @import("router.zig");

pub const Response = router.Response;

/// Web UI HTML 页面（编译时嵌入）
/// 包含：类型选择、销毁模式选择（数值+单位）、提交按钮、Tailwind CSS
const web_ui_html =
    \\<!DOCTYPE html>
    \\<html lang="zh">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width,initial-scale=1">
    \\<title>即焚</title>
    \\<script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>
    \\</head>
    \\<body class="bg-gray-50 min-h-screen flex items-center justify-center p-4">
    \\<div class="w-full max-w-md">
    \\<h1 class="text-3xl font-bold text-center text-gray-800 mb-6">jfai <span class="text-sm font-normal text-gray-400">即焚AI</span></h1>
    \\<div class="bg-white rounded-xl shadow-lg p-6 space-y-5">
    \\<div>
    \\<label class="block text-sm font-medium text-gray-700 mb-1">分享类型</label>
    \\<div class="flex gap-2">
    \\<button onclick="setType('text')" id="btnText" class="flex-1 py-2 px-4 rounded-lg text-sm font-medium bg-blue-500 text-white transition">文字</button>
    \\<button onclick="setType('file')" id="btnFile" class="flex-1 py-2 px-4 rounded-lg text-sm font-medium bg-gray-100 text-gray-600 hover:bg-gray-200 transition">文件</button>
    \\</div>
    \\</div>
    \\<div id="textArea">
    \\<label class="block text-sm font-medium text-gray-700 mb-1">文字内容</label>
    \\<textarea id="content" rows="5" class="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:ring-2 focus:ring-blue-500 focus:border-transparent resize-vertical" placeholder="输入要分享的文字..."></textarea>
    \\</div>
    \\<div id="fileArea" class="hidden">
    \\<label class="block text-sm font-medium text-gray-700 mb-1">选择文件</label>
    \\<input type="file" id="file" class="w-full text-sm text-gray-500 file:mr-4 file:py-2 file:px-4 file:rounded-lg file:border-0 file:text-sm file:font-medium file:bg-blue-50 file:text-blue-700 hover:file:bg-blue-100">
    \\</div>
    \\<div>
    \\<label class="block text-sm font-medium text-gray-700 mb-2">销毁条件</label>
    \\<div class="flex items-center gap-2">
    \\<select id="destroyValue" class="flex-1 px-3 py-2 border border-gray-300 rounded-lg text-sm focus:ring-2 focus:ring-blue-500">
    \\<option value="1">1</option>
    \\<option value="2">2</option>
    \\<option value="4">4</option>
    \\<option value="8">8</option>
    \\<option value="16">16</option>
    \\</select>
    \\<select id="destroyUnit" class="flex-1 px-3 py-2 border border-gray-300 rounded-lg text-sm focus:ring-2 focus:ring-blue-500">
    \\<option value="min">分钟后销毁</option>
    \\<option value="count">次后销毁</option>
    \\</select>
    \\</div>
    \\</div>
    \\<button onclick="doSubmit()" class="w-full py-3 bg-blue-500 hover:bg-blue-600 text-white font-medium rounded-lg transition">创建分享</button>
    \\<div id="error" class="hidden text-sm text-red-600 bg-red-50 p-3 rounded-lg"></div>
    \\<div id="result" class="hidden text-sm bg-green-50 p-3 rounded-lg"></div>
    \\</div>
    \\</div>
    \\<script>
    \\var curType='text';
    \\function setType(t){
    \\curType=t;
    \\document.getElementById('textArea').className=t==='text'?'':'hidden';
    \\document.getElementById('fileArea').className=t==='file'?'':'hidden';
    \\document.getElementById('btnText').className='flex-1 py-2 px-4 rounded-lg text-sm font-medium transition '+(t==='text'?'bg-blue-500 text-white':'bg-gray-100 text-gray-600 hover:bg-gray-200');
    \\document.getElementById('btnFile').className='flex-1 py-2 px-4 rounded-lg text-sm font-medium transition '+(t==='file'?'bg-blue-500 text-white':'bg-gray-100 text-gray-600 hover:bg-gray-200');
    \\}
    \\function doSubmit(){
    \\var dv=parseInt(document.getElementById('destroyValue').value);
    \\var unit=document.getElementById('destroyUnit').value;
    \\var dm=unit==='min'?'time':'count';
    \\var val=unit==='min'?dv*60:dv;
    \\var errEl=document.getElementById('error');
    \\var resEl=document.getElementById('result');
    \\errEl.className='hidden';resEl.className='hidden';
    \\if(curType==='text'){
    \\var c=document.getElementById('content').value.trim();
    \\if(!c){showErr('内容不能为空');return;}
    \\send({type:'text',content:c,destroy_mode:dm,destroy_value:val});
    \\}else{
    \\var f=document.getElementById('file').files[0];
    \\if(!f){showErr('请选择文件');return;}
    \\var r=new FileReader();
    \\r.onload=function(){
    \\var u8=new Uint8Array(r.result);var s='';for(var i=0;i<u8.length;i+=8192){s+=String.fromCharCode.apply(null,u8.subarray(i,Math.min(i+8192,u8.length)));}
    \\send({type:'file',content:btoa(s),destroy_mode:dm,destroy_value:val,file_name:f.name,mime_type:f.type||'application/octet-stream'});
    \\};r.readAsArrayBuffer(f);
    \\}
    \\}
    \\function showErr(msg){var e=document.getElementById('error');e.textContent=msg;e.className='text-sm text-red-600 bg-red-50 p-3 rounded-lg';}
    \\function send(data){
    \\fetch('api/share',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)})
    \\.then(function(r){if(!r.ok&&r.status!==400&&r.status!==413){throw new Error('HTTP '+r.status);}return r.json();})
    \\.then(function(j){
    \\if(j.error){showErr(j.error);return;}
    \\var link=location.origin+j.share_link;
    \\var el=document.getElementById('result');
    \\el.innerHTML='<span class="text-green-700">分享链接：</span><a href="'+link+'" target="_blank" class="text-blue-600 underline break-all">'+link+'</a>';
    \\el.className='text-sm bg-green-50 p-3 rounded-lg';
    \\}).catch(function(e){showErr('请求失败: '+e.message);});
    \\}
    \\</script>
    \\</body>
    \\</html>
;

pub const Handler = struct {
    store: *storage.Storage,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, store: *storage.Storage) Handler {
        return .{ .store = store, .allocator = allocator };
    }

    /// POST /api/share — 创建分享
    /// 接受 JSON 请求体，支持文字和 base64 编码的文件
    pub fn handleCreateShare(self: *Handler, body: ?[]const u8) Response {
        const raw = body orelse return jsonError(400, "{\"error\":\"request body is empty\"}");
        if (raw.len == 0) return jsonError(400, "{\"error\":\"request body is empty\"}");

        // 解析 JSON
        const parsed = std.json.parseFromSlice(ShareRequest, self.allocator, raw, .{
            .ignore_unknown_fields = true,
        }) catch {
            return jsonError(400, "{\"error\":\"invalid JSON\"}");
        };
        defer parsed.deinit();
        const req = parsed.value;

        // 校验 destroy_mode
        const destroy_mode: storage.DestroyMode = if (std.mem.eql(u8, req.destroy_mode, "count"))
            .count
        else if (std.mem.eql(u8, req.destroy_mode, "time"))
            .time
        else
            return jsonError(400, "{\"error\":\"invalid destroy mode\"}");

        // 构造 CreateParams
        var params = storage.CreateParams{
            .content_type = undefined,
            .destroy_mode = destroy_mode,
            .destroy_value = req.destroy_value,
        };

        if (std.mem.eql(u8, req.type, "text")) {
            params.content_type = .text;
            params.text_body = req.content orelse return jsonError(400, "{\"error\":\"content cannot be empty\"}");
            if (params.text_body.?.len == 0) return jsonError(400, "{\"error\":\"content cannot be empty\"}");
        } else if (std.mem.eql(u8, req.type, "file")) {
            params.content_type = .file;
            const b64 = req.content orelse return jsonError(400, "{\"error\":\"content cannot be empty\"}");
            if (b64.len == 0) return jsonError(400, "{\"error\":\"content cannot be empty\"}");

            // base64 解码
            const decoded = decodeBase64(self.allocator, b64) catch {
                return jsonError(400, "{\"error\":\"invalid base64 content\"}");
            };
            params.file_data = decoded;
            params.mime_type = req.mime_type orelse "application/octet-stream";
            params.file_name = req.file_name;
        } else {
            return jsonError(400, "{\"error\":\"invalid type, must be text or file\"}");
        }
        // file_data 由 storage 使用后需要释放
        defer if (params.file_data) |d| self.allocator.free(d);

        // 调用 storage
        const result = self.store.createShare(params) catch |err| switch (err) {
            error.EmptyContent => return jsonError(400, "{\"error\":\"content cannot be empty\"}"),
            error.FileTooLarge => return jsonError(413, "{\"error\":\"file too large\"}"),
            error.DestroyValueExceedsLimit => return jsonError(400, "{\"error\":\"destroy value exceeds limit\"}"),
            else => return jsonError(500, "{\"error\":\"internal error\"}"),
        };

        std.log.info("created share: id={s} type={s} mode={s} value={d}", .{
            &result.id,
            req.type,
            req.destroy_mode,
            req.destroy_value,
        });

        // 构造成功响应 JSON
        return self.buildSuccessResponse(&result.id) catch
            jsonError(500, "{\"error\":\"internal error\"}");
    }

    /// 构造创建成功的 JSON 响应（动态分配）
    fn buildSuccessResponse(self: *Handler, share_id: *const [22]u8) !Response {
        // {"share_link":"/s/XXXXXXXXXXXXXXXXXXXX","id":"XXXXXXXXXXXXXXXXXXXX"}
        // 固定部分长度: {"share_link":"/s/","id":""} = 29 字符 + 22*2 = 73
        const json = try std.fmt.allocPrint(self.allocator,
            \\{{"share_link":"s/{s}","id":"{s}"}}
        , .{ share_id, share_id });
        return Response{
            .status = 200,
            .content_type = "application/json",
            .body = json,
            .allocated = true,
        };
    }

    /// GET /s/{id} — 查看内容
    /// 文字类型渲染 HTML，文件类型返回二进制流，不存在返回 404
    pub fn handleViewContent(self: *Handler, content_id: []const u8) Response {
        var content = self.store.getContent(content_id) orelse {
            std.log.info("view share: id={s} result=not_found", .{content_id});
            return jsonError(404, "{\"error\":\"not found\"}");
        };

        std.log.info("view share: id={s} type={s}", .{
            content_id,
            if (content.content_type == .text) "text" else "file",
        });

        switch (content.content_type) {
            .text => {
                const text = content.text_body orelse {
                    self.store.freeContent(&content);
                    return jsonError(404, "{\"error\":\"not found\"}");
                };
                // 渲染简单 HTML 页面
                const html = std.fmt.allocPrint(self.allocator, "<html><body><pre>{s}</pre></body></html>", .{text}) catch {
                    self.store.freeContent(&content);
                    return jsonError(500, "{\"error\":\"internal error\"}");
                };
                // 释放 Content 中的分配内存（text_body 已复制到 html 中）
                self.store.freeContent(&content);
                return Response{
                    .status = 200,
                    .content_type = "text/html; charset=utf-8",
                    .body = html,
                    .allocated = true,
                };
            },
            .file => {
                const file_data = content.file_data orelse {
                    self.store.freeContent(&content);
                    return jsonError(404, "{\"error\":\"not found\"}");
                };
                const resp_mime = content.mime_type orelse "application/octet-stream";
                // 转移 file_data 和 mime_type 所有权给 Response
                content.file_data = null;
                content.mime_type = null;
                self.store.freeContent(&content);
                return Response{
                    .status = 200,
                    .content_type = resp_mime,
                    .body = file_data,
                    .allocated = true,
                    .content_type_allocated = true,
                };
            },
        }
    }

    /// GET /health — 健康检查
    /// 返回服务状态、活跃内容数和存储字节数
    pub fn handleHealth(self: *Handler) Response {
        const stats = self.store.getStats();
        const json = std.fmt.allocPrint(self.allocator,
            \\{{"status":"ok","active_contents":{d},"storage_bytes":{d}}}
        , .{ stats.active_contents, stats.storage_bytes }) catch
            return jsonError(500, "{\"error\":\"internal error\"}");
        return Response{
            .status = 200,
            .content_type = "application/json",
            .body = json,
            .allocated = true,
        };
    }

    /// GET / — Web UI
    /// 返回内嵌的 HTML 页面，包含创建分享的表单和前端交互逻辑
    pub fn handleWebUI(self: *Handler) Response {
        _ = self;
        return .{
            .status = 200,
            .content_type = "text/html; charset=utf-8",
            .body = web_ui_html,
        };
    }
};

/// JSON 请求体结构
const ShareRequest = struct {
    type: []const u8,
    content: ?[]const u8 = null,
    destroy_mode: []const u8,
    destroy_value: u64,
    file_name: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
};

/// 返回静态 JSON 错误响应
fn jsonError(status: u16, msg: []const u8) Response {
    return .{
        .status = status,
        .content_type = "application/json",
        .body = msg,
    };
}

/// base64 标准解码
fn decodeBase64(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(input) catch return error.InvalidBase64;
    const buf = try allocator.alloc(u8, size);
    decoder.decode(buf, input) catch {
        allocator.free(buf);
        return error.InvalidBase64;
    };
    return buf;
}

// ============ handleViewContent 测试 ============

test "handleViewContent: 文字类型返回 HTML 页面" {
    var store = try storage.Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer store.deinit();

    // 创建文字分享
    const result = try store.createShare(.{
        .content_type = .text,
        .text_body = "hello world",
        .destroy_mode = .time,
        .destroy_value = 3600,
    });

    var handler = Handler.init(std.testing.allocator, &store);
    const resp = handler.handleViewContent(&result.id);

    // 验证状态码 200
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    // 验证 Content-Type
    try std.testing.expectEqualStrings("text/html; charset=utf-8", resp.content_type);
    // 验证 HTML 包含原始文字
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "hello world") != null);
    // 验证 HTML 结构
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "<html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "<pre>") != null);
    // 释放分配的 body
    if (resp.allocated) std.testing.allocator.free(resp.body);
}

test "handleViewContent: 不存在的 ID 返回 404" {
    var store = try storage.Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer store.deinit();

    var handler = Handler.init(std.testing.allocator, &store);
    const resp = handler.handleViewContent("nonexistent_id_1234567");

    try std.testing.expectEqual(@as(u16, 404), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "not found") != null);
    // 静态字符串，不需要释放
    try std.testing.expect(!resp.allocated);
}

test "handleViewContent: 文字分享状态码 200" {
    var store = try storage.Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer store.deinit();

    const result = try store.createShare(.{
        .content_type = .text,
        .text_body = "测试中文内容",
        .destroy_mode = .count,
        .destroy_value = 5,
    });

    var handler = Handler.init(std.testing.allocator, &store);
    const resp = handler.handleViewContent(&result.id);

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(resp.allocated);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "测试中文内容") != null);
    if (resp.allocated) std.testing.allocator.free(resp.body);
}

// ============ handleHealth 测试 ============

test "handleHealth: 空存储返回 active_contents=0" {
    var store = try storage.Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer store.deinit();

    var handler = Handler.init(std.testing.allocator, &store);
    const resp = handler.handleHealth();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);
    // 验证 JSON 包含关键字段
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"active_contents\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"storage_bytes\":") != null);
    if (resp.allocated) std.testing.allocator.free(resp.body);
}

test "handleHealth: 创建分享后 active_contents 正确" {
    var store = try storage.Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer store.deinit();

    // 创建 2 个分享
    _ = try store.createShare(.{
        .content_type = .text,
        .text_body = "content 1",
        .destroy_mode = .time,
        .destroy_value = 3600,
    });
    _ = try store.createShare(.{
        .content_type = .text,
        .text_body = "content 2",
        .destroy_mode = .count,
        .destroy_value = 5,
    });

    var handler = Handler.init(std.testing.allocator, &store);
    const resp = handler.handleHealth();

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"active_contents\":2") != null);
    if (resp.allocated) std.testing.allocator.free(resp.body);
}
