# if/elsif/else — a prop emitted in every branch of a fully-covered chain
# stays required; a prop missing from any branch becomes optional.

if @active
  json.status "active"
  json.reason "still active"
elsif @blocked
  json.status "blocked"
else
  json.status "idle"
end
