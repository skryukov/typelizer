typelize_as "AnnotatedRender"
typelize_from User

json.id 1
json.title "Hello", typelize: "string"
json.published true, typelize: "boolean"
