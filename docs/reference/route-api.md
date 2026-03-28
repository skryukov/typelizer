# Route API Reference

## Route Configuration Options

Configure route generation via `Typelizer.configuration.routes`:

| Option | Type | Default | Description |
|---|---|---|---|
| `enabled` | `Boolean` | `false` | Enable route helper generation |
| `output_dir` | `String`, `Pathname` | Auto-detected | Output directory. Defaults to `{js_root}/routes` (uses ViteRuby source dir if available) |
| `include` | `Regexp`, `Array<Regexp>` | `nil` | Only generate routes whose path matches at least one pattern |
| `exclude` | `Regexp`, `Array<Regexp>` | `nil` | Skip routes whose path matches any pattern |
| `camel_case` | `Boolean` | `true` | Convert route keys to camelCase (e.g., `user_posts` becomes `userPosts`) |
| `format` | `Symbol` | `:ts` | Output format: `:ts` (TypeScript) or `:js` (JavaScript) |

```ruby
Typelizer.configure do |config|
  config.routes.enabled = true
  config.routes.output_dir = Rails.root.join("app/javascript/routes")
  config.routes.camel_case = true
  config.routes.format = :ts
  config.routes.include = [/^\/api/]
  config.routes.exclude = [/^\/admin/]
end
```

## Generated File Structure

| File | Contents |
|---|---|
| `{Controller}Controller.ts` | Route helper methods for one Rails controller. Default export is an object keyed by action name. |
| `index.ts` | Barrel file. Re-exports controller namespaces and named route shortcuts. |
| `runtime.ts` | Shared types and the `buildUrl`/`formAction` utilities. Not intended for direct editing. |

Namespaced controllers are placed in subdirectories (e.g., `Admin/UsersController.ts`).

All files include a fingerprint comment. Unchanged files are skipped on regeneration. Stale files are deleted automatically.

## TypeScript Types

### `Method`

```typescript
type Method = 'get' | 'post' | 'put' | 'patch' | 'delete'
```

### `RouteDefinition<M>`

Returned by every route helper method:

```typescript
type RouteDefinition<M extends Method> = {
  url: string
  method: M
}
```

### `FormDefinition`

Returned by `.form` variants on PATCH/DELETE routes:

```typescript
type FormDefinition = {
  action: string
  method: 'get' | 'post'
}
```

### `RouteOptions`

Optional second argument to route helper methods:

```typescript
type RouteOptions = {
  query?: Record<string, unknown>
  anchor?: string
}
```

## Controller Module API

Each controller file exports a default object with methods keyed by action name.

**GET routes** (no params):

```typescript
index: (options?: RouteOptions): RouteDefinition<'get'>
```

**GET routes** (single required param):

```typescript
show: (
  params: { id: string | number } | string | number,
  options?: RouteOptions,
): RouteDefinition<'get'>
```

When a route has exactly one required parameter and no optional parameters, params can be passed as a bare value.

**GET routes** (multiple params):

```typescript
userPost: (
  params: { userId: string | number; id: string | number },
  options?: RouteOptions,
): RouteDefinition<'get'>
```

**PATCH/DELETE routes** (with `.form` variant):

```typescript
update: Object.assign(
  (params, options?): RouteDefinition<'patch'>,
  { form: (params, options?): FormDefinition }
)
```

The `.form` method calls `formAction()` to produce an action URL with a `_method` query parameter, suitable for HTML forms.

**Optional parameters**:

```typescript
archive: (
  params: { year?: string | number; month?: string | number },
  options?: RouteOptions,
): RouteDefinition<'get'>
```

**Glob parameters**:

```typescript
show: (
  params: { path: string | number } | string | number,
  options?: RouteOptions,
): RouteDefinition<'get'>
```

## Runtime Functions

### `buildUrl(template, params, options?)`

Constructs a URL from a route template and parameters.

```typescript
function buildUrl(
  template: string,
  params: Record<string, unknown> | string | number,
  options?: RouteOptions,
): string
```

- Replaces `:param` segments with values from `params`
- Fills or removes `(/:param)` optional segments
- Replaces `*param` glob segments
- Appends query string from `options.query`
- Appends anchor from `options.anchor`
- Accepts both `snake_case` and `camelCase` parameter keys

### `formAction(url, method)`

Converts a URL and HTTP method into an HTML-form-compatible action:

```typescript
function formAction(url: string, method: Method): FormDefinition
```

- GET and POST are returned as-is
- Other methods append `?_method=METHOD` (or `&_method=METHOD` if query params exist) and use `method: 'post'`

### `setUrlDefaults(defaults)`

Set global URL defaults merged into every `buildUrl` call:

```typescript
function setUrlDefaults(
  defaults: Record<string, unknown> | (() => Record<string, unknown>)
): void
```

Pass a function for dynamic defaults (evaluated on each call).

### `addUrlDefault(key, value)`

Add a single default without replacing existing ones:

```typescript
function addUrlDefault(key: string, value: unknown): void
```

### `setBaseUrl(url)`

Set a base URL prepended to all generated paths:

```typescript
function setBaseUrl(url: string): void
```

When set, `buildUrl` prepends this value to every path. Useful when the API is hosted on a different domain than the frontend.

## Index Exports

The `index.ts` barrel provides two kinds of exports:

**Namespace exports** -- one per controller, giving access to all its routes:

```typescript
export { default as users } from './UsersController'
export { default as adminUsers } from './Admin/UsersController'
```

**Named route exports** -- shortcuts for individually named routes:

```typescript
export const root = _pages.index
export const editUser = _users.edit
export const newPost = _posts.new
```

Named exports are only generated for routes that have a Rails route name. If a named export would collide with a namespace export (same name), the named export is skipped.

## Parameter Handling

| Pattern | Example | Param type |
|---|---|---|
| `:param` | `/users/:id` | Required. `{ id: string \| number }` or bare value if single param |
| `(/:param)` | `/archive(/:year)` | Optional. `{ year?: string \| number }` |
| `*param` | `/pages/*path` | Glob. `{ path: string \| number }`. Arrays are joined with `/` |

When `camel_case: true` (default), parameter keys are camelized in TypeScript (`user_id` becomes `userId`). The runtime accepts both forms.
