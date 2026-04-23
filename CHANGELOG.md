# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog],
and this project adheres to [Semantic Versioning].

## [Unreleased]

### Added

- **Inline object types**: pass a positional hash to `typelize` to describe an inline TypeScript object type. Nested hashes nest, and options like `multi:`/`nullable:` compose. Useful for JSON columns and ad-hoc computed shapes that don't warrant a separate resource. ([@skryukov])

  ```ruby
  typelize({id: :number, label?: :string})
  attribute :category
  # → category: { id: number; label?: string }
  ```

- **`?` suffix on attribute keys** as a shorthand for `optional: true`, mirroring TypeScript's own syntax. Works both in keyed `typelize` calls and inside inline shape hashes. ([@skryukov])

  ```ruby
  typelize name?: :string
  # → name?: string
  ```

### Changed

- [BREAKING] Dropped `DISABLE_TYPELIZER` environment variable support (deprecated since 0.12.0). Use `TYPELIZER=false` instead. ([@skryukov])
- [BREAKING] Bumped `railties` requirement to `>= 6.1.0` to use the `server` Railtie block for auto-generation. ([@skryukov])

### Fixed

- `typelize` declarations silently dropped during rake tasks, producing `unknown` for every field. ([#114](https://github.com/skryukov/typelizer/issues/114)) ([@skryukov])
- `properties_transformer` now applied to nested attribute sub-properties, meta nested blocks, and Alba trait properties. Previously only top-level keys were transformed, producing inconsistent output. ([#89](https://github.com/skryukov/typelizer/issues/89)) ([@skryukov])
- `typelize "Name[]"` paired with `with_traits:` no longer emits a phantom trait intersection with a missing import. Explicit `typelize` overrides are now trusted as-is — the generated type is exactly what you wrote. ([#113](https://github.com/skryukov/typelizer/issues/113)) ([@skryukov])

## [0.12.0] - 2026-03-29

### Added

- **Route generation**: Generate typed TypeScript (or JavaScript) route helpers from Rails routes. Enable with `config.routes.enabled = true`. ([@skryukov])

## [0.11.0] - 2026-03-26

### Added

- Per-serializer `output_dir` override via `typelizer_config`. Interfaces are written to their configured directory while the shared `index.ts` barrel generates correct relative import paths. ([@skryukov])

- `filename_mapper` configuration to decouple generated file paths from TypeScript type names. Useful for mirroring Ruby module namespaces as nested directories. ([@skryukov], [@rdavid1099])

  ```ruby
  Typelizer.configure do |config|
    config.filename_mapper = ->(name) { name.gsub("::", "/") }
  end
  # Alba::UserSerializer → types/Alba/User.ts (type name stays AlbaUser)
  ```

### Fixed

- Walk over inline association properties to determine imports. ([@skryukov])
- Fix `config.type_mapping` override not applied to OpenAPI schema generation. ([@skryukov])
- Fix key transformation for Alba traits. ([@skryukov])

## [0.10.0] - 2026-03-02

### Changed

- **Breaking:** Arrays of strings in `typelize` now produce string literal unions (`'active' | 'inactive'`) instead of type reference unions. Use symbols for type references: `typelize status: [:string, :number]`. ([@skryukov])

## [0.9.3] - 2026-02-27

### Fixed

- Fix keyless `typelize` DSL without name. ([@skryukov])
- Support arrays for keyless `typelize` calls. ([@skryukov])

## [0.9.2] - 2026-02-26

### Fixed

- Fix string literal unions in OpenAPI and bracket-aware union type splitting. ([@skryukov])

## [0.9.1] - 2026-02-26

### Fixed

- Fix crash when using tuple types in serializers. ([@skryukov])
- Handle abstract ActiveRecord classes gracefully during type inference. ([@skryukov])

## [0.9.0] - 2026-02-26

### Added

- Alba: nested attributes (`nested` / `nested_attribute`) now generate inline nested TypeScript types with full type inference support, including within traits. ([@pgiblock])

- OpenAPI: support for traits in schema generation. ([@skryukov])

- Union types in `typelize` for polymorphic associations. Supports serializer class references, pipe-delimited strings, and plain TypeScript type names. ([@skryukov])

  ```ruby
  typelize commentable: [UserResource, CommentResource]
  typelize approver: "AuthorResource | null"
  typelize content: "TextBlock | ImageBlock"
  ```

### Fixed

- OpenAPI: TypeScript-only types (`any`, `unknown`, `never`) and generic types (`Record<string, unknown>`, `Partial<T>`, etc.) no longer produce invalid `$ref` entries. They are mapped to `{type: :object}` instead. ([@skryukov])
- OpenAPI: fix nullable arrays producing incorrect schemas. ([@skryukov])
- Fix Typelizer not loading gracefully when required gems are missing at boot time. ([@skryukov])

### Changed

- **Internal:** Union types are now stored as arrays of symbols instead of pipe-delimited strings. This fixes import resolution for serializer classes inside unions and eliminates redundant string splitting/joining across the DSL, Interface, and OpenAPI layers. ([@skryukov])

## [0.8.0] - 2026-02-19

### Added

- OpenAPI schema generation from serializers, supporting both OpenAPI 3.0 and 3.1. ([@skryukov])

  ```ruby
  # Get all schemas as a hash
  Typelizer.openapi_schemas
  # => { "Post" => { type: :object, properties: { ... }, required: [...] }, ... }

  # OpenAPI 3.1 output
  Typelizer.openapi_schemas(openapi_version: "3.1")
  ```

  Column types are automatically mapped to OpenAPI types with proper formats (`integer`, `int64`, `uuid`, `date-time`, etc.).
  Enums, nullable fields, arrays, deprecated flags, and `$ref` associations are all handled automatically.

- Type inference for delegated attributes (`delegate :name, to: :user`). Typelizer now tracks `delegate` calls on ActiveRecord models and resolves types from the target association's model, including support for `prefix` and `allow_nil` options. ([@skryukov])

- Reference other serializers in `typelize` method by passing the class directly. ([@skryukov])

- Per-writer `reject_class` configuration. Each writer can now define its own `reject_class` filter, enabling scoped output (e.g., only V1 serializers for a V1 writer). ([@skryukov])

### Fixed

- `typelize` DSL metadata (optional, comment, type overrides) now correctly applies to renamed attributes (e.g., via `key:`, `alias_name`, `value_from`). Previously, metadata was looked up only by `column_name`, missing attributes where the output name differs. ([@skryukov])

## [0.7.0] - 2026-01-15

### Changed

- Use DSL hooks instead of TracePoint for `typelize` method. ([@skryukov])

### Fixed

- Apply sorting and quote style configs consistently to all generated files. ([@jonmarkgo], [@skryukov])
- Fix fingerprint calculations to include all config options. ([@skryukov])

## [0.6.0] - 2026-01-14

### Added

- New `imports_sort_order` configuration option for consistent import ordering in generated TypeScript interfaces. ([@jonmarkgo])

  ```ruby
  Typelizer.configure do |config|
    # Sort imports alphabetically
    config.imports_sort_order = :alphabetical
  end
  ```

  Available options:
  - `:none` (default) - preserve original order
  - `:alphabetical` - sort imports A-Z (case-insensitive)
  - `Proc` - custom sorting logic

### Changed

- Rails enum attributes now generate named types (e.g., `PostCategory`) in a separate `Enums.ts` file instead of inline unions. ([@skryukov])

### Fixed

- Fix `index.ts` not being regenerated when traits are added or removed. ([@skryukov])

## [0.5.6] - 2026-01-12

### Added

- Type inference for serialized fields. `serialize :skills, type: Array` generates `Array<unknown>`, `serialize :settings, type: Hash` generates `Record<string, unknown>`. ([@skryukov])

### Fixed

- Alba: respect `key:` option for associations defined in traits. ([@skryukov])

## [0.5.5] - 2025-12-24

### Added

- New `properties_sort_order` configuration option for consistent property ordering in generated TypeScript interfaces. ([@skryukov])

  ```ruby
  Typelizer.configure do |config|
    # Sort properties alphabetically with 'id' first
    config.properties_sort_order = :id_first_alphabetical
  end
  ```

  Available options:
  - `:none` (default) - preserve serializer definition order
  - `:alphabetical` - sort properties A-Z (case-insensitive)
  - `:id_first_alphabetical` - place `id` first, then sort remaining A-Z
  - `Proc` - custom sorting logic

  ```ruby
  # Custom sorting example
  config.properties_sort_order = ->(props) {
    priority = %w[id uuid type]
    props.sort_by { |p| [priority.index(p.name) || 999, p.name] }
  }
  ```

### Fixed

- Fix self-import issue when using custom `typelize` types for self-referential associations in namespaced serializers. ([@skryukov])

## [0.5.4] - 2025-12-08

### Added

- Type shortcuts for `typelize` method. ([@skryukov])

  Use `?` suffix for optional and `[]` suffix for arrays:

  ```ruby
  typelize "string?"      # optional: true
  typelize "number[]"     # multi: true
  typelize "string?[]"    # optional: true, multi: true

  # With hash syntax
  typelize name: "string?", tags: "string[]"

  # Combined with explicit options
  typelize status: ["string?", nullable: true]
  ```

  Generates:

  ```typescript
  name?: string;
  tags: Array<string>;
  roles?: Array<string>;
  status?: string | null;
  ```

- Alba: support for traits. ([@skryukov])

  Typelizer now generates TypeScript types for Alba traits and supports `with_traits` in associations:

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

  Generates:

  ```typescript
  type User = {
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
  ```

  When using `with_traits` in associations, Typelizer generates intersection types:

  ```ruby
  has_one :author, resource: UserResource, with_traits: [:detailed]
  # Generates: author: User & UserDetailedTrait
  ```

## [0.5.3] - 2025-11-25

## Fixed

- Ignore trace points if they return errors on class checks to fix Rails 8.1 compatibility. ([@skryukov])

## [0.5.2] - 2025-10-06

## Added

- Infer type for `<relation>_ids`. ([@skryukov])

## [0.5.1] - 2025-09-11

### Fixed

- Fix type inference when using virtual associations. ([@hkamberovic])

## [0.5.0] - 2025-09-01

### Added

- Support for multiple output writers: emit several variants (e.g., snake_case and camelCase) in parallel. ([@prog-supdex])
- Support for Rails' Attributes API. ([@skryukov])

## [0.4.2] - 2025-06-23

### Added

- Map `uuid` type to `string` by default. ([@ventsislaf])

### Fixed

- Alba: fix `has_many` with a custom `key` generates single value type instead of array. ([@skryukov])

## [0.4.1] - 2025-06-10

### Added

- Add option to use double quotes in generated TypeScript interfaces through `prefer_double_quotes` config option ([@kristinemcbride])

### Fixed

- Fix types not being generated on the fly since [0.2.0]. ([@skryukov])
- Improve memory consumption (~100x less memory) & speed of types generation (~5x faster). ([@skryukov])
- Fix nullable detection for `belongs_to` associations with `:active_record` strategy. ([@NOX73])
- Alba: fix unknown type for conditional attribute with `transform_keys`. ([@nkriege])

## [0.4.0] - 2025-05-03

### Added 

- Support for `panko_serializer` gem ([@PedroAugustoRamalhoDuarte], [@skryukov])
- Mark `has_one` and `belongs_to` association as nullable. ([@skryukov])

  By default, `has_one` associations are marked as nullable in TypeScript interfaces.
  `belongs_to` associations are marked as nullable if the database column is nullable.
  Use the new `config.associations_strategy = :active_record` configuration option to mark associations as nullable based on the `required`/`optional` options.  
  You can also use the type hint `typelize latest_post: {nullable: false}` in the serializer to override the defaults.

- Support inherited typelization. ([@skryukov])

  Set `config.inheritance_strategy = :inheritance` to make Typelizer respect the inheritance hierarchy of serializers:

  ```ruby
    class AdminSerializer < UserSerializer
      attributes :admin_level
    end
  ```
  
  ```typescript
    // app/javascript/types/serializers/Admin.ts
    import { User } from "@/types";
    
    export type Admin = User & {
      admin_level: number;
    }
  ```

### Fixed

- Alba: always use strings for keys in properties. ([@skryukov])
  This change will fire update of all hashes for Alba serializers, but it's necessary to support inheritance strategy.

## [0.3.0] - 2025-02-28

### Added

- Support transform keys. ([@patvice], [@skryukov])

  Typelizer now respects `transform_keys`/`key_transform` configurations for all plugins.

- Support typing method def in Alba. ([@patvice])

  The `typelize` helper now can be used before a method definition:

  ```ruby
  class UserResource < ApplicationResource
    attributes :id, :name, :email, :chars_in_name

    typelize :number
    def chars_in_name(obj)
      obj.name.chars.count
    end
  end
  ```

- Support for deprecated attributes. ([@Envek])

  They will be marked as deprecated using JSDoc [`@deprecated` tag](https://jsdoc.app/tags-deprecated) in TypeScript interface comments.

  In ActiveModel::Serializer attributes `deprecated` option is recognized.

  For other serializers, you can use `deprecated` option of `typelize` method.

### Fixed

- Ignore `nil` values on fingerprint calculation. ([@Envek])

## [0.2.0] - 2024-11-26

## Added

- Add support for enum attributes declared using `ActiveRecord::Enum` or explicitly in serializers ([@Envek])
- Add support for comments in generated TypeScript interfaces ([@Envek])
- Add TypeScript verbatim module syntax support through `verbatim_module_syntax` config option ([@patvice])
- Add `typelizer:generate:refresh` command to clean output directory and regenerate all interfaces ([@patvice])
- Allow disabling Typelizer in Rails development with `DISABLE_TYPELIZER` environment variable to `true` ([@okuramasafumi])
- Allow to get interfaces without generating TypeScript files ([@Envek])

## Fixed

- Do not override `Typelizer.dirs` in the railtie initializer ([@patvice])
- Do not raise on empty nested serializers ([@skryukov])
- Attribute options merging in inherited serializers ([@Envek])
- Allow recursive type definition ([@okuramasafumi])

## [0.1.5] - 2024-10-07

## Fixed

- Fix the duplicated import with multiple same association ([@okuramasafumi])

## [0.1.4] - 2024-10-04

## Added

- PORO model plugin ([@okuramasafumi])
- Auto model plugin ([@skryukov])

## [0.1.3] - 2024-09-27

## Added

- Support inline associations ([@okuramasafumi], [@skryukov])

  Example of Alba serializer with inline associations (note the `helper Typelizer::DSL`, see [Alba's docs](https://github.com/okuramasafumi/alba?tab=readme-ov-file#helper) for more details):  

  ```ruby
  class FooSerializer
    include Alba::Resource
    helper Typelizer::DSL

    many :bars do
      typelize_from Bar

      attributes :id, :name
    end
  end
  ```

## [0.1.2] - 2024-09-05

### Fixed

- Prevent Alba's `meta nil` raising an error ([@okuramasafumi])

## [0.1.1] - 2024-08-26

### Fixed

- Failing method inspection ([@skryukov], [@davidrunger])

## [0.1.0] - 2024-08-02

- Initial release ([@skryukov])

[@davidrunger]: https://github.com/davidrunger
[@Envek]: https://github.com/Envek
[@hkamberovic]: https://github.com/hkamberovic
[@jonmarkgo]: https://github.com/jonmarkgo
[@kristinemcbride]: https://github.com/kristinemcbride
[@nkriege]: https://github.com/nkriege
[@NOX73]: https://github.com/NOX73
[@okuramasafumi]: https://github.com/okuramasafumi
[@patvice]: https://github.com/patvice
[@pgiblock]: https://github.com/pgiblock
[@PedroAugustoRamalhoDuarte]: https://github.com/PedroAugustoRamalhoDuarte
[@prog-supdex]: https://github.com/prog-supdex
[@rdavid1099]: https://github.com/rdavid1099
[@skryukov]: https://github.com/skryukov
[@ventsislaf]: https://github.com/ventsislaf

[Unreleased]: https://github.com/skryukov/typelizer/compare/v0.12.0...HEAD
[0.12.0]: https://github.com/skryukov/typelizer/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/skryukov/typelizer/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/skryukov/typelizer/compare/v0.9.3...v0.10.0
[0.9.3]: https://github.com/skryukov/typelizer/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/skryukov/typelizer/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/skryukov/typelizer/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/skryukov/typelizer/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/skryukov/typelizer/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/skryukov/typelizer/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/skryukov/typelizer/compare/v0.5.6...v0.6.0
[0.5.6]: https://github.com/skryukov/typelizer/compare/v0.5.5...v0.5.6
[0.5.5]: https://github.com/skryukov/typelizer/compare/v0.5.4...v0.5.5
[0.5.4]: https://github.com/skryukov/typelizer/compare/v0.5.3...v0.5.4
[0.5.3]: https://github.com/skryukov/typelizer/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/skryukov/typelizer/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/skryukov/typelizer/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/skryukov/typelizer/compare/v0.4.2...v0.5.0
[0.4.2]: https://github.com/skryukov/typelizer/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/skryukov/typelizer/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/skryukov/typelizer/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/skryukov/typelizer/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/skryukov/typelizer/compare/v0.1.5...v0.2.0
[0.1.5]: https://github.com/skryukov/typelizer/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/skryukov/typelizer/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/skryukov/typelizer/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/skryukov/typelizer/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/skryukov/typelizer/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/skryukov/typelizer/commits/v0.1.0

[Keep a Changelog]: https://keepachangelog.com/en/1.0.0/
[Semantic Versioning]: https://semver.org/spec/v2.0.0.html
