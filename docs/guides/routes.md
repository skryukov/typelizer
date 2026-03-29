# Route Helpers

Rails route helpers (`users_path`, `edit_post_path`) don't exist on the frontend. Without them, you hardcode URL strings -- typos are silent, renamed routes break at runtime, and parameter mismatches go unnoticed until production.

Typelizer generates type-safe TypeScript (or JavaScript) route functions from your `config/routes.rb`. Each controller gets its own module with methods for every action, giving you autocompletion, type-checked parameters, and zero runtime dependencies beyond the generated code.

## Enable Route Generation

Add to your initializer:

```ruby
# config/initializers/typelizer.rb
Typelizer.configure do |config|
  config.routes.enabled = true
end
```

## Generate Route Helpers

Run the rake task:

```bash
# Generate route helpers only
rails typelizer:routes

# Generate both types and routes
rails typelizer:generate

# Clean and regenerate everything
rails typelizer:generate:refresh
```

## Understanding the Generated Output

Given these Rails routes:

```ruby
Rails.application.routes.draw do
  root "pages#index"
  resources :users
  resources :posts
end
```

Typelizer generates three kinds of files in the output directory (default: `app/javascript/routes/`):

**Per-controller files** contain route helper methods grouped by controller:

```typescript
// routes/UsersController.ts
import type { RouteDefinition, RouteOptions } from './runtime'
import { buildUrl } from './runtime'

export default {
  /** GET /users */
  index: (options?: RouteOptions): RouteDefinition<'get'> => ({
    url: buildUrl('/users', {}, options),
    method: 'get',
  }),

  /** GET /users/:id */
  show: (
    params: { id: string | number } | string | number,
    options?: RouteOptions,
  ): RouteDefinition<'get'> => ({
    url: buildUrl('/users/:id', params, options),
    method: 'get',
  }),

  // ... index, create, new, edit, update, destroy
}
```

**`index.ts`** re-exports all controllers as namespaces and provides shortcuts for named routes:

```typescript
// routes/index.ts
export { default as users } from './UsersController'
export { default as posts } from './PostsController'

// Named route shortcuts
export const root = _pages.index
export const newUser = _users.new
export const editPost = _posts.edit
// ...
```

**`runtime.ts`** contains the URL builder and type definitions used by all controller files.

## Using Route Helpers

### Import by Controller Namespace

Import the controller namespace to access all its routes:

```typescript
import { users } from '@/routes'

// GET /users
const list = users.index()
// => { url: "/users", method: "get" }

// GET /users/42
const detail = users.show(42)
// => { url: "/users/42", method: "get" }
```

### Import Named Routes

Import named route shortcuts directly:

```typescript
import { editUser, newPost } from '@/routes'

const edit = editUser(42)
// => { url: "/users/42/edit", method: "get" }
```

### Passing Parameters

Routes with a single required parameter accept a value directly:

```typescript
users.show(42)
users.show("abc-123")
```

Routes with multiple parameters require an object:

```typescript
import { posts } from '@/routes'

// GET /users/:user_id/posts/:id
posts.userPost({ userId: 1, id: 42 })
```

### Query Strings and Anchors

Pass `query` and `anchor` in the options:

```typescript
users.index({ query: { page: 2, per: 25 } })
// => { url: "/users?page=2&per=25", method: "get" }

posts.show(42, { anchor: "comments" })
// => { url: "/posts/42#comments", method: "get" }
```

### Optional Parameters

Optional route segments are typed with `?`:

```typescript
import { posts } from '@/routes'

// GET /archive(/:year)(/:month)
posts.archive({})
// => { url: "/archive", method: "get" }

posts.archive({ year: 2025 })
// => { url: "/archive/2025", method: "get" }

posts.archive({ year: 2025, month: 3 })
// => { url: "/archive/2025/3", method: "get" }
```

## Form Submissions {#forms}

PATCH and DELETE routes include a `.form` variant that returns an HTML-form-compatible action with a `_method` query parameter:

```typescript
import { users } from '@/routes'

// Standard route
users.update(42)
// => { url: "/users/42", method: "patch" }

// Form variant
users.update.form(42)
// => { action: "/users/42?_method=PATCH", method: "post" }

users.destroy.form(42)
// => { action: "/users/42?_method=DELETE", method: "post" }
```

This is useful for HTML forms and libraries like Inertia.js that need a `POST` method with `_method` override.

## URL Defaults {#url-defaults}

Set global URL defaults that are merged into every route:

```typescript
import { setUrlDefaults, addUrlDefault } from '@/routes/runtime'

// Set all defaults at once
setUrlDefaults({ locale: 'en' })

// Add a single default
addUrlDefault('locale', 'en')

// Dynamic defaults with a function
setUrlDefaults(() => ({
  locale: getCurrentLocale(),
}))
```

## Base URL {#base-url}

By default, route helpers generate relative paths. If your frontend talks to a different host (e.g., a separate API server), set a base URL:

```typescript
import { setBaseUrl } from '@/routes/runtime'

setBaseUrl('https://api.example.com')

posts.index()
// => { url: "https://api.example.com/posts", method: "get" }
```

This is useful when your Rails API and frontend are deployed separately. Set it once at app startup and all route helpers prepend it automatically.

## Filtering Routes {#filtering}

Use `include` and `exclude` to control which routes are generated:

```ruby
Typelizer.configure do |config|
  config.routes.enabled = true

  # Only generate routes matching these patterns
  config.routes.include = [/^\/api/]

  # Skip routes matching these patterns
  config.routes.exclude = [/^\/admin/, /^\/internal/]
end
```

Both accept a single `Regexp` or an array of patterns. When `include` is set, only matching routes are generated. `exclude` is applied after `include`.

## Engine Support {#engines}

Mounted Rails engines are included automatically. Route paths include the mount prefix:

```ruby
# config/routes.rb
mount BlogEngine::Engine, at: "/blog"
```

This generates `BlogEngine/ArticlesController.ts` with paths like `/blog/articles` and `/blog/articles/:id`. The engine's named routes are prefixed with the mount name (e.g., `blogEngineArticles`).

## Auto-Regeneration {#auto-regeneration}

When the [Listen](https://github.com/guard/listen) gem is installed and routes are enabled, Typelizer watches `config/` for changes to route files and regenerates automatically.

## JavaScript Output {#javascript}

For projects without TypeScript, set the format to `:js`:

```ruby
Typelizer.configure do |config|
  config.routes.enabled = true
  config.routes.format = :js
end
```

This generates `.js` files without type annotations. The runtime functions and API are identical.

## Namespaced Routes {#namespaces}

Namespaced routes are placed in subdirectories matching the namespace:

```ruby
namespace :admin do
  resources :users, only: [:index, :show, :destroy]
end
```

Generates `Admin/UsersController.ts` with paths like `/admin/users` and `/admin/users/:id`.

Import via the namespace:

```typescript
import { adminUsers } from '@/routes'

adminUsers.index()
// => { url: "/admin/users", method: "get" }
```
