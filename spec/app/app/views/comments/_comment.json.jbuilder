# Recursive partial: `_comment.json.jbuilder` references itself through
# `partial: "comments/comment"`. Typelizer's WriterContext memoizes the
# Interface per class, so the self-reference produces a stable type.

json.id comment.id, typelize: "number"
json.body comment.body, typelize: "string"
json.replies comment.replies, partial: "comments/comment", as: :comment
