# Alba

This guide covers using Typelizer with [Alba](https://github.com/okuramasafumi/alba). Alba has the richest integration -- traits, nested attributes, typed attributes, inline serializers, and key transformation are all supported.

## Setup

Add `Typelizer::DSL` to your base resource using Alba's `helper` method:

```ruby
class ApplicationResource
  include Alba::Resource
  helper Typelizer::DSL
end
```

## Attributes and Associations

Define attributes and associations as usual. Typelizer infers types from the underlying model:

```ruby
class PostResource < ApplicationResource
  attributes :id, :title, :body

  has_one :author, resource: AuthorResource
  has_many :comments, resource: CommentResource
end
```

Use `typelize_from` when the model name can't be inferred from the serializer name:

```ruby
class AuthorResource < ApplicationResource
  typelize_from User
  attributes :id, :name
end
```

## Key Transformation

Alba's `transform_keys` is respected. Typelizer transforms property names in the generated TypeScript to match:

```ruby
class PostResource < ApplicationResource
  transform_keys :lower_camel

  attributes :id, :title, :created_at
end
```

Generates:

```typescript
export type Post = {
  id: number;
  title: string;
  createdAt: string;
}
```

## Traits

Typelizer generates separate TypeScript types for each [Alba trait](https://github.com/okuramasafumi/alba#traits):

```ruby
class UserResource < ApplicationResource
  attributes :id, :name

  trait :detailed do
    attributes :email, :created_at
  end

  trait :with_posts do
    has_many :posts, resource: PostResource, with_traits: [:summary]
  end
end
```

This generates:

```typescript
// User.ts
export type User = {
  id: number;
  name: string;
}

type UserDetailedTrait = {
  email: string;
  created_at: string;
}

type UserWithPostsTrait = {
  posts: Array<Post & PostSummaryTrait>;
}

export default User;
```

### Trait Composition with `with_traits`

Use `with_traits` on associations to generate intersection types:

```ruby
class TeamResource < ApplicationResource
  attributes :id, :name
  has_one :lead, resource: UserResource, with_traits: [:detailed]
  has_many :members, resource: UserResource, with_traits: [:detailed, :with_posts]
end
```

Generates:

```typescript
import type { User, UserDetailedTrait, UserWithPostsTrait } from "@/types";

export type Team = {
  id: number;
  name: string;
  lead: User & UserDetailedTrait;
  members: Array<User & UserDetailedTrait & UserWithPostsTrait>;
}
```

### Manual Typing Inside Traits

The `typelize` method works inside trait blocks:

```ruby
trait :with_stats do
  typelize :number
  attribute :posts_count do |user|
    user.posts.count
  end

  typelize word_count: :number
  attributes :word_count
end
```

## Nested Attributes

Alba's `nested` blocks create inline object types:

```ruby
class UserResource < ApplicationResource
  attributes :id, :name

  nested :details do
    attributes :role
    nested :timestamps do
      attributes :created_at, :updated_at
    end
  end
end
```

Generates:

```typescript
export type User = {
  id: number;
  name: string;
  details: {
    role: string;
    timestamps: {
      created_at: string;
      updated_at: string;
    };
  };
}
```

## Inline Serializers

Define serializers inline within associations:

```ruby
class UserResource < ApplicationResource
  attributes :id, :name

  has_many :posts do
    typelize id: :number
    attributes :id, title: [String, true]
  end
end
```

## Typed Attributes

Alba's [typed attributes](https://github.com/okuramasafumi/alba#typed-attributes) are mapped via the `ts_mapper`. The default mapping:

| Alba Type | TypeScript Type |
|---|---|
| `String` | `string` |
| `Integer` | `number` |
| `Boolean` | `boolean` |
| `ArrayOfString` | `Array<string>` |
| `ArrayOfInteger` | `Array<number>` |

Customize the mapping via `plugin_configs`:

```ruby
Typelizer.configure do |config|
  config.plugin_configs = {
    alba: {
      ts_mapper: {
        "String" => { type: :string },
        "UUID" => { type: :string },
        "Money" => { type: :number }
      }
    }
  }
end
```

## Meta

When using Alba's `root_key!` and `meta`, Typelizer includes the meta field:

```ruby
class PostResource < ApplicationResource
  root_key!

  typelize_meta metadata: "{foo: 'bar'}"
  meta :metadata do
    { foo: :bar }
  end

  attributes :id, :title
end
```

See [Manual Typing](/guides/manual-typing) for full details on the `typelize` method.
