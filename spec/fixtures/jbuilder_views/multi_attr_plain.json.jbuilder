person = {id: 5, name: "Ann"}

json.extract! person, :id, :name
json.call person, :id
json.items do
  json.array! [{id: 1}, {id: 2}], :id
end
