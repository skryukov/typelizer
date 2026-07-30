# Conditional nested inside a block — branch merging applies per nesting
# level, inside the inline shape.

json.profile do
  json.id 1
  if @admin
    json.role "admin"
  else
    json.role "user"
    json.limited true
  end
end
