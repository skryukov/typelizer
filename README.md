# Typelizer

[![Gem Version](https://badge.fury.io/rb/typelizer.svg)](https://rubygems.org/gems/typelizer)

Typelizer generates TypeScript types, route helpers, and OpenAPI schemas from your Ruby on Rails application. It keeps your backend and frontend in sync without hand-maintaining types.

## Features

- Automatic TypeScript interface generation from serializers
- Type-safe route helpers from Rails routes
- Supports Alba, ActiveModel::Serializer, Oj::Serializer, Panko::Serializer
- OpenAPI 3.0/3.1 schema generation
- Multiple output writers with layered configuration
- File watching with automatic regeneration in development

## Quick Start

Add to your Gemfile:

```ruby
gem "typelizer"
```

Include the DSL in your serializers:

```ruby
class ApplicationResource
  include Alba::Resource
  include Typelizer::DSL
end

class PostResource < ApplicationResource
  attributes :id, :title, :body
end
```

Generate TypeScript types:

```bash
rails typelizer:generate
```

## Documentation

**Full documentation: https://typelizer.dev**

- [Getting Started](https://typelizer.dev/getting-started)
- [Manual Typing](https://typelizer.dev/guides/manual-typing)
- [Route Helpers](https://typelizer.dev/guides/routes)
- [Configuration](https://typelizer.dev/reference/configuration)
- [Type Mapping](https://typelizer.dev/reference/type-mapping)

## Development

You need PostgreSQL running locally. Then:

```bash
bundle install
cd spec/app && RAILS_ENV=test bundle exec rails db:create db:migrate && cd ../..
bundle exec rspec
```

The test suite uses a dummy Rails app in `spec/app/` with models, migrations, and serializers for all four supported frameworks (Alba, AMS, OjSerializers, Panko). Linting is done with StandardRB:

```bash
bundle exec standardrb
```

`bundle exec rake` runs both the tests and the linter.

## Credits

Typelizer is inspired by [types_from_serializers](https://github.com/ElMassimo/types_from_serializers), [js-routes](https://github.com/railsware/js-routes), and [Wayfinder](https://github.com/nicholasvansanten/wayfinder).

<a href="https://evilmartians.com/?utm_source=typelizer&utm_campaign=project_page">
<img src="https://evilmartians.com/badges/sponsored-by-evil-martians.svg" alt="Built by Evil Martians" width="236" height="54">
</a>

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
