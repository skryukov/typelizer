Typelizer.configure do |c|
  c.dirs = [
    Rails.root.join("app", "serializers")
  ]

  c.types_global = %w[Array Date Record]

  c.comments = true
end
