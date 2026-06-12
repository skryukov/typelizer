# Named intersections for composed partials (the thicket round-3 pattern):
# a block whose body is exclusively `json.partial!` calls emits the partials
# as named imported interfaces joined into an intersection; a mixed block
# trails the named members with an inline shape for its own props.

json.course do
  json.partial! "jbuilder_features/course", course: @course
  json.partial! "jbuilder_features/course_details", course: @course
end

json.course_with_progress do
  json.partial! "jbuilder_features/course", course: @course
  json.progress 0.5, typelize: "number"
end
