# unless/else — both branches contribute. The else clause is the
# condition-true branch (unless-semantics); a prop emitted in both branches
# stays required, a prop in only one branch becomes optional.

unless @minimal # standard:disable Style/UnlessElse -- the construct under test
  json.full_name "Jane Doe"
  json.theme "dark"
else
  json.compact true
  json.theme "light"
end
