# Type Mapping

## Database to TypeScript

Typelizer maps database column types to TypeScript types:

| Column Type | TypeScript Type |
|---|---|
| `boolean` | `boolean` |
| `integer` | `number` |
| `float` | `number` |
| `decimal` | `number` |
| `string` | `string` |
| `text` | `string` |
| `citext` | `string` |
| `uuid` | `string` |
| `date` | `string` |
| `datetime` | `string` |
| `time` | `string` |

Unknown column types map to `unknown`.

## Database to OpenAPI

When generating [OpenAPI schemas](/guides/openapi), column types map to OpenAPI types with optional format specifiers:

| Column Type | OpenAPI Type | Format |
|---|---|---|
| `integer` | `integer` | |
| `bigint` | `integer` | `int64` |
| `float` | `number` | `float` |
| `decimal` | `number` | `double` |
| `boolean` | `boolean` | |
| `string` | `string` | |
| `text` | `string` | |
| `citext` | `string` | |
| `uuid` | `string` | `uuid` |
| `date` | `string` | `date` |
| `datetime` | `string` | `date-time` |
| `time` | `string` | `time` |
| `json` | `object` | |
| `jsonb` | `object` | |
| `binary` | `string` | `binary` |
| `inet` | `string` | |
| `cidr` | `string` | |

## Custom Type Mapping

Override the default mapping in your configuration:

```ruby
Typelizer.configure do |config|
  config.type_mapping = config.type_mapping.merge(
    jsonb: "Record<string, unknown>",
    inet: "string"
  )
end
```

This affects TypeScript generation. OpenAPI mappings use a separate, fixed table.
