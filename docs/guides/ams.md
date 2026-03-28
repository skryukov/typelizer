# ActiveModel::Serializer

This guide covers using Typelizer with [ActiveModel::Serializer](https://github.com/rails-api/active_model_serializers) (AMS).

## Setup

```ruby
class ApplicationSerializer < ActiveModel::Serializer
  include Typelizer::DSL
end
```

## Attributes and Associations

Define attributes and associations as usual:

```ruby
class PostSerializer < ApplicationSerializer
  attributes :id, :title, :body

  has_one :author, serializer: AuthorSerializer
  has_many :comments, serializer: CommentSerializer
  belongs_to :created_by, serializer: UserSerializer
end
```

Typelizer infers types from the model. Use `typelize_from` when the model name can't be inferred:

```ruby
class AuthorSerializer < ApplicationSerializer
  typelize_from User
  attributes :id, :name
end
```

## Conditional Attributes

Attributes with `if:` or `unless:` conditions are automatically marked as optional in the generated TypeScript:

```ruby
class UserSerializer < ApplicationSerializer
  attributes :id, :name
  attribute :email, if: :admin?
end
```

Generates:

```typescript
export type User = {
  id: number;
  name: string;
  email?: string;
}
```

## Key Transformation

AMS adapter key transforms are respected:

```ruby
class PostSerializer < ApplicationSerializer
  attributes :id, :title, :created_at
end

# config/initializers/ams.rb
ActiveModelSerializers.config.key_transform = :camel_lower
```

## Custom Methods

Override attributes with methods and annotate with `typelize`:

```ruby
class PostSerializer < ApplicationSerializer
  attributes :id, :title

  typelize :string
  attribute :name, deprecated: "Use 'title' instead."
  def name
    title
  end
end
```

See [Manual Typing](/guides/manual-typing) for full details on the `typelize` method.
