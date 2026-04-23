# Configuration

::: info Supported serializers
Typelizer works with Alba, ActiveModel::Serializer, Oj::Serializer, and Panko::Serializer. jbuilder, `as_json`, and JSONAPI::Serializer are not currently supported.
:::

## Global Settings

These settings apply to all writers and are set on the `Typelizer` module directly:

```ruby
# Directories to search for serializers
Typelizer.dirs = [Rails.root.join("app", "resources"), Rails.root.join("app", "serializers")]

# Reject specific classes from being typelized
Typelizer.reject_class = ->(serializer:) { false }

# Logger for debugging
Typelizer.logger = Logger.new($stdout, level: :info)

# Force enable or disable file watching with Listen
Typelizer.listen = nil
```

## Configuration Layers

Typelizer uses a hierarchical system to resolve settings. Higher numbers override lower ones:

1. **Library Defaults** -- the gem's built-in default values
2. **Global Settings** -- application-wide settings in the `Typelizer.configure` block
3. **Writer-Specific Settings** -- settings within a `config.writer(:name)` block
4. **Per-Serializer Overrides** -- settings defined using `typelizer_config` in a serializer class (highest priority)

## Writer Configuration

Define writers inside the configure block or via the top-level helper. See [Multiple Writers](/guides/multiple-writers) for a full guide.

```ruby
Typelizer.configure do |config|
  config.writer(:camel_case) do |c|
    c.output_dir = "app/javascript/types/camel_case"
    c.properties_transformer = ->(properties) { # ... }
  end
end
```

## Per-Serializer Configuration

Use `typelizer_config` to apply overrides with the highest priority:

```ruby
class PostResource < ApplicationResource
  typelizer_config do |c|
    c.null_strategy = :nullable_and_optional
    c.plugin_configs = { alba: { ts_mapper: { "UUID" => { type: :string } } } }
  end
end
```

Override `output_dir` per serializer to place its generated file in a different directory:

```ruby
class Admin::UserResource < ApplicationResource
  typelizer_config do |c|
    c.output_dir = Rails.root.join("app/javascript/types/admin")
  end
end
```

## Route Configuration {#route-configuration}

Configure route generation via `Typelizer.configuration.routes`:

```ruby
Typelizer.configure do |config|
  config.routes.enabled = true
  config.routes.output_dir = Rails.root.join("app/javascript/routes")
  config.routes.camel_case = true
  config.routes.format = :ts
  config.routes.include = [/^\/api/]
  config.routes.exclude = [/^\/admin/]
end
```

| Option | Type | Default | Description |
|---|---|---|---|
| `enabled` | `Boolean` | `false` | Enable route helper generation |
| `output_dir` | `String` | Auto-detected | Output directory. Defaults to `{js_root}/routes` |
| `include` | `Regexp`, `Array` | `nil` | Only generate routes matching these patterns |
| `exclude` | `Regexp`, `Array` | `nil` | Skip routes matching these patterns |
| `camel_case` | `Boolean` | `true` | Convert route keys to camelCase |
| `format` | `Symbol` | `:ts` | Output format: `:ts` or `:js` |

See the [Route API Reference](/reference/route-api) for details on the generated output.

## Rake Tasks {#rake-tasks}

```bash
# Generate TypeScript interfaces from serializers
rails typelizer:types

# Clean output directory and regenerate all interfaces
rails typelizer:types:refresh

# Generate TypeScript route helpers
rails typelizer:routes

# Clean and regenerate all route helpers
rails typelizer:routes:refresh

# Generate both types and routes
rails typelizer:generate

# Clean and regenerate everything
rails typelizer:generate:refresh
```

## Environment Variables {#environment-variables}

| Variable | Effect |
|---|---|
| `TYPELIZER=true` | Force-enable Typelizer (overrides environment detection) |
| `TYPELIZER=false` | Force-disable Typelizer (does not affect manual `rake` tasks) |

When neither variable is set, Typelizer is enabled in development mode (detected via `Rails.env.development?` when Rails is loaded, or via `RAILS_ENV=development` / `RACK_ENV=development` otherwise).

## Full Option Reference {#full-option-reference}

All options below can be set in the `Typelizer.configure` block, in a `writer` block, or in `typelizer_config` on a serializer:

```ruby
Typelizer.configure do |config|
  # Name to type mapping for serializer classes
  config.serializer_name_mapper = ->(serializer) { ... }

  # Custom file path mapping (decouples filename from type name)
  # Receives the mapped name (output of serializer_name_mapper) and returns a file path.
  # When nil (default), filename is derived from the type name.
  # Example: ->(name) { name.gsub("::", "/") }
  config.filename_mapper = nil

  # Maps serializers to their corresponding model classes
  config.serializer_model_mapper = ->(serializer) { ... }

  # Custom transformation for generated properties
  config.properties_transformer = ->(properties) { ... }

  # Strategy for ordering properties in generated TypeScript interfaces
  # :none - preserve serializer definition order (default)
  # :alphabetical - sort properties A-Z (case-insensitive)
  # :id_first_alphabetical - place 'id' first, then sort remaining A-Z
  # Proc - custom sorting function receiving array of Property objects
  config.properties_sort_order = :none

  # Strategy for ordering imports in generated TypeScript interfaces
  # :none - preserve original order (default)
  # :alphabetical - sort imports A-Z (case-insensitive)
  # Proc - custom sorting function receiving array of import strings
  config.imports_sort_order = :none

  # Plugin for model type inference (default: ModelPlugins::Auto)
  config.model_plugin = Typelizer::ModelPlugins::Auto

  # Plugin for serializer parsing (default: SerializerPlugins::Auto)
  config.serializer_plugin = Typelizer::SerializerPlugins::Auto

  # Additional configurations for specific plugins
  config.plugin_configs = { alba: { ts_mapper: {...} } }

  # Custom DB to TypeScript type mapping
  config.type_mapping = config.type_mapping.merge(jsonb: "Record<string, unknown>")

  # Strategy for handling null values (:nullable, :optional, or :nullable_and_optional)
  config.null_strategy = :nullable

  # Strategy for handling serializer inheritance (:none, :inheritance)
  # :none - lists all attributes of the serializer in the type
  # :inheritance - extends the type from the parent serializer
  config.inheritance_strategy = :none

  # Strategy for handling has_one and belongs_to associations nullability
  # :database - uses the database column nullability
  # :active_record - uses the required / optional association options
  config.associations_strategy = :database

  # Directory where TypeScript interfaces will be generated
  config.output_dir = Rails.root.join("app/javascript/types/serializers")

  # Import path for generated types in TypeScript files
  config.types_import_path = "@/types"

  # List of type names considered global in TypeScript (not prefixed with import path)
  config.types_global = %w[Array Date Record File FileList]

  # Support TypeScript's Verbatim module syntax option (default: false)
  config.verbatim_module_syntax = false

  # Use double quotes in generated TypeScript interfaces (default: false)
  config.prefer_double_quotes = false

  # Add comments to generated TypeScript interfaces (default: false)
  config.comments = false

  # Emit runtime constants for named enums alongside type aliases (default: false).
  # When enabled, `Enums.ts` also exports an `as const` object per enum and
  # `index.ts` re-exports them as values (not just types), so consumers can
  # both type-check and compare against the values at runtime.
  config.runtime_enums = false
end
```

With `runtime_enums = true`, an ActiveRecord enum like `enum role: {guest: 0, member: 1, admin: 2}` generates:

```ts
// Enums.ts
export type UserRole = 'guest' | 'member' | 'admin';
export const UserRole = { guest: 'guest', member: 'member', admin: 'admin' } as const;
```

And in consuming code:

```ts
import { UserRole } from '@/types'

if (user.role === UserRole.admin) { ... }
```
