class Poro
  def foo
    "This is foo method"
  end

  def as_json
    {foo: foo}
  end
end
