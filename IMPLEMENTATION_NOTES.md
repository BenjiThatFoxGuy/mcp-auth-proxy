# mcp-auth-proxy Deep Dive: Tool-Level Permission Gating

## 1. Project Structure

### Source Files and Purposes

```
main.go                          - CLI entry point. Uses cobra for command parsing.
                                   Defines all CLI flags/env vars. Calls mcpproxy.Run().

pkg/mcp-proxy/main.go           - Server wiring. The Run() function assembles all
                                   components: backend, auth router, IDP router, proxy
                                   router, gin engine, TLS, and starts the HTTP server.

pkg/proxy/proxy.go               - ProxyRouter: JWT-validated reverse proxy middleware.
                                   Validates bearer tokens, strips/adds headers, forwards
                                   to backend handler. THE MAIN REQUEST PATH for MCP traffic.

pkg/backend/interface.go         - Backend interface: Run(ctx) -> (http.Handler, error),
                                   Wait() error, Close() error.

pkg/backend/proxy.go             - ProxyBackend: Stdio-based MCP backend. Spawns a child
                                   process, connects via stdio transport, creates an
                                   mcp-go Server that mirrors the child's tools/prompts/
                                   resources, and serves via StreamableHTTPServer.
                                   THIS IS WHERE TOOLS ARE DISCOVERED AND REGISTERED.

pkg/backend/transparent.go       - TransparentBackend: HTTP/HTTPS reverse proxy using
                                   httputil.ReverseProxy. Passes all traffic through
                                   without MCP-level awareness. Follows 307/308 redirects.

pkg/auth/interface.go            - Provider interface for OAuth providers.
pkg/auth/auth.go                 - AuthRouter: Login/logout, OAuth callback handling,
                                   session management, password auth.
pkg/auth/github.go               - GitHub OAuth provider implementation.
pkg/auth/google.go               - Google OAuth provider implementation.
pkg/auth/oidc.go                 - Generic OIDC provider implementation.
pkg/auth/mock.go                 - Generated mock for Provider interface.

pkg/idp/idp.go                   - IDPRouter: Built-in OAuth 2.1 Identity Provider.
                                   Handles /authorize, /token, /register, /introspect,
                                   JWKS, and .well-known endpoints. Uses fosite library.

pkg/models/models.go             - Data models for fosite Request/Client/AuthorizeRequest
                                   serialization.

pkg/repository/interface.go      - Repository interface (fosite.Storage + custom storage).
pkg/repository/kvs.go            - BoltDB (bbolt) key-value store implementation.
pkg/repository/sql.go            - SQL (GORM) implementation for sqlite/postgres/mysql.

pkg/utils/keys.go                - RSA key and HMAC secret generation/loading.
pkg/utils/rand.go                - Key ID, client ID/secret, state generation.
pkg/utils/log.go                 - Fosite error -> zap fields helper.
pkg/utils/must.go                - Generic Must[T] panic helper.

pkg/tlsreload/file_reloader.go   - Hot-reloading TLS certificate watcher.

pkg/backend/testserver/main.go   - Minimal MCP server for testing (stdio, no tools).
```

### Test Files

```
main_test.go                     - Tests for CLI parsing helpers (splitCSV, parseAttributeMap, etc.)
pkg/auth/auth_test.go            - Tests for AuthRouter.
pkg/auth/github_test.go          - Tests for GitHub provider.
pkg/auth/google_test.go          - Tests for Google provider.
pkg/auth/oidc_test.go            - Tests for OIDC provider.
pkg/auth/main_test.go            - Test setup for auth package.
pkg/backend/proxy_test.go        - Tests for ProxyBackend and setupProxy.
pkg/backend/transparent_test.go  - Tests for TransparentBackend.
pkg/backend/main_test.go         - Test setup for backend package.
pkg/mcp-proxy/main_test.go       - Integration tests for Run() and config normalization.
pkg/proxy/proxy_test.go          - Tests for ProxyRouter JWT validation, header mapping, SSE blocking.
pkg/repository/sql_test.go       - Tests for SQL repository.
pkg/utils/keys_test.go           - Tests for key utilities.
```

---

## 2. MCP Message Flow

### Two Completely Different Paths

The proxy has **two backend modes** with fundamentally different message flow:

#### Path A: ProxyBackend (stdio command) -- MCP-AWARE

When `proxyTarget[0]` is NOT a URL (no http/https scheme), the proxy uses `ProxyBackend`:

```
Client -> Gin router -> ProxyRouter.handleProxy() (JWT validation)
       -> StreamableHTTPServer (mcp-go server)
       -> mcp-go Server (has registered tools/prompts/resources)
       -> client.CallTool() / client.GetPrompt() etc.
       -> stdio transport -> child process
```

**Key flow in `pkg/backend/proxy.go`, `setupProxy()` (line 95):**

1. **Line 96-98**: Creates an `mcp-go/client.Client` with the stdio transport, starts it.
2. **Line 103-116**: Sends `InitializeRequest` to the backend MCP server.
3. **Lines 118-127**: If backend has tools capability, calls `c.ListTools()` and registers
   each tool on a NEW `mcp-go/server.MCPServer` via `s.AddTool(tool, c.CallTool)`.
   - `c.CallTool` is the handler -- it forwards calls directly to the child process.
4. **Lines 128-152**: Same for prompts and resources.
5. **Lines 154-160**: Creates a `StreamableHTTPServer` with endpoint `/mcp`, stateless mode.

**THIS IS THE PATH WHERE WE HAVE MCP-LEVEL VISIBILITY.** The proxy creates its own
mcp-go Server that mirrors the backend's capabilities. Tool calls flow through the
mcp-go server's handler dispatch, which calls `c.CallTool` (the client function).

#### Path B: TransparentBackend (HTTP URL) -- MCP-OPAQUE

When `proxyTarget[0]` IS a URL (http:// or https://), the proxy uses `TransparentBackend`:

```
Client -> Gin router -> ProxyRouter.handleProxy() (JWT validation)
       -> httputil.ReverseProxy -> backend HTTP server
```

**`pkg/backend/transparent.go`, `Run()` (line 116):**

Creates a standard `httputil.ReverseProxy` with the redirect-following transport.
The proxy has NO knowledge of MCP messages at all -- it just forwards raw HTTP.

**For tool-level gating on TransparentBackend, we'd need to intercept the HTTP body,
parse JSON-RPC messages, and modify them. This is significantly harder.**

### Where tools/list happens

**ProxyBackend**: In `setupProxy()` at line 119, `c.ListTools()` is called once during
initialization. The result is used to register tools on the server. After that, when a
client sends a `tools/list` request to the StreamableHTTPServer, the mcp-go server
handles it internally by returning its registered tools list.

**TransparentBackend**: The tools/list JSON-RPC message passes through the reverse proxy
to the backend HTTP server without any interception.

### Where tools/call happens

**ProxyBackend**: When a client sends a `tools/call` request, the mcp-go server dispatches
it to the handler registered for that tool, which is `c.CallTool` -- the client function
that forwards the call to the stdio backend.

**TransparentBackend**: The tools/call JSON-RPC message passes through the reverse proxy
to the backend HTTP server without any interception.

---

## 3. Key Interception Points

### For ProxyBackend (stdio) -- THE EASY PATH

#### Tool filtering on tools/list

**File**: `pkg/backend/proxy.go`
**Function**: `setupProxy()`, lines 118-127

```go
if init.Capabilities.Tools != nil {
    tools, err := c.ListTools(ctx, mcp.ListToolsRequest{})
    // ...
    for _, tool := range tools.Tools {
        s.AddTool(tool, c.CallTool)
    }
}
```

**Interception strategy**: After listing tools from backend, filter the list before
registering on the server. Tools with "hide" permission are never registered, so they
don't appear in the client's tools/list response at all.

```go
// Proposed change:
for _, tool := range tools.Tools {
    perm := permissions.GetPermission(tool.Name)
    if perm == PermissionHide {
        continue // Don't register -- invisible to client
    }
    if perm == PermissionDeny {
        s.AddTool(tool, denyHandler(tool.Name)) // Register but reject calls
        continue
    }
    s.AddTool(tool, c.CallTool) // Allow -- forward normally
}
```

#### Tool gating on tools/call

**File**: `pkg/backend/proxy.go`
**Function**: `setupProxy()`, line 126

The second argument to `s.AddTool()` is the handler function:
```go
s.AddTool(tool, c.CallTool)
```

`c.CallTool` has the signature matching mcp-go's `ToolHandlerFunc`:
```go
func(ctx context.Context, request mcp.CallToolRequest) (*mcp.CallToolResult, error)
```

**Interception strategy**: Wrap `c.CallTool` with a permission-checking handler:

```go
func gatedCallTool(permissions *PermissionStore, toolName string, upstream mcp.ToolHandlerFunc) mcp.ToolHandlerFunc {
    return func(ctx context.Context, request mcp.CallToolRequest) (*mcp.CallToolResult, error) {
        perm := permissions.GetPermission(toolName)
        if perm == PermissionDeny || perm == PermissionHide {
            return nil, &jsonrpc.Error{
                Code:    -32601, // Method not found
                Message: fmt.Sprintf("Tool '%s' is not available", toolName),
            }
        }
        return upstream(ctx, request)
    }
}
```

#### Response inspection / auto-discovery

**File**: `pkg/backend/proxy.go`
**Function**: `setupProxy()`, line 119

`c.ListTools()` already returns the full tool list from the backend. This is where
we can auto-discover all available tools and seed the permissions manifest.

### For TransparentBackend (HTTP) -- THE HARD PATH

#### JSON-RPC Message Interception

**File**: `pkg/proxy/proxy.go`
**Function**: `handleProxy()`, line 68

Currently at line 143:
```go
p.proxy.ServeHTTP(c.Writer, c.Request)
```

This is where the request is forwarded to the backend (the `http.Handler` from the
backend). For TransparentBackend, this is the `httputil.ReverseProxy`.

**To intercept MCP messages in transparent mode, we would need to:**

1. Read the request body to detect JSON-RPC `tools/call` and `tools/list` methods.
2. For `tools/call`: Check permissions before forwarding.
3. For `tools/list`: Forward to backend, intercept the response, filter hidden tools.
4. This requires replacing the simple `proxy.ServeHTTP` with a body-reading middleware,
   and potentially using `httputil.ReverseProxy.ModifyResponse` for response filtering.

**Important**: The transparent backend does NOT buffer request bodies (it's a streaming
reverse proxy). We'd need to buffer the body to parse JSON-RPC, which could affect
SSE/streaming behavior.

**Recommendation**: For the initial implementation, only support tool-level gating in
ProxyBackend mode. TransparentBackend can be a follow-up.

---

## 4. Configuration System

### Current Configuration

**Format**: All CLI flags via cobra, with environment variable fallbacks.
**No config file** -- everything is flags or env vars.

**File**: `main.go`, `newRootCommand()` function (line 178)

Pattern for each config item:
```go
rootCmd.Flags().StringVar(&variable, "flag-name", getEnvWithDefault("ENV_NAME", "default"), "description")
```

**The entire config is passed as individual arguments to `mcpproxy.Run()`** -- there's
no config struct. The `Run()` function has a massive parameter list (40+ parameters).

### Where to add permissions manifest

**Option A: Config file approach**
Add a `--permissions-file` flag pointing to a YAML/JSON file. This is the cleanest for
a persistent manifest that an admin edits.

```yaml
# permissions.yaml
tools:
  read_file:
    permission: allow
  delete_database:
    permission: deny
    message: "This tool is restricted by policy"
  internal_debug:
    permission: hide
default: allow  # or deny
```

**Option B: Environment variable approach**
Less flexible but consistent with existing config style:
```
TOOL_PERMISSIONS="read_file:allow,delete_database:deny,internal_debug:hide"
TOOL_DEFAULT_PERMISSION="allow"
```

**Option C: Both**
Config file for the manifest, flag/env for the path and default policy.

**Recommendation**: Option C. Add these flags:
- `--permissions-file` / `PERMISSIONS_FILE` - path to YAML permissions manifest
- `--tool-default` / `TOOL_DEFAULT_PERMISSION` - default policy (allow/deny/hide)

The file needs to be added to `main.go`'s flag definitions and passed through to `Run()`.
Since the config ultimately flows through `mcpproxy.Run()` which calls `setupProxy()`,
the permissions config needs to reach `setupProxy()` either as a parameter or as a
new config object.

**Suggested refactoring**: Create a `Config` struct to replace the massive parameter list
in `Run()`, or at minimum create a `PermissionsConfig` struct that gets threaded through.

### Where the config reaches the backend

```
main.go (flag parsing)
  -> mcpproxy.Run() in pkg/mcp-proxy/main.go (line 40)
    -> backend.NewProxyBackend() or backend.NewTransparentBackend() (lines 146-163)
    -> setupProxy() in pkg/backend/proxy.go (line 95) -- ONLY for ProxyBackend
```

The permissions config needs to reach `setupProxy()`. Currently, `NewProxyBackend`
only takes `(logger, cmd)`. We'd need to extend it or pass permissions separately.

---

## 5. Transport Handling

### Transport Summary

The proxy supports two distinct transport modes based on the `proxyTarget` argument:

| Backend Type | Trigger | Transport to Backend | MCP Awareness | Tool Gating Difficulty |
|---|---|---|---|---|
| ProxyBackend | `proxyTarget` is a command (no URL scheme) | stdio (pipes to child process) | Full -- mirrors tools/prompts/resources | Easy -- intercept at registration |
| TransparentBackend | `proxyTarget` is http:// or https:// URL | HTTP reverse proxy | None -- opaque byte forwarding | Hard -- body parsing required |

### Client-to-Proxy Transport

**Always HTTP**. The gin router serves HTTP/HTTPS. Clients connect either:
- **Streamable HTTP** (POST to `/mcp`) -- for ProxyBackend (mcp-go StreamableHTTPServer)
- **SSE** (GET to `/mcp` with `Accept: text/event-stream`) -- can be blocked with `--http-streaming-only`
- **Raw HTTP** -- for TransparentBackend (any path, forwarded as-is)

The `--http-streaming-only` flag in `ProxyRouter.handleProxy()` (line 89) blocks SSE
GET requests when enabled.

### Interception Differences by Transport

**For ProxyBackend**: Interception is at the mcp-go server level. The
`StreamableHTTPServer` handles JSON-RPC framing internally. We intercept at the
`AddTool()` / handler level, which is transport-agnostic.

**For TransparentBackend**: Would need to intercept at the HTTP body level in
`ProxyRouter.handleProxy()` before calling `p.proxy.ServeHTTP()`. This is
transport-dependent -- SSE responses are streamed, HTTP responses may be chunked.

---

## 6. Session Management

### OAuth/Browser Sessions

**File**: `pkg/auth/auth.go` and `pkg/mcp-proxy/main.go`

Sessions use `gin-contrib/sessions` with cookie store (line 324-332 of mcp-proxy/main.go):
```go
store := cookie.NewStore(secret)
store.Options(sessions.Options{
    Path:     "/",
    MaxAge:   600,
    HttpOnly: true,
    Secure:   sessionCookieSecure(parsedExternalURL),
    SameSite: http.SameSiteLaxMode,
})
router.Use(sessions.Sessions("session", store))
```

Session keys (defined in auth.go):
- `SessionKeyAuthorized` ("authorized") - bool
- `SessionKeyRedirectURL` ("redirect_url") - string
- `SessionKeyOAuthState` ("oauth_state") - string
- `SessionKeyUserID` ("user_id") - string
- `SessionKeyUserInfo` ("user_info") - JSON string of user info map

### MCP API Sessions (Bearer Token)

**File**: `pkg/proxy/proxy.go`, `handleProxy()` (line 68)

MCP clients authenticate via Bearer JWT tokens. The proxy validates the token's:
- Signing method (RSA)
- Issuer (must match externalURL)
- Audience (must match externalURL)

The JWT claims include:
- `sub` (subject/user ID)
- `userinfo` (nested map with provider-specific info, e.g., email)

**There is NO per-session state storage for MCP API calls.** The ProxyRouter is
stateless from the proxy's perspective. The mcp-go StreamableHTTPServer runs in
stateless mode (`server.WithStateLess(true)` at proxy.go line 157).

### Per-Session Permissions

Since there's no per-session state for MCP API calls, tool permissions would be:
- **Global** (same for all users/sessions) -- simplest approach
- **Per-user** (based on JWT claims) -- requires looking up user identity in the
  permission check and having user-scoped permission rules

For the initial implementation, global permissions (from the config file) are the
right approach. Per-user permissions can be added later by extracting user identity
from the `context.Context` that mcp-go passes to tool handlers.

---

## 7. Error Response Format

### Current Error Patterns

**ProxyRouter** (proxy.go):
```go
// Line 71-72 -- Missing bearer token
c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "Unauthorized"})

// Line 85 -- Invalid token
c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "Invalid token"})

// Line 91 -- SSE rejected
c.AbortWithStatusJSON(http.StatusMethodNotAllowed, gin.H{
    "error": "SSE (GET) streaming is not supported by this backend; use POST-based HTTP streaming instead",
})
```

**IDP Router** (idp.go) -- fosite errors:
```go
a.provider.WriteAuthorizeError(ctx, c.Writer, ar, err)
a.provider.WriteAccessError(ctx, c.Writer, accessRequest, err)
```

**Auth Router** (auth.go):
```go
c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "Unauthorized"})
```

### MCP Error Response Format

For tool-level permission denials, we need to return errors in the **MCP JSON-RPC
format**, not HTTP error codes. The mcp-go server handles this internally when a
tool handler returns an error.

When using ProxyBackend (mcp-go server), returning an error from the tool handler
will cause the mcp-go server to return a JSON-RPC error response:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32601,
    "message": "Tool 'delete_database' is not available: access denied by policy"
  }
}
```

Alternatively, we can return a successful `CallToolResult` with `IsError: true` for
a gentler denial that doesn't look like a protocol error:

```go
return &mcp.CallToolResult{
    IsError: true,
    Content: []mcp.Content{
        mcp.TextContent{
            Type: "text",
            Text: "Access denied: tool 'delete_database' is restricted by policy. Contact your administrator.",
        },
    },
}, nil
```

**Recommendation**: Use the `CallToolResult` with `IsError: true` approach for denied
tools. This gives us control over the error message and doesn't break JSON-RPC framing.
For hidden tools that somehow get called (shouldn't happen since they're not registered),
use a JSON-RPC error with code -32601 (Method not found).

---

## 8. Implementation Plan Summary

### Recommended Approach

1. **Target ProxyBackend only** for the initial implementation. TransparentBackend
   can be a follow-up (it requires HTTP body interception).

2. **New package**: `pkg/permissions/` with:
   - `permissions.go` -- `PermissionStore` struct, YAML loading, permission lookup
   - Permission types: `Allow`, `Deny`, `Hide`
   - Default permission policy
   - Custom deny message per tool

3. **Config additions** in `main.go`:
   - `--permissions-file` / `PERMISSIONS_FILE`
   - `--tool-default` / `TOOL_DEFAULT_PERMISSION`

4. **Modify `setupProxy()`** in `pkg/backend/proxy.go`:
   - Accept permissions config
   - Filter tools at registration time (hide)
   - Wrap handlers for denied tools
   - Auto-discover tools from backend and optionally seed the manifest

5. **Thread config through** `Run()` -> `NewProxyBackend()` -> `setupProxy()`

### Critical Files to Modify

| File | Changes |
|---|---|
| `main.go` | Add `--permissions-file` and `--tool-default` flags |
| `pkg/mcp-proxy/main.go` | Thread permissions config through `Run()` to backend |
| `pkg/backend/proxy.go` | Add permission filtering in `setupProxy()` tool loop |
| `pkg/backend/interface.go` | Possibly extend Backend interface if needed |
| NEW `pkg/permissions/permissions.go` | Permission store, YAML parsing, lookup |

### Key mcp-go Types Referenced

From `github.com/mark3labs/mcp-go`:
- `mcp.Tool` -- tool definition (name, description, inputSchema)
- `mcp.CallToolRequest` -- incoming tool call request
- `mcp.CallToolResult` -- tool call response (Content, IsError)
- `server.MCPServer.AddTool(tool, handler)` -- registers a tool with its handler
- `client.Client.CallTool` -- forwards tool call to backend (the handler function)
- `client.Client.ListTools` -- lists tools from backend

The handler signature for `AddTool` is:
```go
type ToolHandlerFunc func(ctx context.Context, request mcp.CallToolRequest) (*mcp.CallToolResult, error)
```
