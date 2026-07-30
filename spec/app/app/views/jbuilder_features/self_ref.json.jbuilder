# Self-referencing types via typelize: string.
# Typelizer filters self-imports so the reference compiles.
# Type name matches the generated interface (derived from filename + path).

json.id @node.id
json.name @node.name, typelize: "string"
json.parent @node.parent, typelize: "JbuilderFeaturesSelfRef | null"
