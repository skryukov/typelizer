# Oj::Serializer

This guide covers using Typelizer with [Oj::Serializer](https://github.com/ElMassimo/oj_serializers).

## Setup

```ruby
class ApplicationSerializer < Oj::Serializer
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

## Key Transformation

Oj's `transform_keys` is respected:

```ruby
class PostSerializer < ApplicationSerializer
  transform_keys :camel_case

  attributes :id, :title, :created_at
end
```

## Flat Associations

Oj::Serializer's `flat_one` inlines an association's attributes into the parent type alongside the nested reference:

```ruby
class UserSerializer < ApplicationSerializer
  attributes :id, :name

  flat_one :invitor, serializer: UserSerializer
end
```

The invitor's attributes (`username`, `active`, `name`, etc.) are merged directly into the parent type. The `invitor` property itself is also kept in the output.

## Conditional and Nullable Attributes

Oj::Serializer supports `optional` and `nullable` flags directly:

```ruby
class PostSerializer < ApplicationSerializer
  attributes :id, :title
  attribute :draft, optional: true
  attribute :deleted_at, nullable: true
end
```

See [Manual Typing](/guides/manual-typing) for full details on the `typelize` method.
