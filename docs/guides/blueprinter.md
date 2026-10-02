# Blueprinter

This guide covers using Typelizer with [Blueprinter](https://github.com/procore-oss/blueprinter).

## Setup

```ruby
class ApplicationBlueprint < Blueprinter::Base
  include Typelizer::DSL
end
```

## Fields and Associations

Define fields and associations as usual:

```ruby
class UserBlueprint < ApplicationBlueprint
  identifier :id
  fields :name, :email
  field :created_at, if: ->(_field, _user, options) { options[:admin] }

  association :posts, blueprint: PostBlueprint
end
```

Typelizer infers field types from the model (`UserBlueprint` → `User`). Use `typelize_from` when the model name can't be inferred. Fields and associations with `if:`, `unless:`, or `exclude_if_nil:` are optional.

Blueprinter renders an association as a list or a single object depending on the value, so Typelizer asks the model: a `has_many` association becomes an array. Without a model, set it with `typelize`:

```ruby
typelize items: [ItemBlueprint, multi: true]
association :items, blueprint: ItemBlueprint
```

## Computed Fields

Annotate block fields with `typelize`:

```ruby
class UserBlueprint < ApplicationBlueprint
  typelize :string
  field :full_name do |user, _options|
    "#{user.first_name} #{user.last_name}"
  end
end
```

See [Manual Typing](/guides/manual-typing) for full details on the `typelize` method.

## Views

Each view becomes its own type, named after the blueprint and the view:

```ruby
class UserBlueprint < ApplicationBlueprint
  identifier :id
  fields :name

  view :extended do
    field :email
  end
end
```

```typescript
type User = {
  id: number;
  name: string;
}

type UserExtendedView = {
  id: number;
  email: string;
  name: string;
}
```

An association rendered with a view (`association :posts, blueprint: PostBlueprint, view: :summary`) uses that view's type.

## Limitations

- Transformers (`transform`, `default_transformers`) can rename keys at render time, and Typelizer can't see them. For camelCase keys, use Typelizer's [`properties_transformer`](/reference/configuration).
- `default:`, `field_default`, and `association_default` replace `nil` at render time, but the types still include `| null`.
- An association whose blueprint is a proc, or that uses the `:identifier` view, is typed as `unknown`.
- `root:` and `meta:` are render options, so the generated type describes the blueprint itself, not the wrapper.
