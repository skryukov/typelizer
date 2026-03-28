# OpenAPI Schemas

Typelizer can generate [OpenAPI](https://swagger.io/specification/) component schemas from your serializers. This is useful for documenting your API or integrating with tools like [rswag](https://github.com/rswag/rswag).

## Generate All Schemas

Get all schemas as a hash:

```ruby
Typelizer.openapi_schemas
# => {
#   "Post" => {
#     type: :object,
#     properties: {
#       id: { type: :integer },
#       title: { type: :string },
#       published_at: { type: :string, format: :"date-time", nullable: true }
#     },
#     required: [:id, :title]
#   },
#   "Author" => { ... }
# }
```

## OpenAPI 3.1 Support

By default, schemas are generated for OpenAPI 3.0. Pass `openapi_version: "3.1"` for OpenAPI 3.1 output (e.g., `type: [:string, :null]` instead of `nullable: true`):

```ruby
Typelizer.openapi_schemas(openapi_version: "3.1")
```

## Single Interface Schema

Generate a schema for a single interface:

```ruby
interfaces = Typelizer.interfaces
post_interface = interfaces.find { |i| i.name == "Post" }
Typelizer::OpenAPI.schema_for(post_interface)
Typelizer::OpenAPI.schema_for(post_interface, openapi_version: "3.1")
```

## Writer-Specific Schemas

Pass a `writer_name` to generate schemas based on a specific writer's configuration (e.g., a camelCase writer):

```ruby
Typelizer.openapi_schemas(writer_name: :camel_case)
```

## Type Mapping

Column types are mapped to OpenAPI types automatically. Enums, nullable fields, arrays, deprecated flags, and `$ref` associations are all handled.

See the [Type Mapping Reference](/reference/type-mapping) for the full mapping table.
