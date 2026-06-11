# Custom TypeScript-in-a-string overrides: inline objects, Record<>,
# tuples, unions, nullable unions.

json.provider "x", typelize: "'cloudpayments' | 'tiptoppay'"
json.metadata typelize: "{ name: string; visitorId: string | null }"
json.lookup typelize: "Record<string, number | null>"
json.pair typelize: "[string | null, number]"
json.result typelize: "{ ok: boolean } | { error: string }"
json.nullable_config typelize: "{ retries: number | null } | null"
