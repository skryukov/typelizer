# Typelizer

[![Gem Version](https://badge.fury.io/rb/typelizer.svg)](https://rubygems.org/gems/typelizer)

Typelizer generates TypeScript types from your Ruby serializers. It supports multiple serializer libraries and a flexible, layered configuration model so you can keep your backend and frontend in sync without hand‑maintaining types.

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
  - [Basic Setup](#basic-setup)
  - [Manual Typing](#manual-typing)
  - [Alba Traits](#alba-traits)
  - [TypeScript Integration](#typescript-integration)
  - [Manual Generation](#manual-generation)
  - [Automatic Generation in Development](#automatic-generation-in-development)
  - [Disabling Typelizer](#disabling-typelizer)
- [Configuration](#configuration)
  - [Global Configuration](#simple-configuration)
  - [Writers (multiple outputs)](#defining-multiple-writers)
  - [Per-Serializer Configuration](#per-serializer-configuration)
- [Credits](#credits)
- [License](#license)

<a href="https://evilmartians.com/?utm_source=typelizer&utm_campaign=project_page">
<img src="https://evilmartians.com/badges/sponsored-by-evil-martians.svg" alt="Built by Evil Martians" width="236" height="54">
</a>

## Features

- Automatic TypeScript interface generation
- Infers types from database columns and associations, with support for the Attributes API
- Supports multiple serializer libraries (`Alba`, `ActiveModel::Serializer`, `Oj::Serializer`, `Panko::Serializer`)
- File watching with automatic regeneration in development
- Multiple output writers: emit several variants (e.g., snake_case and camelCase) in parallel

## Installation

To install Typelizer, add the following line to your `Gemfile` and run `bundle install`:

```ruby
gem "typelizer"
```

## Usage

### Basic Setup

Include the Typelizer DSL in your serializers:

```ruby
class ApplicationResource
  include Alba::Resource
  include Typelizer::DSL

  # For Alba, we recommend using the `helper` method instead of `include`.
  # See the documentation: https://github.com/okuramasafumi/alba/blob/main/README.md#helper
  # helper Typelizer::DSL
end

class PostResource < ApplicationResource
  attributes :id, :title, :body

  has_one :author, serializer: AuthorResource
end

class AuthorResource < ApplicationResource
  # specify the model to infer types from (optional)
  typelize_from User

  attributes :id, :name
end
```

Typelizer will automatically generate TypeScript interfaces based on your serializer definitions using information from your models.

### Manual Typing

You can manually specify TypeScript types in your serializers:

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

`typelize` can be used with a Hash to specify multiple types at once.

```ruby
class PostResource < ApplicationResource
  attributes :id, :title, :body, :published_at

  attribute :author_name do |post|
    post.author.name
  end

  typelize author_name: :string, published_at: :string
end
```

You can also use shortcut syntax for common type modifiers:

```ruby
class PostResource < ApplicationResource
  typelize author_name: "string?"       # optional string (name?: string)
  typelize tag_ids: "number[]"          # array of numbers (tag_ids: Array<number>)
  typelize categories: "string?[]"      # optional array of strings (categories?: Array<string>)

  # Shortcuts can be combined with explicit options
  typelize status: ["string?", nullable: true]  # optional and nullable

  # Also works with keyless typelize
  typelize "string?"
  attribute :nickname do |user|
    user.nickname
  end
end
```

For more complex type definitions, use the full API:

```ruby
typelize attribute_name: ["string", "Date", optional: true, nullable: true, multi: true, enum: %w[foo bar], comment: "Attribute description", deprecated: "Use `another_attribute` instead"]
```

### Alba Traits

Typelizer supports [Alba traits](https://github.com/okuramasafumi/alba#traits), generating separate TypeScript types for each trait. When using `with_traits` in associations, Typelizer generates intersection types.

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

When using `with_traits` in associations, Typelizer generates intersection types combining the base type with trait types:

```ruby
class TeamResource < ApplicationResource
  attributes :id, :name
  has_one :lead, resource: UserResource, with_traits: [:detailed]
  has_many :members, resource: UserResource, with_traits: [:detailed, :with_posts]
end
```

This generates:

```typescript
// Team.ts
import type { User, UserDetailedTrait, UserWithPostsTrait } from "@/types";

export type Team = {
  id: number;
  name: string;
  lead: User & UserDetailedTrait;
  members: Array<User & UserDetailedTrait & UserWithPostsTrait>;
}

export default Team;
```

The `typelize` method works inside traits for manual type specification:

```ruby
trait :with_stats do
  typelize :number
  attribute :posts_count do |user|
    user.posts.count
  end

  typelize score: :number
  attributes :score
end
```

### TypeScript Integration

Typelizer generates TypeScript interfaces in the specified output directory:

```typescript
// app/javascript/types/serializers/Post.ts
export interface Post {
  id: number;
  title: string;
  category?: "news" | "article" | "blog" | null;
  body: string;
  published_at: string | null;
  author_name: string;
}
```

All generated interfaces are automatically imported in a single file:

```typescript
// app/javascript/types/serializers/index.ts
export * from "./post";
export * from "./author";
```

We recommend importing this file in a central location:

```typescript
// app/javascript/types/index.ts
import "@/types/serializers";
// Custom types can be added here
// ...
```

With such a setup, you can import all generated interfaces in your TypeScript files:

```typescript
import { Post } from "@/types";
```

This setup also allows you to use custom types in your serializers:

```ruby
class PostWithMetaResource < ApplicationResource
  attributes :id, :title
  typelize "PostMeta"
  attribute :meta do |post|
    { likes: post.likes, comments: post.comments }
  end
end
```

```typescript
// app/javascript/types/serializers/PostWithMeta.ts

import { PostMeta } from "@/types";

export interface Post {
  id: number;
  title: string;
  meta: PostMeta;
}
```

The `"@/types"` import path is configurable:

```ruby
Typelizer.configure do |config|
  config.types_import_path = "@/types";
end
```

See the [Configuration](#configuration) section for more options.

### Manual Generation

To manually generate TypeScript interfaces use one of the following commands:

```bash
# Generate new interfaces
rails typelizer:generate

# Clean output directory and regenerate all interfaces
rails typelizer:generate:refresh
````

### Automatic Generation in Development

When [Listen](https://github.com/guard/listen) is installed, Typelizer automatically watches for changes and regenerates interfaces in development mode. You can disable this behavior:

```ruby
Typelizer.listen = false
```

### Disabling Typelizer

Sometimes we want to use Typelizer only with manual generation. To disable Typelizer during development, we can set `DISABLE_TYPELIZER` environment variable to `true`. This doesn't affect manual generation.

## Configuration

Typelizer provides several global configuration options:

```ruby
# Directories to search for serializers:
Typelizer.dirs = [Rails.root.join("app", "resources"), Rails.root.join("app", "serializers")]
# Reject specific classes from being typelized:
Typelizer.reject_class = ->(serializer:) { false }
# Logger for debugging:
Typelizer.logger = Logger.new($stdout, level: :info)
# Force enable or disable file watching with Listen:
Typelizer.listen = nil
```

### Configuration Layers

Typelizer uses a hierarchical system to resolve settings. Settings are applied in the following order of precedence, where higher numbers override lower ones:

1.  **Per-Serializer Overrides**: Settings defined using `typelizer_config` directly within a serializer class. This layer has the highest priority.
2.  **Writer-Specific Settings**: Settings defined within a `config.writer(:name) { ... }` block.
3.  **Global Settings**: Application-wide settings defined by direct assignment (e.g., `config.comments = true`) within the `Typelizer.configure` block.
4.  **Library Defaults**: The gem's built-in default values.

### Simple Configuration (Single Output)

For most apps, a single output is enough. All settings in an initializer apply to the `:default` writer and also act as a global baseline.

- Settings like `dirs` are considered **Global** and establish a baseline for all writers.
- Settings like `output_dir` or `comments` configure the implicit **`:default` writer**.

```ruby
# config/initializers/typelizer.rb
Typelizer.configure do |config|
  # This is a GLOBAL SETTING. It applies to ALL writers.
  config.dirs = [Rails.root.join("app/serializers")]

  # This setting configures the :default writer and ALSO acts as a global setting.
  config.output_dir = "app/javascript/types/generated"
  config.comments = true
end
```

### Defining Multiple Writers

The multi-writer system allows for the generation of multiple, distinct TypeScript outputs. Each output is managed by a named writer with an isolated configuration.


#### Writer Inheritance Rules

- By default, a new writer inherits its base settings from the Global Settings.
- To inherit from another existing writer, use the `from:` option.


**A Note on the :default Writer and Inheritance**
- You usually do not need to declare `writer(:default)`. The implicit default writer automatically uses your global settings. 
- Declare `writer(:default)` when you want to apply specific overrides to it that should not be inherited by other new writers. This provides a way to separate your application's global baseline from settings that are truly unique to the default output

#### Example of the distinction:
```ruby
Typelizer.configure do |config|
  # === Global Setting ===
  # `comments: true` applies to :default and will be inherited by :camel_case.
  config.comments = true

  # === Default-Writer-Only Setting ===
  # `prefer_double_quotes: true` applies ONLY to the :default writer.
  # It is NOT a global setting and will NOT be inherited by :camel_case.
  config.writer(:default) do |c|
    c.prefer_double_quotes = true
  end

  # === New Writer Definition ===
  config.writer(:camel_case) do |c|
    c.output_dir = "app/javascript/types/camel_case"
    # This writer inherits `comments: true` from globals.
    # It does NOT inherit `prefer_double_quotes: true` from the :default writer's block.
    # Its `prefer_double_quotes` will be `false` (the library default).
  end
end
```

#### Configuring Writers
You can define writers either inside the configure block or directly on the Typelizer module.

1. **Inside the configure block**

This is the approach for keeping all configuration centralized.

```ruby
# config/initializers/typelizer.rb
Typelizer.configure do |config|
  # ... global settings ...

  config.writer(:camel_case) do |c|
    c.output_dir = "app/javascript/types/camel_case"
    c.properties_transformer = ->(properties) { # ... transform ... }
  end

  config.writer(:admin, from: :camel_case) do |c|
    c.output_dir = "app/javascript/types/admin"
    c.null_strategy = :optional
  end
end
```

2. Top-Level Helper

```ruby
Typelizer.writer(:admin, from: :default) do |c|
  c.output_dir = Rails.root.join("app/javascript/types/admin")
  c.prefer_double_quotes = true
end
```

#### Comprehensive Example
This example configures three distinct outputs, demonstrating all inheritance mechanisms.

```ruby
# config/initializers/typelizer.rb
Typelizer.configure do |config|
  # === 1. Global Settings (Baseline for ALL writers) ===
  config.comments = true
  config.dirs = [Rails.root.join("app/serializers")]

  # === 2. The :default writer (snake_case output) ===
  config.writer(:default) do |c|
    c.output_dir = "app/javascript/types/snake_case"
  end

  # === 3. A new :camel_case writer ===
  # Inherits `comments: true` and `dirs` from the Global Settings.
  config.writer(:camel_case) do |c|
    c.output_dir = "app/javascript/types/camel_case"
    c.properties_transformer = lambda do |properties|
      properties.map { |prop| prop.with_overrides(name: prop.name.to_s.camelize(:lower)) }
    end
  end

  # === 4. An "admin" writer that clones :camel_case ===
  # Use `from:` to explicitly inherit another writer's complete configuration.
  config.writer(:admin, from: :camel_case) do |c|
    c.output_dir = "app/javascript/types/admin"
    # This writer inherits the properties_transformer from :camel_case.
    c.null_strategy = :optional
  end
end
```

### Per-serializer configuration

Use `typelizer_config` within a serializer class to apply overrides with the highest possible priority. 
These settings will supersede any conflicting settings from the active writer, global settings, or library defaults.

```ruby
class PostResource < ApplicationResource
  typelizer_config do |c|
    c.null_strategy = :nullable_and_optional
    c.plugin_configs = { alba: { ts_mapper: { "UUID" => { type: :string } } } }
  end
end
```

### Option reference

```ruby
Typelizer.configure do |config|
  # Name to type mapping for serializer classes
  config.serializer_name_mapper = ->(serializer) { ... }

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
  config.type_mapping = config.type_mapping.merge(jsonb: "Record<string, undefined>", ... )

  # Strategy for handling null values (:nullable, :optional, or :nullable_and_optional)
  config.null_strategy = :nullable

  # Strategy for handling serializer inheritance (:none, :inheritance)
  # :none - lists all attributes of the serializer in the type
  # :inheritance - extends the type from the parent serializer
  config.inheritance_strategy = :none

  # Strategy for handling `has_one` and `belongs_to` associations nullability (:database, :active_record)
  # :database - uses the database column nullability
  # :active_record - uses the `required` / `optional` association options
  config.associations_strategy = :database

  # Directory where TypeScript interfaces will be generated
  config.output_dir = Rails.root.join("app/javascript/types/serializers")

  # Import path for generated types in TypeScript files
  # (e.g., `import { MyType } from "@/types"`)
  config.types_import_path = "@/types"

  # List of type names that should be considered global in TypeScript
  # (i.e. not prefixed with the import path)
  config.types_global = %w[Array Date Record File FileList]

  # Support TypeScript's Verbatim module syntax option (default: false)
  # Will change imports and exports of types from default to support this syntax option
  config.verbatim_module_syntax = false

  # Use double quotes in generated TypeScript interfaces (default: false)
  config.prefer_double_quotes = false

  # Support comments in generated TypeScript interfaces (default: false)
  # Will add comments to the generated interfaces
  config.comments = false
end
```

## Credits

Typelizer is inspired by [types_from_serializers](https://github.com/ElMassimo/types_from_serializers).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
