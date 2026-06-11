# Kwargs-only collection partial — `json.partial! partial: "x",
# collection: @xs` renders an array at the template root, so the generated
# type is Array<element shape>.

json.partial! partial: "posts/post", collection: @posts, as: :post
