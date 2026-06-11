# Jbuilder

This guide covers using Typelizer with [Jbuilder](https://github.com/rails/jbuilder). Unlike other serializer libraries, Jbuilder is template-based: each `.json.jbuilder` file becomes its own TypeScript interface. Typelizer reads templates by walking their Prism AST, so no runtime evaluation is required.

## Setup

Jbuilder templates are registered as virtual serializer classes. For Rails apps, auto-discover every template under `app/views` from an initializer:

```ruby
# config/initializers/typelizer.rb
Rails.application.config.after_initialize do
  Typelizer::Jbuilder.discover
end
```

`discover` scans the given views root (default: `Rails.root.join("app/views")`), registers a class per `.json.jbuilder` file, and statically reads top-of-file `typelize_from Model` / `typelize_as "Name"` declarations.

For non-Rails setups or more control, register templates explicitly:

```ruby
Typelizer::Jbuilder.template("posts/index.json.jbuilder")
Typelizer::Jbuilder.template("posts/_post.json.jbuilder", model: Post)
```

The generated type name is derived from the template path. When a partial follows Rails convention — `<resource>/_<resource>.json.jbuilder`, where the parent directory singularizes to the partial name — the redundant directory is stripped. Any other layout keeps its full path so names stay unique and locations stay honest.

| Template | TypeScript type |
|---|---|
| `posts/index.json.jbuilder` | `PostsIndex` |
| `posts/show.json.jbuilder` | `PostsShow` |
| `posts/_post.json.jbuilder` | `Post` |
| `admin/posts/index.json.jbuilder` | `AdminPostsIndex` |
| `admin/users/_user.json.jbuilder` | `AdminUser` |
| `admin/_user.json.jbuilder` | `AdminUser` |
| `users/_avatar.json.jbuilder` | `UsersAvatar` |
| `_post.json.jbuilder` (root) | `Post` — collides with `posts/_post.json.jbuilder`; keep partials under a resource directory |

## Template-side declarations

Two top-of-file DSL calls let a template own its own metadata:

```ruby
# app/views/posts/_post.json.jbuilder
typelize_as "Post"           # override the auto-derived type name
typelize_from Post           # bind to an AR model for column inference

json.extract! post, :id, :title, :body, :published_at
```

Both calls are no-ops at template render time (provided by an ActionView helper auto-included by Typelizer's railtie). The plugin reads them statically via Prism during `discover`.

Generates:

```typescript
type Post = {
  id: number;
  title: string | null;
  body: string | null;
  published_at: string | null;
}
```

`typelize_as` is the same DSL method used in class-based serializers (Alba/AMS/Oj/Panko) — same semantics, just made available inside templates that don't have a class body.

::: tip
Without a model binding, Typelizer falls back to literal inference (`json.count 0` → `number`) and name heuristics (`_at` → `string`, `_id` → `number`, `is_/has_/can_` → `boolean`). Unresolvable cases emit `unknown`.
:::

### When to use `typelize_as`

The auto-derived type-name rule covers ~95% of templates. Reach for `typelize_as` when:

- The path doesn't fit the `<resource>/_<resource>` convention and would generate a stuttered name (e.g., `shared_props/_shared_props.json.jbuilder` would produce `SharedPropsSharedProps`).
- Two templates would derive the same name (collision; one needs an explicit override).
- Migration compat — the frontend already imports the old name and you don't want a rename to ripple.

## Extracting Attributes

`json.extract!` and its call-style alias `json.(record, ...)` emit one property per symbol, using the bound model for type inference:

```ruby
typelize_from Post

json.extract! post, :id, :title, :body
json.(post, :category_id)  # equivalent
```

## Manual Typing with `typelize:`

Use the `typelize:` kwarg to override or add an explicit type on any `json.xxx` call. It accepts the same type strings as Typelizer's [`typelize` DSL](/guides/manual-typing), including shortcuts and unions:

```ruby
json.name "Alice", typelize: "string"
json.rating post.average_rating, typelize: "number"
json.category post.category, typelize: "'news' | 'article' | 'blog'"

# Shortcuts
json.nickname "x", typelize: "string?"       # optional
json.tags ["a"], typelize: "string[]"        # array
json.scores [1], typelize: "number?[]"       # optional array

# Inline objects, Record<>, tuples, unions
json.metadata typelize: "{ name: string; visitorId: string | null }"
json.lookup typelize: "Record<string, number | null>"
json.pair typelize: "[string | null, number]"
json.result typelize: "{ ok: boolean } | { error: string }"
```

The `typelize:` kwarg always wins — use it when you need to pin a shape that the walker can't infer.

## Partials

Partials referenced via `json.partial!` or the `partial:` kwarg are resolved to their own generated interfaces. No separate registration is needed — Typelizer auto-registers referenced partials on first use.

Merging a partial inline (properties flow into the current scope):

```ruby
# posts/show.json.jbuilder
json.partial! "posts/post", post: @post
json.author do
  json.partial! "users/user", user: @post.user
end
json.summary @post.body, typelize: "string"
```

Generates:

```typescript
import type {PostCategory} from '@/types'

type PostsShow = {
  id: number;
  title: string | null;
  body: string | null;
  published_at: string | null;
  category: PostCategory | null;
  author: {
    id: number;
    name: string;
    username: string;
    active: boolean;
  };
  summary: string;
}
```

The `partial:` kwarg imports the partial as a named type. The plugin infers whether the result is a single object or an array from the property name — plural names become arrays, singular names stay as one:

```ruby
# posts/index.json.jbuilder
json.title "Posts"
json.total_count @posts.count
json.posts @posts, partial: "posts/post", as: :post    # plural → Array<Post>
json.featured @featured, partial: "posts/post", as: :post  # singular → Post
```

Generates:

```typescript
import type {Post} from '@/types'

type PostsIndex = {
  title: string;
  total_count: number;
  posts: Array<Post>;
  featured: Post;
}
```

If the name doesn't match the plurality of the value (e.g. a collection named `data`), pin it with `typelize:` or rename the property. Known collection methods on the argument (`all`, `where`, `order`, `includes`, `limit`, `recent`, `active`) also force array inference.

Recursive partials work too — Typelizer's `WriterContext` memoizes interfaces per class, so a `_comment.json.jbuilder` that references itself via `partial: "comments/comment"` produces a stable self-referential type.

## Blocks and Nested Shapes

`json.xxx do ... end` produces a nested inline shape. Block parameters (collection iteration) produce an array of that shape:

```ruby
# Nested object
json.stats do
  json.total @total
  json.average_rating @rating, typelize: "number | null"
end

# Collection iteration — block params → Array<shape>
json.posts @posts do |post|
  json.id post.id
  json.title post.title, typelize: "string"
end
```

Generates:

```typescript
{
  stats: {
    total: number;
    average_rating: number | null;
  };
  posts: Array<{
    id: number;
    title: string;
  }>;
}
```

### Collection + Attribute Shortcut

`json.posts @posts, :id, :title` — a collection followed by symbols — expands to an inline shape over those attributes (using the bound model for inference):

```ruby
typelize_from Post

json.posts @posts, :id, :title, :published_at
```

Generates:

```typescript
{
  posts: Array<{
    id: number;
    title: string | null;
    published_at: string | null;
  }>;
}
```

## Root Arrays

`json.array! @items do |item| ... end` at the template root wraps the entire interface as an array:

```ruby
json.array! @items do |item|
  json.id item.id
  json.name item.name, typelize: "string"
end
```

Generates:

```typescript
type JbuilderFeaturesRootArrayData = {
  id: number;
  name: string;
}
type JbuilderFeaturesRootArray = Array<JbuilderFeaturesRootArrayData>;
```

## Conditional Fields

Properties emitted inside `if` or `unless` blocks become **optional** keys — they may or may not be present depending on the condition:

```ruby
json.always "value"

if @feature_flag
  json.featured true
  json.badge "hot", typelize: "string"
end

unless @hidden
  json.public_id 42, typelize: "number"
end
```

Generates:

```typescript
{
  always: string;
  featured?: boolean;
  badge?: string;
  public_id?: number;
}
```

### If/Else Branches

When the same property appears in every branch of an `if/elsif/else` chain that terminates in `else`, it stays **required** — one branch always fires, so the key is always set:

```ruby
if @post.category
  json.category @post.category, partial: "categories/category", as: :category
else
  json.category nil, typelize: "Category | null"
end
```

Generates:

```typescript
{
  category: Category;  // required — every branch emits it
}
```

::: warning
When branches disagree on nullability (one emits `Category`, another emits `Category | null`), the plugin currently picks the first branch's type — nullability from other branches is lost. Pin the combined type with `typelize:` if the distinction matters.
:::

If/elsif chains without a final `else` fall back to optional, since one condition combination can skip every branch.

## Caching Blocks

`json.cache!`, `json.cache_if!`, and `json.cache_root!` are treated as transparent pass-throughs — the walker descends into their blocks as if the cache wrapper weren't there:

```ruby
json.cache! @post, expires_in: 1.hour do
  json.title @post.title, typelize: "string"
  json.body @post.body, typelize: "string"
end
```

Generates the same properties as if `cache!` were not present.

## Inertia Compatibility

When used alongside `jbuilder-inertia` (sibling to [alba-inertia](https://github.com/skryukov/alba-inertia)), the `inertia:` kwarg is read symbolically to widen properties to optional:

```ruby
json.stats @stats, inertia: :defer          # → stats?: ...
json.filters @filters, inertia: :optional   # → filters?: ...
```

Typelizer doesn't evaluate the kwarg at runtime — it just widens the TypeScript type so partial reloads and deferred props type-check correctly on the frontend.

## Limitations

The walker is static — it parses templates without running them. A few dynamic forms can't be resolved and are silently dropped; use `typelize:` to pin a shape when you need one:

| Form | Behavior | Workaround |
|---|---|---|
| `json.merge! some_hash` | Skipped (runtime-only shape) | Wrap the merge in a `typelize:` kwarg on the surrounding call |
| `json.set! dynamic_key, value` | Skipped (dynamic key) | `json.foo typelize: "Record<string, T>"` |
| `json.null!`, `json.key_format!`, etc. | No property emitted | No workaround needed |
| `.jb` / Rabl templates | Not supported | Use `.json.jbuilder` |

For attributes the walker can't type at all (no model binding, no literal, no name hint), Typelizer emits `unknown` and logs a development warning — add `typelize:` to silence it.

### Faking traits with composed partials

[Alba traits](/guides/alba#traits) generate named intersection types (`Course & CourseDetailsTrait`). Jbuilder doesn't have a direct equivalent, but the same effect falls out of `json.partial!` composition because TypeScript is structurally typed.

Define one partial per "trait":

```ruby
# courses/_course.json.jbuilder — base
json.id course.id, typelize: "number"
json.title course.title, typelize: "string"

# courses/_course_details.json.jbuilder — additive
json.description course.description, typelize: "string"
json.lessons course.lessons, partial: "lessons/lesson", as: :lesson

# courses/_course_classmates.json.jbuilder — additive
json.classmates course.enrolled_students, partial: "users/user", as: :user
```

Compose them in the page template:

```ruby
# dashboard/courses/show.json.jbuilder
json.course do
  json.partial! "courses/course", course: @course
  json.partial! "courses/course_details", course: @course
  json.partial! "courses/course_classmates", course: @course
end
```

Generates an inline shape with all the merged fields:

```typescript
type DashboardCoursesShow = {
  course: {
    id: number;
    title: string;
    description: string;       // from _course_details
    lessons: Array<Lesson>;    // from _course_details
    classmates: Array<User>;   // from _course_classmates
  };
}
```

The shape is structurally equivalent to `Course & CourseDetails & CourseClassmates` for any property access — `course.description`, `course.lessons.map(...)`, etc. all type-check. Each partial also generates its own named type (`Course`, `CourseDetails`, `CourseClassmates`) that downstream components can use as explicit prop types.

::: tip
The key trade-off vs Alba traits: in Alba, `with_traits: [...]` is decided at serializer-call time and types stay named. In jbuilder, composition happens in the template and the resulting type is anonymous unless consumers reach back through `MyPage["course"]`. The behavior is the same; the naming ergonomics differ.
:::

### `partial!` inside a block inlines, doesn't import

`json.foo do ... json.partial! "..." ... end` merges the partial's properties into the nested shape — the partial becomes part of the inline type, not a separate named import. To get a named import, use the `partial:` kwarg directly on the call:

```ruby
# Inlines — instructor becomes a massive anonymous object
json.instructor do
  json.partial! "author_profiles/author_profile", profile: @course.author_profile
end

# Imports — instructor: AuthorProfile
json.instructor @course.author_profile, partial: "author_profiles/author_profile", as: :profile
```

## Plugin Configuration

Override the views root via `plugin_configs`:

```ruby
Typelizer.configure do |config|
  config.plugin_configs = {
    jbuilder: {
      views_root: Rails.root.join("app/views").to_s
    }
  }
end
```

Per-template overrides are available through the virtual class's `typelizer_config` block, though in most cases the template DSL (`typelize_as`, `typelize_from`, `typelize:` kwarg) is enough.

See [Manual Typing](/guides/manual-typing) for the full `typelize` syntax and [Configuration Reference](/reference/configuration) for the plugin config layering.
