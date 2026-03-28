# Getting Started

Typelizer is for Rails apps that use a serializer library and a TypeScript-capable frontend (React, Vue, Svelte via Inertia, or a separate SPA). It generates TypeScript interfaces from your serializers and type-safe route helpers from your Rails routes.

If you use jbuilder or `render json: model.as_json`, you'll need to adopt a serializer library first. If you use server-rendered views (ERB/Haml) without TypeScript, Typelizer's [route helpers](/guides/routes) and [OpenAPI schemas](/guides/openapi) may still be useful, but type generation won't apply.

## Prerequisites

- Ruby 3.0+
- Rails 6.1+
- A serializer library: [Alba](https://github.com/okuramasafumi/alba), [ActiveModel::Serializer](https://github.com/rails-api/active_model_serializers), [Oj::Serializer](https://github.com/ElMassimo/oj_serializers), or [Panko::Serializer](https://github.com/panko-serializer/panko_serializer). New to serializers? We recommend Alba.

## Installation

Add Typelizer to your Gemfile:

```ruby
gem "typelizer"
```

Run `bundle install`.

## Set Up Your Serializers

Add `Typelizer::DSL` to your base serializer class:

::: code-group
```ruby [Alba]
class ApplicationResource
  include Alba::Resource
  helper Typelizer::DSL
end
```
```ruby [AMS]
class ApplicationSerializer < ActiveModel::Serializer
  include Typelizer::DSL
end
```
```ruby [Oj::Serializer]
class ApplicationSerializer < Oj::Serializer
  include Typelizer::DSL
end
```
```ruby [Panko]
class ApplicationSerializer < Panko::Serializer
  include Typelizer::DSL
end
```
:::

Now define your serializers as usual. Typelizer reads the attributes and infers TypeScript types from your models:

```ruby
class PostResource < ApplicationResource
  attributes :id, :title, :body

  has_one :author, serializer: AuthorResource
end

class AuthorResource < ApplicationResource
  # Specify the model to infer types from (optional)
  typelize_from User

  attributes :id, :name
end
```

## Generate TypeScript Types

Run the generator:

```bash
rails typelizer:generate
```

Typelizer creates TypeScript interfaces in `app/javascript/types/serializers/`:

```typescript
// app/javascript/types/serializers/Post.ts
export interface Post {
  id: number;
  title: string;
  body: string;
  author: Author;
}
```

All interfaces are re-exported from a barrel file:

```typescript
// app/javascript/types/serializers/index.ts
export * from "./Post";
export * from "./Author";
```

## Use in Your TypeScript Code

Import the generated types:

```typescript
import { Post } from "@/types";

function renderPost(post: Post) {
  console.log(post.title);
}
```

We recommend creating a central `app/javascript/types/index.ts` that re-exports the generated types:

```typescript
// app/javascript/types/index.ts
export * from "./serializers";
// Add your custom types here
```

The `"@/types"` import path is configurable via [`types_import_path`](/reference/configuration#full-option-reference).

## Auto-Regeneration in Development

When the [Listen](https://github.com/guard/listen) gem is installed, Typelizer automatically watches your serializer files and regenerates interfaces on change. Disable this if needed:

```ruby
Typelizer.listen = false
```

To clean the output directory and regenerate everything:

```bash
rails typelizer:generate:refresh
```

To disable Typelizer entirely in development (without affecting manual generation), set the environment variable:

```bash
TYPELIZER=false
```

## Route Helpers {#route-helpers}

Without route helpers, you hardcode URL strings -- typos are silent and params aren't checked:

```typescript
fetch(`/users/${userId}/posts`)  // hope the URL is right
```

Typelizer generates type-safe route functions from your `config/routes.rb`. Enable it in an initializer:

```ruby
# config/initializers/typelizer.rb
Typelizer.configure do |config|
  config.routes.enabled = true
end
```

Run `rails typelizer:generate`, then use the generated helpers:

```typescript
import { posts } from "@/routes";

posts.index()     // => { url: "/posts", method: "get" }
posts.show(42)    // => { url: "/posts/42", method: "get" }
posts.show()      // TypeScript error: missing required param
```

Autocompletion, compile-time checking, no string URLs. See the [Route Helpers guide](/guides/routes) for the full walkthrough.

## Next Steps

- [Manual Typing](/guides/manual-typing) -- annotate computed attributes with custom types
- Serializer guides: [Alba](/guides/alba), [AMS](/guides/ams), [Oj](/guides/oj-serializer), [Panko](/guides/panko)
- [Route Helpers](/guides/routes) -- type-safe route functions from Rails routes
- [Multiple Writers](/guides/multiple-writers) -- emit different outputs (e.g., snake_case and camelCase)
- [Configuration Reference](/reference/configuration) -- all available options
