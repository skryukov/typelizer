# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog],
and this project adheres to [Semantic Versioning].

## [Unreleased]

## [0.2.0] - 2024-11-26

## Added

- Add support for enum attributes declared using `ActiveRecord::Enum` or explicitly in serializers ([@envek])
- Add support for comments in generated TypeScript interfaces ([@envek])
- Add TypeScript verbatim module syntax support through `verbatim_module_syntax` config option ([@patvice])
- Add `typelizer:generate:refresh` command to clean output directory and regenerate all interfaces ([@patvice])
- Allow disabling Typelizer in Rails development with `DISABLE_TYPELIZER` environment variable to `true` ([@okuramasafumi])

## Fixes

- Do not override `Typelizer.dirs` in the railtie initializer ([@patvice])
- Do not raise on empty nested serializers ([@skryukov])
- Attribute options merging in inherited serializers ([@envek])
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
[@envek]: https://github.com/envek
[@okuramasafumi]: https://github.com/okuramasafumi
[@patvice]: https://github.com/patvice
[@skryukov]: https://github.com/skryukov

[Unreleased]: https://github.com/skryukov/typelizer/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/skryukov/typelizer/compare/v0.1.5...v0.2.0
[0.1.5]: https://github.com/skryukov/typelizer/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/skryukov/typelizer/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/skryukov/typelizer/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/skryukov/typelizer/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/skryukov/typelizer/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/skryukov/typelizer/commits/v0.1.0

[Keep a Changelog]: https://keepachangelog.com/en/1.0.0/
[Semantic Versioning]: https://semver.org/spec/v2.0.0.html
