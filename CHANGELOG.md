# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog],
and this project adheres to [Semantic Versioning].

## [Unreleased]

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
[@kristinemcbride]: https://github.com/kristinemcbride
[@nkriege]: https://github.com/nkriege
[@NOX73]: https://github.com/NOX73
[@okuramasafumi]: https://github.com/okuramasafumi
[@patvice]: https://github.com/patvice
[@PedroAugustoRamalhoDuarte]: https://github.com/PedroAugustoRamalhoDuarte
[@skryukov]: https://github.com/skryukov
[@prog-supdex]: https://github.com/prog-supdex
[@ventsislaf]: https://github.com/ventsislaf

[Unreleased]: https://github.com/skryukov/typelizer/compare/v0.5.5...HEAD
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
