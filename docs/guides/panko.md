# Panko::Serializer

This guide covers using Typelizer with [Panko::Serializer](https://github.com/panko-serializer/panko_serializer).

## Setup

```ruby
class ApplicationSerializer < Panko::Serializer
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
end
```

Typelizer infers types from the model. Use `typelize_from` when the model name can't be inferred:

```ruby
class AuthorSerializer < ApplicationSerializer
  typelize_from User
  attributes :id, :name
end
```

## Custom Methods

Override attributes with methods. Panko requires explicit method definitions (no block syntax):

```ruby
class UserSerializer < ApplicationSerializer
  attributes :id, :name

  has_one :created_by, serializer: UserSerializer

  def created_by
    object.user
  end
end
```

Annotate computed attributes with `typelize`:

```ruby
class PostSerializer < ApplicationSerializer
  attributes :id, :title

  typelize :string
  def display_name
    "#{title} by #{object.author.name}"
  end
end
```

See [Manual Typing](/guides/manual-typing) for full details on the `typelize` method.

## Limitations

Panko associations are always generated as required (non-optional, non-nullable). If you need an optional or nullable association in the generated types, use `typelize` to override it manually.
