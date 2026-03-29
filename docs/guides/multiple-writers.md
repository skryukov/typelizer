# Multiple Writers

The multi-writer system generates multiple, distinct TypeScript outputs from the same serializers. Each output is managed by a named writer with an isolated configuration. Use this when you need different naming conventions (e.g., snake_case and camelCase) or separate output directories for different parts of your app.

## Single Output (Default)

For most apps, a single output is enough. All settings in an initializer apply to the `:default` writer and also act as a global baseline:

```ruby
# config/initializers/typelizer.rb
Typelizer.configure do |config|
  # Global setting -- applies to ALL writers
  config.dirs = [Rails.root.join("app/serializers")]

  # Configures the :default writer and also acts as a global setting
  config.output_dir = "app/javascript/types/generated"
  config.comments = true
end
```

## Defining a New Writer

Define additional writers with `config.writer`:

```ruby
Typelizer.configure do |config|
  config.writer(:camel_case) do |c|
    c.output_dir = "app/javascript/types/camel_case"
    c.properties_transformer = ->(properties) { # ... transform ... }
  end
end
```

Or use the top-level helper:

```ruby
Typelizer.writer(:admin, from: :default) do |c|
  c.output_dir = Rails.root.join("app/javascript/types/admin")
  c.prefer_double_quotes = true
end
```

## Inheritance Rules

Writers inherit settings in a specific order:

1. A new writer inherits from **Global Settings** by default.
2. Use `from:` to inherit from another existing writer instead.
3. The `:default` writer block settings are **not** inherited by other writers.

This distinction matters. Declare `writer(:default)` when you want to apply settings that should not be inherited by other writers:

```ruby
Typelizer.configure do |config|
  # Global -- inherited by all writers
  config.comments = true

  # Default-writer-only -- NOT inherited by :camel_case
  config.writer(:default) do |c|
    c.prefer_double_quotes = true
  end

  # Inherits `comments: true` from globals
  # Does NOT inherit `prefer_double_quotes: true` from :default block
  config.writer(:camel_case) do |c|
    c.output_dir = "app/javascript/types/camel_case"
  end
end
```

## Inheriting from Another Writer

Use `from:` to clone another writer's complete configuration:

```ruby
config.writer(:admin, from: :camel_case) do |c|
  c.output_dir = "app/javascript/types/admin"
  # Inherits the properties_transformer from :camel_case
  c.null_strategy = :optional
end
```

## Comprehensive Example

This example configures three distinct outputs, demonstrating all inheritance mechanisms:

```ruby
# config/initializers/typelizer.rb
Typelizer.configure do |config|
  # 1. Global Settings (baseline for ALL writers)
  config.comments = true
  config.dirs = [Rails.root.join("app/serializers")]

  # 2. The :default writer (snake_case output)
  config.writer(:default) do |c|
    c.output_dir = "app/javascript/types/snake_case"
  end

  # 3. A new :camel_case writer
  # Inherits `comments: true` and `dirs` from Global Settings.
  config.writer(:camel_case) do |c|
    c.output_dir = "app/javascript/types/camel_case"
    c.properties_transformer = lambda do |properties|
      properties.map { |prop| prop.with_overrides(name: prop.name.to_s.camelize(:lower)) }
    end
  end

  # 4. An "admin" writer that clones :camel_case
  # Uses `from:` to inherit another writer's complete configuration.
  config.writer(:admin, from: :camel_case) do |c|
    c.output_dir = "app/javascript/types/admin"
    # Inherits the properties_transformer from :camel_case.
    c.null_strategy = :optional
  end
end
```

See the [Configuration Reference](/reference/configuration) for all available options.
