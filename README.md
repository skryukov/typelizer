# Typelizer

[![Gem Version](https://badge.fury.io/rb/typelizer.svg)](https://rubygems.org/gems/typelizer)

Typelizer is a Ruby gem that automatically generates TypeScript interfaces from your Ruby serializers, bridging the gap between your Ruby backend and TypeScript frontend. It supports multiple serializer libraries and provides a flexible configuration system, making it easier to maintain type consistency across your full-stack application.

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
  - [Basic Setup](#basic-setup)
  - [Manual Typing](#manual-typing)
  - [TypeScript Integration](#typescript-integration)
  - [Manual Generation](#manual-generation)
  - [Automatic Generation in Development](#automatic-generation-in-development)
  - [Disabling Typelizer](#disabling-typelizer)
- [Configuration](#configuration)
  - [Global Configuration](#global-configuration)
  - [Config Options](#config-options)
  - [Per-Serializer Configuration](#per-serializer-configuration)
- [Credits](#credits)
- [License](#license)

<a href="https://evilmartians.com/?utm_source=typelizer&utm_campaign=project_page">
<img src="https://evilmartians.com/badges/sponsored-by-evil-martians.svg" alt="Built by Evil Martians" width="236" height="54">
</a>

## Features

- Automatic TypeScript interface generation
- Support for multiple serializer libraries (`Alba`, `ActiveModel::Serializer`, `Oj::Serializer`, `Panko::Serializer`)
- File watching and automatic regeneration in development

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

You can also specify more complex type definitions using a lower-level API:

```ruby
typelize attribute_name: ["string", "Date", optional: true, nullable: true, multi: true, enum: %w[foo bar], comment: "Attribute description", deprecated: "Use `another_attribute` instead"]
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

### Global Configuration

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

### Config Options

`Typelizer::Config` offers fine-grained control over the gem's behavior. Here's a list of available options:

```ruby
Typelizer.configure do |config|
  # Determines how serializer names are mapped to TypeScript interface names
  config.serializer_name_mapper = ->(serializer) { ... }

  # Maps serializers to their corresponding model classes
  config.serializer_model_mapper = ->(serializer) { ... }

  # Custom transformation for generated properties
  config.properties_transformer = ->(properties) { ... }

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

  # Directory where TypeScript interfaces will be generated
  config.output_dir = Rails.root.join("app/javascript/types/serializers")

  # Import path for generated types in TypeScript files
  # (e.g., `import { MyType } from "@/types"`)
  config.types_import_path = "@/types"

  # List of type names that should be considered global in TypeScript
  # (i.e. not prefixed with the import path)
  config.types_global << %w[Array Date Record File FileList]

  # Support TypeScript's Verbatim module syntax option (default: false)
  # Will change imports and exports of types from default to support this syntax option
  config.verbatim_module_syntax = false

  # Support comments in generated TypeScript interfaces (default: false)
  # Will add comments to the generated interfaces
  config.comments = false
end
```

### Per-Serializer Configuration

You can also configure Typelizer on a per-serializer basis:

```ruby
class PostResource < ApplicationResource
  typelizer_config do |config|
    config.type_mapping = config.type_mapping.merge(jsonb: "Record<string, undefined>", ... )
    config.null_strategy = :nullable
    # ...
  end
end
```

## Credits

Typelizer is inspired by [types_from_serializers](https://github.com/ElMassimo/types_from_serializers).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
