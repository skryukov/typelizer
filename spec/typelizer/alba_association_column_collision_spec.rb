# frozen_string_literal: true

RSpec.describe "Alba association named after a model column" do
  let(:context) { Typelizer::WriterContext.new }

  def build_resource(&block)
    klass = Class.new do
      include ::Alba::Resource

      helper Typelizer::DSL
    end
    klass.class_eval(&block)
    klass
  end

  def property(resource, name)
    context.interface_for(resource).properties.find { |p| p.name.to_s == name.to_s }
  end

  let(:full_name_resource) do
    stub_const("AlbaFullNameResource", build_resource do
      attributes :first, :last
    end)
  end

  it "keeps the association type for a `one` over a string column" do
    target = full_name_resource
    resource = stub_const("AlbaUserWithFullName", build_resource do
      typelize_from ::User
      one :name, resource: target
    end)

    prop = property(resource, :name)
    expect(prop.type).to eq(context.interface_for(target))
    expect(prop.render).to eq("name: AlbaFullName")
  end

  it "keeps the association type for a `one` over an enum column" do
    target = full_name_resource
    resource = stub_const("AlbaUserWithRoleObject", build_resource do
      typelize_from ::User
      one :role, resource: target
    end)

    expect(property(resource, :role).render).to eq("role: AlbaFullName")
  end

  it "keeps an explicit typelize over an enum column" do
    target = full_name_resource
    resource = stub_const("AlbaUserWithTypelizedRole", build_resource do
      typelize_from ::User
      typelize role: target
      attributes :role
    end)

    expect(property(resource, :role).render).to eq("role: AlbaFullName")
  end

  it "keeps the nested shape for a `nested` over a string column" do
    resource = stub_const("AlbaUserWithNestedName", build_resource do
      typelize_from ::User
      nested :name do
        attributes :first
        typelize first: :string
      end
    end)

    expect(property(resource, :name).render).to eq("name: {\n  first: string;\n}")
  end

  it "still infers nullability from a real association" do
    target = full_name_resource
    resource = stub_const("AlbaUserWithInvitor", build_resource do
      typelize_from ::User
      one :invitor, resource: target
    end)

    expect(property(resource, :invitor).render).to eq("invitor: AlbaFullName | null")
  end
end
