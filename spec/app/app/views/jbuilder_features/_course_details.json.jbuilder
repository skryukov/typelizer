# Additive "trait" partial (the thicket `course` + `course_details`
# composition pattern) — composed by composed_partials.json.jbuilder.

json.description course.description, typelize: "string"
json.lessons_count course.lessons_count, typelize: "number"
