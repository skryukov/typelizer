# typelize: kwarg accepts Typelizer's type shortcuts.

json.name "x", typelize: "string?"
json.tags ["a"], typelize: "string[]"
json.scores [1], typelize: "number?[]"
json.status "pending", typelize: "'pending' | 'active' | 'closed'"
