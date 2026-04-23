# Manual Typing

Typelizer infers types from your database columns and associations automatically. When you have computed attributes, custom types, or need finer control, use the `typelize` method to specify types manually.

## Typing a Single Attribute

Place `typelize` before an attribute to annotate its type:

```ruby
class PostResource < ApplicationResource
  attributes :id, :title, :body, :published_at

  typelize "string"
  attribute :author_name do |post|
    post.author.name
  end

  typelize :string, nullable: true, comment: "Author's avatar URL"
  attribute :avatar do
    "https://example.com/avatar.png" if active?
  end
end
```

This generates:

```typescript
export type Post = {
  id: number;
  title: string;
  body: string;
  published_at: string;
  author_name: string;
  /** Author's avatar URL */
  avatar: string | null;
}
```

## Typing Multiple Attributes

Use a Hash to specify types for several attributes at once:

```ruby
class PostResource < ApplicationResource
  attributes :id, :title, :body, :published_at

  attribute :author_name do |post|
    post.author.name
  end

  typelize author_name: :string, published_at: :string
end
```

## Shortcut Syntax

Common type modifiers have shortcut forms:

```ruby
class PostResource < ApplicationResource
  typelize author_name: "string?"       # optional string (author_name?: string)
  typelize tag_ids: "number[]"          # array of numbers (tag_ids: Array<number>)
  typelize categories: "string?[]"      # optional array of strings (categories?: Array<string>)

  # Use the `?` suffix on the key as an alternative to the type shortcut
  typelize nickname?: "string"          # same as nickname: "string?"
  typelize avatar_url?: [:string, nullable: true]

  # Shortcuts can be combined with explicit options
  typelize status: [:string?, nullable: true]  # optional and nullable

  # Also works with keyless typelize
  typelize :string?
  attribute :slug do |post|
    post.slug
  end
end
```

This generates:

```typescript
export type Post = {
  author_name?: string;
  tag_ids: Array<number>;
  categories?: Array<string>;
  nickname?: string;
  avatar_url?: string | null;
  status?: string | null;
  slug?: string;
}
```

::: tip
The `?` suffix on keys mirrors TypeScript's own syntax and composes with the `"string?"` type shortcut -- both forms produce the same output, so pick whichever reads better for your attribute.

Explicit options win when they conflict: `typelize name?: [:string, optional: false]` produces `name: string` (required).
:::

## Inline Object Types

Pass a hash literal with keyless `typelize` to describe an inline object type -- useful for JSON columns, computed hashes, and ad-hoc shapes that don't warrant a separate resource:

```ruby
class PostResource < ApplicationResource
  attributes :id, :title

  typelize({id: :number, label: "string?"})
  attribute :category do |post|
    {id: post.category_id, label: post.category_name}
  end
end
```

This generates:

```typescript
export type Post = {
  id: number;
  title: string;
  category: {
    id: number;
    label?: string;
  };
}
```

::: warning
Note the parentheses: `typelize({...})` passes the hash as a positional argument -- the inline shape form. `typelize(key: value)` without braces is keyword arguments -- the attribute-typing form. This is the same distinction Ruby itself makes.
:::

### Composing with Modifiers

Pass options as the second argument -- they apply to the shape as a whole:

```ruby
class PostResource < ApplicationResource
  # Array of shapes
  typelize({id: :number, name: :string}, multi: true)
  attribute :tags

  # Optional + nullable shape
  typelize({street: :string, city: :string}, optional: true, nullable: true)
  attribute :address
end
```

This generates:

```typescript
export type Post = {
  tags: Array<{
    id: number;
    name: string;
  }>;
  address?: {
    street: string;
    city: string;
  } | null;
}
```

### Nested Shapes

Values can themselves be hashes -- nest as deep as you need:

```ruby
class OrderResource < ApplicationResource
  attributes :id

  typelize({
    customer: {name: :string, email?: :string},
    totals: {subtotal: :number, tax: :number, grand_total: :number}
  })
  attribute :summary
end
```

This generates:

```typescript
export type Order = {
  id: number;
  summary: {
    customer: {
      name: string;
      email?: string;
    };
    totals: {
      subtotal: number;
      tax: number;
      grand_total: number;
    };
  };
}
```

### Mixing Shapes with Type Shortcuts

Shape values accept anything a regular `typelize` value accepts, including string shortcuts and unions:

```ruby
class FeedItemResource < ApplicationResource
  typelize({
    payload: "TextBlock | ImageBlock",
    tags: "string[]"
  })
  attribute :item
end
```

This generates:

```typescript
export type FeedItem = {
  item: {
    payload: TextBlock | ImageBlock;
    tags: Array<string>;
  };
}
```

::: tip
For serializers using Alba's `nested_attribute`, Typelizer already infers the shape from the block -- you don't need `typelize` in that case. Use inline shapes when typing computed attributes, JSON columns, or overriding the inferred shape.
:::

## Referencing Other Serializers

Pass a serializer class directly. Typelizer resolves it to the generated TypeScript type name:

```ruby
class PostResource < ApplicationResource
  attributes :id, :title

  # Reference another serializer
  typelize reviewer: [AuthorResource, {optional: true, nullable: true}]
  attribute :reviewer do |post|
    post.reviewer
  end

  # Self-reference works too
  typelize previous_post: PostResource
  attribute :previous_post do |post|
    post.previous_post
  end
end
```

## Union Types

For polymorphic associations, use serializer class references or pipe-delimited strings:

```ruby
class PostResource < ApplicationResource
  attributes :id, :title

  # Union of two serializers
  typelize commentable: [UserResource, CommentResource]
  attribute :commentable

  # Nullable union -- extracts null and marks as nullable
  typelize approver: "AuthorResource | null"
  attribute :approver

  # Pipe-delimited string with serializer names
  typelize target: "UserResource | CommentResource"
  attribute :target

  # Pipe-delimited string with namespaced serializer
  typelize item: "Namespace::UserResource | CommentResource"
  attribute :item
end
```

Plain TypeScript type names are passed through as-is:

```ruby
class PostResource < ApplicationResource
  attributes :id, :title

  # Plain type names
  typelize content: "TextBlock | ImageBlock"
  attribute :content

  # Works with arrays of symbols too
  typelize sections: [:TextBlock, :ImageBlock]
  attribute :sections
end
```

This generates:

```typescript
type Post = {
  id: number;
  title: string;
  content: TextBlock | ImageBlock;
  sections: TextBlock | ImageBlock;
}
```

## String Literal Unions

Arrays of strings become string literal union types -- useful for enums and state machines:

```ruby
class PostResource < ApplicationResource
  attributes :id, :title

  # Array of strings
  typelize status: ["draft", "published", "archived"]
  attribute :status

  # Works with Rails enums and state machines
  typelize review_state: ReviewStateMachine.states.keys
  attribute :review_state
end
```

This generates:

```typescript
type Post = {
  id: number;
  title: string;
  status: 'draft' | 'published' | 'archived';
  review_state: 'pending' | 'approved' | 'rejected';
}
```

::: tip
In arrays, **strings** become string literal types (`'a'`), while **symbols** and **class constants** become type references (`A`). You can mix them: `[:number, "auto"]` produces `number | 'auto'`.
:::

## Full API

The `typelize` method supports these options:

```ruby
typelize attribute_name: [
  :string, :Date,
  optional: true,
  nullable: true,
  multi: true,
  enum: %w[foo bar],
  comment: "Attribute description",
  deprecated: "Use `another_attribute` instead"
]
```

| Option | Effect |
|---|---|
| `optional` | Makes the property optional (`name?: type`). Equivalent to a `?` suffix on the attribute key or type shortcut. |
| `nullable` | Adds `null` to the type (`type \| null`) |
| `multi` | Wraps in `Array<type>` |
| `enum` | Generates string literal union |
| `comment` | Adds a JSDoc comment above the property |
| `deprecated` | Adds a `@deprecated` JSDoc tag |

For inline object types, pass a **positional** hash: `typelize({key: type, ...}, options)`. See [Inline Object Types](#inline-object-types).

The behaviour of `nullable` depends on your [`null_strategy` configuration](/reference/configuration#full-option-reference).
