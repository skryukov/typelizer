person = {id: 5, name: "Ann"}

json.extract! person, :id, :name, typelize: "string"
json.call person, :id, typelize: "number"
json.items do
  json.array! [{id: 1}, {id: 2}], :id, typelize: "number"
end
