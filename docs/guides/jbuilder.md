# Jbuilder

This guide covers using Typelizer with [Jbuilder](https://github.com/rails/jbuilder). Unlike other serializer libraries, Jbuilder is template-based: each `.json.jbuilder` file becomes its own TypeScript interface. Typelizer reads templates by walking their Prism AST, so no runtime evaluation is required.

## Requirements

Template parsing uses [Prism](https://github.com/ruby/prism) and requires prism >= 1.0. Prism is not a dependency of the typelizer gem — add it to your Gemfile:

```ruby
gem "prism", ">= 1.0"
```

Prism activates lazily, the first time a template is parsed (generation time). It is never loaded at boot or render time, so apps that don't use the Jbuilder plugin pay nothing. If prism is missing or too old when the plugin first needs it, generation fails with an actionable error:

```
Typelizer's Jbuilder plugin requires prism >= 1.0 to parse templates —
add prism (>= 1.0) to your Gemfile (prism 0.19.0 is active; the Jbuilder plugin needs >= 1.0)
```

::: warning Ruby's bundled prism may be too old
Ruby 3.3 ships prism 0.19 as a bundled gem. The version check runs against the prism actually active in the process, so an explicit `gem "prism", ">= 1.0"` in your Gemfile is required even on Rubies that bundle prism.
:::

## Setup

Point Typelizer at your views directories and templates are discovered automatically:

```ruby
# config/initializers/typelizer.rb
Typelizer.configure do |config|
  config.jbuilder_views = [Rails.root.join("app", "views")]
end
```

Setting `jbuilder_views` enables the plugin. Discovery runs at the start of every generation cycle — never at boot — so adding, editing, renaming, or deleting a template (or a partial it composes) is reflected on the next generation without a server restart. In production, generation doesn't run, so templates are never parsed there.

For non-Rails setups or more control, register templates explicitly (leave `jbuilder_views` unset — per-cycle discovery would wipe explicit registrations otherwise):

```ruby
Typelizer::Jbuilder.discover(Rails.root.join("app/views").to_s)
Typelizer::Jbuilder.template("posts/index.json.jbuilder")
Typelizer::Jbuilder.template("posts/_post.json.jbuilder", model: Post)
```

Partials referenced from a registered template are auto-registered on first use — no separate registration needed.

### Type names

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

Path segments that wouldn't form a valid type name are sanitized deterministically: characters outside `A-Za-z0-9_` are stripped (`v2.1/show.json.jbuilder` → `V21Show`) and digit-leading segments are prefixed with `N` (`2fa/show.json.jbuilder` → `N2faShow`). If sanitization still can't produce a valid name, generation raises with a `typelize_as` hint — and an explicit `typelize_as` name is never rewritten: an invalid one (e.g. `typelize_as "userList"`) raises instead.

Two templates claiming the same type name raise a `Typelizer::Jbuilder::NameCollision` error at generation time, naming both template paths. Rename one of them with `typelize_as`.

One exception: with multiple discovery roots, a template at the *same relative path* as one from an earlier root is Rails view-path shadowing, not a collision — the earlier root's template wins (it is the one Rails renders), and the shadowed file is skipped with a debug log. Partial references to the shadowed path resolve to the winner's type.

Property names need no sanitizing — TypeScript allows any string as a quoted key. A name that isn't a valid JS identifier (only possible via a literal `json.set!` key, e.g. `json.set! "kebab-key", value`) renders quoted (`'kebab-key': string;`, or double-quoted with `prefer_double_quotes`); normal names stay bare and byte-identical.

### Render safety vs. plugin enablement

The plugin has two independent halves:

- **Render safety** installs whenever the jbuilder gem is present — independent of `jbuilder_views`. Template annotations (`typelize_as`, `typelize_from`, the `typelize:` kwarg) are no-ops at render time: a type annotation never changes JSON output and never crashes a render, in any environment.
- **Discovery and parsing** (template registration, prism activation) run only when the plugin is enabled — auto-detected from `jbuilder_views` being set, with `config.jbuilder_enabled = true/false` as an explicit override.

::: warning Keep typelizer in the production bundle
The render-safety patches come from the typelizer gem. If typelizer is confined to the `:development` group, annotated templates **will** crash production renders — jbuilder itself doesn't understand `typelize:`. Keep `gem "typelizer"` available in all environments (the production footprint is just the no-op patches).
:::

## Template-side declarations

Two top-of-file DSL calls let a template own its own metadata:

```ruby
# app/views/posts/_post.json.jbuilder
typelize_as "Post"           # override the auto-derived type name
typelize_from Post           # bind to an AR model for column inference

json.extract! post, :id, :title, :body, :published_at
```

Both calls are no-ops at template render time (provided by an ActionView helper auto-included by Typelizer's railtie). The plugin reads them statically via Prism during discovery.

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

::: warning Declaration order matters
`typelize_as` and `typelize_from` are read from the leading statements of the template, and reading stops at the first statement that isn't a bare DSL call. Place them **before the first `json.*` line** (comments are fine anywhere). Declarations placed after content are silently ignored.
:::

The model binding is stored by name and resolved lazily at each generation, so code reloads in development always see the freshly loaded class.

### When to use `typelize_as`

The auto-derived type-name rule covers ~95% of templates. Reach for `typelize_as` when:

- The path doesn't fit the `<resource>/_<resource>` convention and would generate a stuttered name (e.g., `shared_props/_shared_props.json.jbuilder` would produce `SharedPropsSharedProps`).
- Two templates would derive the same name (`NameCollision` at generation; one needs an explicit override).
- Migration compat — the frontend already imports the old name and you don't want a rename to ripple.

## How types are inferred

For each `json.xxx` call, the effective resolution order is:

1. **`typelize:` kwarg** — always wins. The property is marked user-asserted; model inference never overrides it.
2. **Block** — produces a nested inline shape (or a named intersection for composed partials, see below).
3. **`partial:` kwarg** — imports the partial's interface as a named type.
4. **Walker guess** — literal values (`json.count 0` → `number`), `Time.*` calls (→ `string`), then name heuristics: `_id`/`id` → `number`, `_at`/`_on` → `string`, `_count`/`_total`/`total`/`page` → `number`, `is_`/`has_`/`can_`/`should_`/`was_` prefixes → `boolean`. Anything else → `unknown`.
5. **Model inference** — when the template is bound to an ActiveRecord model (`typelize_from`), columns, associations, delegates, and attribute types are resolved through the same pipeline class-based serializers use. **Model inference overwrites the walker's guess**, including literal-derived types (see below).
6. Still `unknown` after all of the above → emitted as `unknown` with a development warning (see [Unknown fallback](#unknown-fallback)).

::: warning Model beats literal
With a model binding, a matching column wins over the literal you wrote. `json.deleted true` against a *nullable string* `deleted` column generates `deleted: string | null`, not `boolean`. This keeps generated types honest about what the database can actually contain — use `typelize:` to assert otherwise.
:::

## Extracting attributes

`json.extract!` and its call-style alias `json.(record, ...)` emit one property per symbol, using the bound model for type inference:

```ruby
typelize_from Post

json.extract! post, :id, :title, :body
json.(post, :category_id)  # equivalent
```

Without a model binding (PORO `typelize_from` targets, or no binding at all), extracted attributes fall back to the name heuristics instead of emitting all-`unknown`.

## Manual typing with `typelize:`

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
json.metadata @metadata, typelize: "{ name: string; visitorId: string | null }"
json.lookup @lookup, typelize: "Record<string, number | null>"
json.pair @pair, typelize: "[string | null, number]"
json.result @result, typelize: "{ ok: boolean } | { error: string }"
```

An annotation must accompany a value or a block. A bare `json.metadata typelize: "..."` is not an annotation at render time — jbuilder receives the braceless hash as the property's *value* and renders `{"metadata":{"typelize":"..."}}` — so the walker warns and types it `unknown` instead of asserting a shape that never renders. (This also means a domain field that happens to be named `typelize` or `inertia` inside a plain hash value is never stripped from your JSON.)

The `typelize:` kwarg always wins — it's scoped to that exact property at that exact nesting level, so a nested `json.stats { json.total @t, typelize: "number" }` never affects a top-level `total`. Use it when you need to pin a shape that the walker can't infer.

`typelize:` applies to named `json.<name>` calls; on multi-attribute emitters (`json.extract!`, `json.array!`, `json.(...)`) it has no per-field meaning, so it's ignored for type generation — but still render-safe (stripped before jbuilder sees it).

## Partials

Partials referenced via `json.partial!` or the `partial:` kwarg are resolved to their own generated interfaces. Resolution follows Rails partial-lookup semantics: a bare name (`json.partial! "widget"`) resolves against the current template's directory first; a prefixed name (`"posts/post"`) resolves against the views root. Both the positional form and the kwargs-only form (`json.partial! partial: "posts/post", collection: @posts, as: :post`) are supported.

With multiple discovery roots (several `jbuilder_views` entries or `discover` calls — e.g. a core root plus an overlay root that reference each other's partials), resolution mirrors Rails' view-path stack: after the template's own root misses, every other registered root is tried in registration order, and the first root containing the partial wins. A cross-root partial registers under the root it was found in, so its type name derives from *that* root's layout. Single-root apps are unaffected.

Merging a partial at the template root (properties flow into the current type):

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
import type {User, PostCategory} from '@/types'

type PostsShow = {
  id: number;
  title: string | null;
  body: string | null;
  published_at: string | null;
  category: PostCategory;
  author: User;
  summary: string;
}
```

Note the two different mechanics: the top-level `json.partial!` merges the partial's properties into `PostsShow` itself, while `json.author do json.partial! ... end` references the partial as a **named imported type** (`User`) — see [Composed partials](#composed-partials-named-intersections).

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

If the name doesn't match the plurality of the value (e.g. a collection named `data`), pin it with `typelize:` or rename the property. Known ActiveRecord collection methods on the argument (`all`, `where`, `includes`, `order`, `limit`, `offset`, `group`, `distinct`, `none`) also force array inference — custom scopes like `recent` or `active` are **not** recognized statically; use a plural property name or `typelize:`.

Words that look plural but are conceptually singular (`news`, `settings`, `earnings`, `analytics`, `statistics`, `series`) are treated as singular. Apps with additional domain-specific cases can extend Rails' inflector (`ActiveSupport::Inflector.inflections { |i| i.uncountable %w[...] }`) — the heuristic consults it.

Recursive partials work too — Typelizer memoizes interfaces per class, so a `_comment.json.jbuilder` that references itself via `partial: "comments/comment"` produces a stable self-referential type.

## Blocks and nested shapes

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

### Collection + attribute shortcut

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

### Literal arrays with `json.child!`

A block whose body builds elements with `json.child!` is jbuilder's literal-array form — the property becomes an **array**. The element type merges every child's shape with the same widening rules as conditional branches: keys present in every child stay required, the rest become optional (and nullability widens across children):

```ruby
# A PWA manifest's icon list
json.icons do
  json.child! do
    json.src image_path("icon-192.png")
    json.type "image/png"
    json.sizes "192x192"
  end
  json.child! do
    json.src image_path("icon-512.png")
    json.type "image/png"
    json.sizes "512x512"
    json.purpose "maskable"
  end
end
```

Generates:

```typescript
{
  icons: Array<{
    src: unknown;
    type: string;
    sizes: string;
    purpose?: string;
  }>;
}
```

Two caveats:

- **Mixed content**: putting `json.child!` calls and named properties in one block renders both into the same value at runtime — a shape TypeScript can't express on one key. The walker types the array elements only, drops the named properties from the type, and warns; use `typelize:` to pin the full type.
- **No enclosing property**: `json.child!` outside a `json.<name>` block (e.g. at the template root) cannot be statically typed and is skipped with a warning.

### Literal `json.set!` keys

`json.set!` with a literal String or Symbol key is statically known and flows through normal property typing — value, block, `partial:`, and attribute-shortcut forms all work, exactly as if the key were a method call. String keys exist precisely for names that aren't valid Ruby method names; such names render quoted (see [Type names](#type-names)):

```ruby
json.set! "kebab-key", "value"   # → 'kebab-key': string;
json.set! :score, 42             # → score: number;
```

Only a *dynamic* key (`json.set! some_variable, value`) is skipped with a warning.

## Composed partials: named intersections {#composed-partials-named-intersections}

A block whose body composes partials emits a **named intersection** instead of an inline shape. Every top-level `json.partial!` in the block with a string-literal reference (no `collection:` kwarg, resolvable template) becomes a named imported interface; whatever else the block contains — own props, conditionals, dynamic or collection partials — trails the intersection as an inline shape:

```ruby
json.course do
  json.partial! "courses/course", course: @course
  json.partial! "courses/course_details", course: @course
end

json.course_with_progress do
  json.partial! "courses/course", course: @course
  json.progress 0.5, typelize: "number"
end
```

Generates:

```typescript
import type {Course, CourseDetails} from '@/types'

{
  course: Course & CourseDetails;
  course_with_progress: Course & {
    progress: number;
  };
}
```

This is structurally identical to inlining the partials' fields — TypeScript is structurally typed — but keeps the names, so frontend code can keep importing `Course` directly.

### Faking traits with composed partials

[Alba traits](/guides/alba#traits) generate named intersection types (`Course & CourseDetailsTrait`). Jbuilder doesn't have a direct equivalent, but composed partials produce the same shape. Define one partial per "trait":

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

Generates:

```typescript
import type {Course, CourseDetails, CourseClassmates} from '@/types'

type DashboardCoursesShow = {
  course: Course & CourseDetails & CourseClassmates;
}
```

`course.description`, `course.lessons.map(...)`, etc. all type-check, and each partial keeps its own named type for downstream components — the same ergonomics as Alba's `with_traits: [...]`, decided in the template instead of at serializer-call time.

Named members require a string-literal, non-collection, resolvable `json.partial!` call. A collection partial (`collection:` kwarg) or a dynamic reference never becomes a named member — it stays on the regular extraction path (with its warning if it can't be typed).

## Root arrays

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

A kwargs-only collection partial at the template root also becomes a root array (the partial's properties are inlined into the `...Data` alias):

```ruby
# posts/index.json.jbuilder
json.partial! partial: "posts/post", collection: @posts, as: :post
# → type PostsIndex = Array<PostsIndexData>
```

A root `json.array!` with a `partial:` option instead references the partial's interface **by name** — the whole type becomes an array of the imported partial type, with no inline Data alias:

```ruby
# portals/index.json.jbuilder
json.array! @portals, partial: "portals/portal", as: :portal
# → import type {Portal} from '@/types'
#   type PortalsIndex = Array<Portal>;
```

A dynamic `partial:` value keeps the dynamic-reference warning (the root stays an object); an unresolvable or empty partial warns and degrades to `Array<unknown>`.

A blockless root `json.array! @xs, :attrs` types as a root array of the attribute shape, and `json.(collection) { |el| ... }` (jbuilder's `call` form) is detected like `array!` — root-array detection also sees through `cache!`/`cache_if!`/`cache_root!` wrappers. One form can't participate and logs a warning instead of silently mistyping: a root array nested inside a conditional (the root stays an object).

## Conditional fields

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

### If/else branches

When the same property appears in every branch of an `if/elsif/else` (or `unless/else`) chain that terminates in `else`, it stays **required** — one branch always fires, so the key is always set:

```ruby
if @active
  json.status "active"
  json.reason "still active"
elsif @blocked
  json.status "blocked"
else
  json.status "idle"
end
```

Generates:

```typescript
{
  status: string;   // required — every branch emits it
  reason?: string;  // optional — missing from two branches
}
```

Chains without a final `else` fall back to optional, since one condition combination can skip every branch.

When branches disagree, same-name properties are merged with these rules:

- **Nullability widens.** A branch emitting `null` (or a nullable type) makes the merged property nullable: `json.category @c, partial: "categories/category"` in one branch plus `json.category nil` in the other generates `category: Category | null`.
- **Optionality widens.** A property marked optional in *any* branch (e.g. via `inertia: :defer`) stays optional after the merge — and it's widened exactly once, not doubled.
- **Base types don't union.** When branches disagree on the base type (`string` vs `number`), the first branch's type wins — except that an explicit `typelize:` assertion in any branch beats inferred guesses. Pin the combined type with `typelize:` if the distinction matters.

Re-setting the same key *sequentially* (outside branches) follows jbuilder's runtime re-set semantics instead: a later unconditional write **replaces** the type (`json.status 1` then `json.status "active"` generates `status: string` — including an own property overriding a merged `json.partial!`'s), two object blocks **deep-merge** per key, and a later *conditional* write unions with the earlier type (keys arriving only from the conditional block become optional).

## Caching blocks

`json.cache!`, `json.cache_if!`, and `json.cache_root!` are treated as transparent pass-throughs — the walker descends into their blocks as if the cache wrapper weren't there:

```ruby
json.cache! @post, expires_in: 1.hour do
  json.title @post.title, typelize: "string"
  json.body @post.body, typelize: "string"
end
```

Generates the same properties as if `cache!` were not present.

## Inertia props

When used alongside [jbuilder-inertia](https://github.com/skryukov/jbuilder-inertia) (sibling to [alba-inertia](https://github.com/skryukov/alba-inertia)), Typelizer reads the Inertia prop directives statically and widens deferred/optional props to optional TypeScript keys (`prop?: T`) — those keys are absent from the initial Inertia page load, so the generated types must say so.

Both annotation forms are recognized:

```ruby
# Kwarg form — symbol, array, and hash spellings
json.stats @stats, inertia: :defer                 # → stats?: ...
json.filters @filters, inertia: :optional          # → filters?: ...
json.activity @items, inertia: [:defer, :merge]    # → activity?: ...
json.heavy @data, inertia: {defer: {group: "x"}}   # → heavy?: ...

# Resolver-object form — the block's value feeds type inference
json.stats JbuilderInertia.defer { compute_stats }
json.notifications JbuilderInertia.optional { current_user.notifications.count }
```

Only `defer` and `optional` widen — they're the directives that may omit the key from the initial page load. `merge`, `deep_merge`, `once`, `always`, and `scroll` affect delivery, not presence, so those props stay required. `typelize:` combines with widening: the asserted type is used *and* the property is optional.

For the resolver-object form, the type is inferred from the block's final expression (literals, `Time.*` calls), then name heuristics, then the bound model's columns — same order as everywhere else.

Typelizer never evaluates any of this at runtime. Rendering is jbuilder-inertia's job:

- With jbuilder-inertia installed, `inertia:` kwargs pass through to it untouched, in either gem-load order.
- Without it, Typelizer strips `inertia:` at render time and logs a one-time warning (`` `inertia:` option found but jbuilder-inertia is not installed; option ignored ``) — the template still renders clean JSON. The resolver-object form is different: `JbuilderInertia.defer` is a constant from that gem, so templates using it require the gem to render.

## Warnings and the unknown fallback

The walker is static — it parses templates without running them. Constructs it can't type are skipped with a warning through `Typelizer.logger` (template path and line included) rather than silently dropped:

| Form | Behavior | Workaround |
|---|---|---|
| `json.merge! some_hash` | Skipped + warning (runtime-only shape) | `typelize:` on the surrounding call |
| `json.set! dynamic_key, value` | Skipped + warning (dynamic key) | Literal key (fully typed) or `json.foo typelize: "Record<string, T>"` |
| `json.child!` outside a `json.<name>` block (template root) | Skipped + warning | Wrap in a named block, or `typelize:` |
| `json.child!` mixed with named props in one block | Array elements typed + warning (named props dropped from the type) | `typelize:` to pin the full type |
| `json.partial! some_variable` | Skipped + warning (dynamic reference) | String-literal reference or `typelize:` |
| `json.partial! "missing/thing"` | Skipped + warning (unresolvable template) | Fix the path |
| Collection `partial!` inside a block | Typed as merged object + warning | `json.<name> @collection, partial: "...", as: ...` |
| Blockless `json.array!` inside another block | Object shape + warning | Block form, `partial:` option, or `typelize:` |
| `json.array! @xs, partial: some_variable` | Skipped + warning (dynamic reference; root stays an object) | String-literal `partial:` or `typelize:` |
| Root array inside a conditional | Object type + warning | `typelize:` |
| `@items.each { json.set!(...) { ... } }` (iteration/expression wrapping json calls) | Skipped + warning (body never walked) | `json.array!` block form or `typelize:` |
| `json.cache_collection! @items` (bare or with `partial:`) | Skipped + warning (runtime collection caching) | Collection `json.partial!` or `json.<name> @items, partial: "...", as: ...` |
| `json.extract! obj, *attrs` (splat/dynamic attribute list) | Literal attributes emitted; dynamic ones skipped + warning | List attributes literally or `typelize:` |
| `json.key_format!` / `json.deep_format_keys!` | No property + warning (runtime key casing diverges from source names) | Align casing via `properties_transformer` config |
| `json.ignore_nil!` | No property + warning (nil keys omitted at runtime) | Mark affected properties optional via `typelize:` |
| `json.nil!` / `json.null!` | No property + warning (renders `null` at runtime) | `typelize:` if the null shape matters |
| `json.attributes!` / `json.target!` | No property + warning (jbuilder internal accessors) | Not needed |
| `.jb` / Rabl templates | Not supported | Use `.json.jbuilder` |

### Unknown fallback {#unknown-fallback}

When every inference step fails — no `typelize:`, no literal, no name hint, no model match — the property is emitted as `unknown`, and Typelizer logs a warning with the template path, line, and a `typelize:` suggestion:

```
Typelizer::Jbuilder: app/views/posts/show.json.jbuilder:4: could not infer a type
for `mystery` — emitted `unknown`; pin it with `typelize:`
(e.g. `json.mystery ..., typelize: "string"`)
```

The warning is decided *after* model inference, so a `json.deleted record.deleted` that a model column rescues never warns. It fires once per template+property per generation cycle. Add `typelize:` to silence it.

## Staged migration from another serializer

Migrating an app from Alba (or another class-based library) to jbuilder templates resource by resource is a supported configuration. Emit jbuilder types through a dedicated writer so the two worlds can't collide in one `index.ts`:

```ruby
Typelizer.configure do |config|
  config.jbuilder_views = [Rails.root.join("app", "views")]

  # Default writer: legacy serializers only
  config.reject_class = ->(serializer:) {
    serializer.name.to_s.start_with?("Typelizer::Jbuilder::Templates::")
  }

  # Jbuilder templates get their own output dir and barrel:
  config.writer(:jbuilder) do |w|
    w.output_dir = Rails.root.join("app/javascript/types/jbuilder")
    w.reject_class = ->(serializer:) {
      !serializer.name.to_s.start_with?("Typelizer::Jbuilder::Templates::")
    }
  end
end
```

If you'd rather keep a single writer and index, retire legacy serializers from it as their templates land — `Typelizer::Jbuilder.exclude(*patterns)` builds a `reject_class` predicate that rejects serializers matching the patterns while always keeping template-derived classes, so the Ruby files can stay until the migration completes:

```ruby
config.reject_class = Typelizer::Jbuilder.exclude(/Resource\z/)
```

Notes that make this safe:

- **Cleanup never crosses writers.** Each writer's stale-file cleanup is scoped to its own output dir, even when one writer's dir is nested inside another's (`types/jbuilder` inside `types`).
- **Duplicate exports warn.** If two sources resolve to the same exported type name in *one* index (Alba `PostResource` → `Post` alongside `posts/_post.json.jbuilder` → `Post`), generation logs a warning naming both sources. Scope the writers' `reject_class` or rename one side with `typelize_as`. The same name across *separate* writers is fine — that's the migration setup.

## Plugin configuration

Discovery is configured at the top level (these are global, not per-writer, settings):

```ruby
Typelizer.configure do |config|
  # Discovery roots; setting this enables the plugin
  config.jbuilder_views = [Rails.root.join("app", "views")]

  # Explicit enablement override (default nil = auto-detect from jbuilder_views)
  config.jbuilder_enabled = nil
end
```

With the [Listen](https://github.com/guard/listen) gem installed, the `jbuilder_views` roots are also watched for `.jbuilder` changes in development, alongside the regular serializer watching.

A fallback views root for partial resolution can be set via `plugin_configs` (registered templates normally carry their own root, so this rarely needs to be set):

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
