# Custom TypeScript-in-a-string overrides: inline objects, Record<>,
# tuples, unions, nullable unions. Annotations must accompany a value (or
# block): a value-less `typelize:` renders its hash as the property's literal
# value at runtime, so the walker warns instead of honoring it.

json.provider "x", typelize: "'cloudpayments' | 'tiptoppay'"
json.metadata @metadata, typelize: "{ name: string; visitorId: string | null }"
json.lookup @lookup, typelize: "Record<string, number | null>"
json.pair @pair, typelize: "[string | null, number]"
json.result @result, typelize: "{ ok: boolean } | { error: string }"
json.nullable_config @config, typelize: "{ retries: number | null } | null"
