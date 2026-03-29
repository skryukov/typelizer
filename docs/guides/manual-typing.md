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
  typelize author_name: "string?"       # optional string (name?: string)
  typelize tag_ids: "number[]"          # array of numbers (tag_ids: Array<number>)
  typelize categories: "string?[]"      # optional array of strings (categories?: Array<string>)

  # Shortcuts can be combined with explicit options
  typelize status: [:string?, nullable: true]  # optional and nullable

  # Also works with keyless typelize
  typelize :string?
  attribute :nickname do |user|
    user.nickname
  end
end
```

This generates:

```typescript
export type Post = {
  author_name?: string;
  tag_ids: Array<number>;
  categories?: Array<string>;
  status?: string | null;
  nickname?: string;
}
```

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
| `optional` | Makes the property optional (`name?: type`) |
| `nullable` | Adds `null` to the type (`type \| null`) |
| `multi` | Wraps in `Array<type>` |
| `enum` | Generates string literal union |
| `comment` | Adds a JSDoc comment above the property |
| `deprecated` | Adds a `@deprecated` JSDoc tag |

The behaviour of `nullable` depends on your [`null_strategy` configuration](/reference/configuration#full-option-reference).
