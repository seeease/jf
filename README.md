# jfai — Burn After Reading

Self-destructing content sharing service. Single binary, zero external dependencies, written in Zig.

Share text or files via a unique link. Content is automatically destroyed by view count or time.

[中文文档](README_ZH.md)

## Features

- Text and file sharing with self-destructing links
- Two destroy modes: by view count or by TTL
- Max TTL as a safety net for all content
- Token bucket IP rate limiting
- Background cleanup of expired content
- Embedded Web UI, ready out of the box
- SQLite for metadata, filesystem for uploaded files
- Single binary deployment, no external database needed

## Build & Run

```bash
zig build
zig build run
# or
./zig-out/bin/jfai
```

## Deploy

### Docker

```bash
docker run -d --name jfai \
  -p 8080:8080 \
  -v jfai-data:/data \
  -e JFAI_DATA_DIR=/data \
  ghcr.io/seeease/jf:latest
```

### Binary

Download from [Releases](https://github.com/seeease/jf/releases):

- `jfai-linux-amd64` / `jfai-linux-arm64`
- `jfai-macos-amd64` / `jfai-macos-arm64`

```bash
chmod +x jfai-linux-amd64
./jfai-linux-amd64
```

## Test

```bash
zig build test
```

## Configuration

All via environment variables, all optional with sensible defaults:

| Variable | Description | Default |
|---|---|---|
| `JFAI_PORT` | Listen port | 8080 |
| `JFAI_DATA_DIR` | Data storage directory | ./data |
| `JFAI_MAX_TTL` | Max time-to-live (seconds) | 86400 (24h) |
| `JFAI_MAX_VIEW_COUNT` | Max views in count mode | 100 |
| `JFAI_MAX_FILE_SIZE` | Max file size (bytes) | 10485760 (10MB) |
| `JFAI_RATE_LIMIT` | Requests per second limit | 10 |
| `JFAI_RATE_BURST` | Burst request limit | 20 |

Example:

```bash
JFAI_PORT=3000 JFAI_MAX_TTL=3600 ./zig-out/bin/jfai
```

## API

### POST /api/share — Create a share

```bash
# Text
curl -X POST http://localhost:8080/api/share \
  -H 'Content-Type: application/json' \
  -d '{"type":"text","content":"secret message","destroy_mode":"count","destroy_value":1}'

# File (base64 encoded)
curl -X POST http://localhost:8080/api/share \
  -H 'Content-Type: application/json' \
  -d '{"type":"file","content":"'$(base64 < secret.pdf)'","file_name":"secret.pdf","mime_type":"application/pdf","destroy_mode":"time","destroy_value":300}'
```

Response:

```json
{"share_link":"/s/aB3xK9mP2qR7wZ5tY8nL1","id":"aB3xK9mP2qR7wZ5tY8nL1"}
```

### GET /s/{id} — View content

- Text returns an HTML page
- File returns binary stream with correct MIME type
- Returns 404 if not found or already destroyed

### GET /health — Health check

```json
{"status":"ok","active_contents":42,"storage_bytes":1048576}
```

### GET / — Web UI

Open in browser for the upload interface.

## Project Structure

```
src/
├── main.zig          # Entry point, wires all components
├── config.zig        # Environment variable configuration
├── storage.zig       # SQLite + filesystem storage layer
├── id.zig            # 128-bit random ID generation (base62)
├── handler.zig       # HTTP request handlers
├── router.zig        # Routing + rate limit middleware
├── rate_limiter.zig  # Token bucket rate limiter
└── cleaner.zig       # Background expiry cleanup thread
```

## Dependencies

None external. SQLite is compiled from source.

- Zig >= 0.15.0
- SQLite (embedded, `vendor/sqlite3/`)

## License

[MIT](LICENSE)
