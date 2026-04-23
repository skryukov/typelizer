# frozen_string_literal: true

RSpec.describe Typelizer::Property do
  describe "#to_s" do
    describe "union type sorting" do
      it "does not sort unions when sort_order is :none" do
        prop = described_class.new(name: "field", type: [:TypeZ, :TypeA, :TypeB])
        expect(prop.render(sort_order: :none)).to eq("field: TypeZ | TypeA | TypeB")
      end

      it "sorts unions alphabetically when sort_order is :alphabetical" do
        prop = described_class.new(name: "field", type: [:TypeZ, :TypeA, :TypeB])
        expect(prop.render(sort_order: :alphabetical)).to eq("field: TypeA | TypeB | TypeZ")
      end

      it "sorts unions in Array<> types" do
        prop = described_class.new(name: "items", type: [:TypeZ, :TypeA, :TypeB], multi: true)
        result = prop.render(sort_order: :alphabetical)
        expect(result).to eq("items: Array<TypeA | TypeB | TypeZ>")
      end

      it "keeps null at the end when nullable" do
        prop = described_class.new(name: "field", type: [:TypeZ, :TypeA], nullable: true)
        result = prop.render(sort_order: :alphabetical)
        expect(result).to eq("field: TypeA | TypeZ | null")
      end

      it "handles enum values with sorting" do
        prop = described_class.new(name: "status", enum: %w[zebra apple banana])
        result = prop.render(sort_order: :alphabetical)
        expect(result).to eq("status: 'apple' | 'banana' | 'zebra'")
      end

      it "does not sort enum values when sort_order is :none" do
        prop = described_class.new(name: "status", enum: %w[zebra apple banana])
        result = prop.render(sort_order: :none)
        expect(result).to eq("status: 'zebra' | 'apple' | 'banana'")
      end

      it "uses double quotes when prefer_double_quotes is true" do
        prop = described_class.new(name: "status", enum: %w[zebra apple banana])
        result = prop.render(sort_order: :alphabetical, prefer_double_quotes: true)
        expect(result).to eq('status: "apple" | "banana" | "zebra"')
      end

      it "defaults to no sorting when sort_order not specified" do
        prop = described_class.new(name: "field", type: [:TypeZ, :TypeA, :TypeB])
        expect(prop.to_s).to eq("field: TypeZ | TypeA | TypeB")
      end
    end

    describe "optional properties" do
      it "adds ? for optional properties" do
        prop = described_class.new(name: "field", type: "string", optional: true)
        expect(prop.to_s).to eq("field?: string")
      end
    end

    describe "nullable properties" do
      it "adds | null for nullable properties" do
        prop = described_class.new(name: "field", type: "string", nullable: true)
        expect(prop.to_s).to eq("field: string | null")
      end
    end

    describe "multi (array) properties" do
      it "wraps type in Array<> for multi properties" do
        prop = described_class.new(name: "items", type: "string", multi: true)
        expect(prop.to_s).to eq("items: Array<string>")
      end
    end

    describe "combined modifiers" do
      it "handles optional, nullable, and multi together" do
        prop = described_class.new(name: "items", type: "string", optional: true, nullable: true, multi: true)
        expect(prop.to_s).to eq("items?: Array<string> | null")
      end

      it "handles union type with optional, nullable, and multi" do
        prop = described_class.new(name: "items", type: [:TypeZ, :TypeA], optional: true, nullable: true, multi: true)
        result = prop.render(sort_order: :alphabetical)
        expect(result).to eq("items?: Array<TypeA | TypeZ> | null")
      end
    end
  end

  describe "Typelizer::OpenAPI.property_schema" do
    it "maps string type from column_type" do
      prop = described_class.new(name: "title", type: :string, column_type: :string)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :string})
    end

    it "maps integer column_type to integer (not number)" do
      prop = described_class.new(name: "age", type: :number, column_type: :integer)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :integer})
    end

    it "maps decimal column_type with format: :double" do
      prop = described_class.new(name: "price", type: :number, column_type: :decimal)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :number, format: :double})
    end

    it "maps float column_type with format: :float" do
      prop = described_class.new(name: "score", type: :number, column_type: :float)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :number, format: :float})
    end

    it "maps boolean column_type" do
      prop = described_class.new(name: "active", type: :boolean, column_type: :boolean)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :boolean})
    end

    it "maps datetime column_type with format: date-time" do
      prop = described_class.new(name: "created_at", type: :string, column_type: :datetime)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :string, format: :"date-time"})
    end

    it "maps date column_type with format: date" do
      prop = described_class.new(name: "born_on", type: :string, column_type: :date)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :string, format: :date})
    end

    it "maps uuid column_type with format: uuid" do
      prop = described_class.new(name: "token", type: :string, column_type: :uuid)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :string, format: :uuid})
    end

    it "maps bigint column_type with format: int64" do
      prop = described_class.new(name: "big_id", type: :number, column_type: :bigint)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :integer, format: :int64})
    end

    it "falls back to TS type string when no column_type" do
      prop = described_class.new(name: "title", type: :string)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :string})
    end

    it "falls back number type when no column_type" do
      prop = described_class.new(name: "count", type: :number)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :number})
    end

    it "falls back boolean type when no column_type" do
      prop = described_class.new(name: "flag", type: :boolean)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :boolean})
    end

    it "passes through valid OpenAPI types without column_type" do
      prop = described_class.new(name: "count", type: :integer)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :integer})
    end

    it "falls back to object for unmapped types" do
      prop = described_class.new(name: "data", type: :unknown)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :object})
    end

    it "maps :any to object" do
      prop = described_class.new(name: "data", type: :any)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :object})
    end

    it "maps :never to object" do
      prop = described_class.new(name: "data", type: :never)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :object})
    end

    it "maps Record<string, unknown> to object" do
      prop = described_class.new(name: "metadata", type: :"Record<string, unknown>")
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :object})
    end

    it "maps Partial<User> to object" do
      prop = described_class.new(name: "partial_user", type: :"Partial<User>")
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :object})
    end

    it "maps Pick<User, 'name'> to object" do
      prop = described_class.new(name: "user_name", type: :"Pick<User, 'name'>")
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :object})
    end

    it "maps generic types with angle brackets to object" do
      prop = described_class.new(name: "data", type: :"Map<string, number>")
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :object})
    end

    it "maps TS-only types to object inside unions" do
      prop = described_class.new(name: "data", type: [:string, :any])
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({
        anyOf: [{type: :string}, {type: :object}]
      })
    end

    it "treats string types as $ref" do
      prop = described_class.new(name: "author", type: "Author")
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({"$ref" => "#/components/schemas/Author"})
    end

    it "includes nullable: true for nullable properties in OpenAPI 3.0" do
      prop = described_class.new(name: "bio", type: :string, column_type: :text, nullable: true)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :string, nullable: true})
    end

    it "uses type array for nullable properties in OpenAPI 3.1" do
      prop = described_class.new(name: "bio", type: :string, column_type: :text, nullable: true)
      expect(Typelizer::OpenAPI.property_schema(prop, openapi_version: "3.1")).to eq({type: [:string, :null]})
    end

    it "wraps in array for multi properties" do
      prop = described_class.new(name: "tags", type: :string, column_type: :string, multi: true)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :array, items: {type: :string}})
    end

    it "includes enum values" do
      prop = described_class.new(name: "role", type: :string, enum: %w[admin user guest])
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :string, enum: %w[admin user guest]})
    end

    it "includes description from comment" do
      prop = described_class.new(name: "name", type: :string, column_type: :string, comment: "User's full name")
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :string, description: "User's full name"})
    end

    it "does not include description when comment is not a string" do
      prop = described_class.new(name: "name", type: :string, column_type: :string, comment: false)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :string})
    end

    it "includes deprecated flag" do
      prop = described_class.new(name: "old_field", type: :string, column_type: :string, deprecated: true)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :string, deprecated: true})
    end

    it "generates $ref for Interface types" do
      interface = instance_double(Typelizer::Interface, name: "UserPost", properties: [])

      prop = described_class.new(name: "post", type: interface)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({"$ref" => "#/components/schemas/UserPost"})
    end

    it "wraps $ref in array for multi Interface types" do
      interface = instance_double(Typelizer::Interface, name: "Tag", properties: [])

      prop = described_class.new(name: "tags", type: interface, multi: true)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :array, items: {"$ref" => "#/components/schemas/Tag"}})
    end

    it "wraps nullable $ref in allOf for 3.0" do
      interface = instance_double(Typelizer::Interface, name: "Author", properties: [])

      prop = described_class.new(name: "author", type: interface, nullable: true)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({
        nullable: true, allOf: [{"$ref" => "#/components/schemas/Author"}]
      })
    end

    it "wraps nullable $ref in oneOf for 3.1" do
      interface = instance_double(Typelizer::Interface, name: "Author", properties: [])

      prop = described_class.new(name: "author", type: interface, nullable: true)
      expect(Typelizer::OpenAPI.property_schema(prop, openapi_version: "3.1")).to eq({
        oneOf: [{"$ref" => "#/components/schemas/Author"}, {type: :null}]
      })
    end

    it "wraps $ref in allOf when siblings present in 3.0" do
      interface = instance_double(Typelizer::Interface, name: "Author", properties: [])

      prop = described_class.new(name: "author", type: interface, comment: "Post author", deprecated: true)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({
        allOf: [{"$ref" => "#/components/schemas/Author"}], description: "Post author", deprecated: true
      })
    end

    it "allows $ref siblings directly in 3.1" do
      interface = instance_double(Typelizer::Interface, name: "Author", properties: [])

      prop = described_class.new(name: "author", type: interface, comment: "Post author", deprecated: true)
      expect(Typelizer::OpenAPI.property_schema(prop, openapi_version: "3.1")).to eq({
        "$ref" => "#/components/schemas/Author", :description => "Post author", :deprecated => true
      })
    end

    it "handles nullable $ref with siblings in 3.0" do
      interface = instance_double(Typelizer::Interface, name: "Author", properties: [])

      prop = described_class.new(name: "author", type: interface, nullable: true, comment: "Post author", deprecated: true)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({
        nullable: true, allOf: [{"$ref" => "#/components/schemas/Author"}], description: "Post author", deprecated: true
      })
    end

    it "handles nullable $ref with siblings in 3.1" do
      interface = instance_double(Typelizer::Interface, name: "Author", properties: [])

      prop = described_class.new(name: "author", type: interface, nullable: true, comment: "Post author", deprecated: true)
      expect(Typelizer::OpenAPI.property_schema(prop, openapi_version: "3.1")).to eq({
        oneOf: [{"$ref" => "#/components/schemas/Author"}, {type: :null}], description: "Post author", deprecated: true
      })
    end

    it "applies nullable to the array container, not items in 3.0" do
      prop = described_class.new(name: "tags", type: :string, column_type: :string, multi: true, nullable: true)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({
        type: :array, nullable: true, items: {type: :string}
      })
    end

    it "applies nullable to the array container, not items in 3.1" do
      prop = described_class.new(name: "tags", type: :string, column_type: :string, multi: true, nullable: true)
      expect(Typelizer::OpenAPI.property_schema(prop, openapi_version: "3.1")).to eq({
        type: [:array, :null], items: {type: :string}
      })
    end

    it "includes null in enum values for nullable enums" do
      prop = described_class.new(name: "role", type: :string, enum: %w[admin user], nullable: true)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({
        type: :string, nullable: true, enum: ["admin", "user", nil]
      })
    end

    it "does not duplicate null in enum values if already present" do
      prop = described_class.new(name: "role", type: :string, enum: ["admin", "user", nil], nullable: true)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({
        type: :string, nullable: true, enum: ["admin", "user", nil]
      })
    end

    it "does not add null to enum values for non-nullable enums" do
      prop = described_class.new(name: "role", type: :string, enum: %w[admin user])
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({
        type: :string, enum: %w[admin user]
      })
    end

    it "maps object type without column_type to object" do
      prop = described_class.new(name: "metadata", type: :object)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :object})
    end

    it "maps json column_type to object" do
      prop = described_class.new(name: "metadata", type: :object, column_type: :json)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :object})
    end

    it "maps jsonb column_type to object" do
      prop = described_class.new(name: "settings", type: :object, column_type: :jsonb)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :object})
    end

    it "maps binary column_type with format" do
      prop = described_class.new(name: "data", type: :string, column_type: :binary)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({type: :string, format: :binary})
    end

    it "combines nullable, multi, enum and description in 3.0" do
      prop = described_class.new(
        name: "roles",
        type: :string,
        multi: true,
        nullable: true,
        enum: %w[admin user],
        comment: "User roles"
      )
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({
        type: :array, nullable: true, description: "User roles",
        items: {type: :string, enum: %w[admin user]}
      })
    end

    it "combines nullable, multi, enum and description in 3.1" do
      prop = described_class.new(
        name: "roles",
        type: :string,
        multi: true,
        nullable: true,
        enum: %w[admin user],
        comment: "User roles"
      )
      expect(Typelizer::OpenAPI.property_schema(prop, openapi_version: "3.1")).to eq({
        type: [:array, :null], description: "User roles",
        items: {type: :string, enum: %w[admin user]}
      })
    end

    it "generates anyOf for union of reference types" do
      prop = described_class.new(name: "item", type: [:Post, :Comment])
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({
        anyOf: [
          {"$ref" => "#/components/schemas/Post"},
          {"$ref" => "#/components/schemas/Comment"}
        ]
      })
    end

    it "generates anyOf for union of primitive types" do
      prop = described_class.new(name: "value", type: [:string, :number])
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({
        anyOf: [{type: :string}, {type: :number}]
      })
    end

    it "generates anyOf for mixed union types" do
      prop = described_class.new(name: "item", type: [:string, :Post])
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({
        anyOf: [{type: :string}, {"$ref" => "#/components/schemas/Post"}]
      })
    end

    it "generates nullable anyOf in 3.0" do
      prop = described_class.new(name: "item", type: [:Post, :Comment], nullable: true)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({
        anyOf: [
          {"$ref" => "#/components/schemas/Post"},
          {"$ref" => "#/components/schemas/Comment"}
        ],
        nullable: true
      })
    end

    it "generates nullable anyOf in 3.1" do
      prop = described_class.new(name: "item", type: [:Post, :Comment], nullable: true)
      expect(Typelizer::OpenAPI.property_schema(prop, openapi_version: "3.1")).to eq({
        anyOf: [
          {"$ref" => "#/components/schemas/Post"},
          {"$ref" => "#/components/schemas/Comment"},
          {type: :null}
        ]
      })
    end

    it "wraps anyOf in array for multi union types" do
      prop = described_class.new(name: "items", type: [:Post, :Comment], multi: true)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({
        type: :array,
        items: {
          anyOf: [
            {"$ref" => "#/components/schemas/Post"},
            {"$ref" => "#/components/schemas/Comment"}
          ]
        }
      })
    end

    it "includes description and deprecated on union types" do
      prop = described_class.new(name: "item", type: [:Post, :Comment], comment: "Polymorphic item", deprecated: true)
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({
        anyOf: [
          {"$ref" => "#/components/schemas/Post"},
          {"$ref" => "#/components/schemas/Comment"}
        ],
        description: "Polymorphic item",
        deprecated: true
      })
    end

    it "generates anyOf for union of Interface types" do
      post_iface = instance_double(Typelizer::Interface, name: "Post", properties: [])
      comment_iface = instance_double(Typelizer::Interface, name: "Comment", properties: [])

      prop = described_class.new(name: "item", type: [post_iface, comment_iface])
      expect(Typelizer::OpenAPI.property_schema(prop)).to eq({
        anyOf: [
          {"$ref" => "#/components/schemas/Post"},
          {"$ref" => "#/components/schemas/Comment"}
        ]
      })
    end
  end

  describe "#enum_runtime_definition" do
    it "returns nil without enum_type_name" do
      prop = described_class.new(name: "status", enum: %w[draft published])
      expect(prop.enum_runtime_definition).to be_nil
    end

    it "returns nil without enum values" do
      prop = described_class.new(name: "status", enum_type_name: "Status")
      expect(prop.enum_runtime_definition).to be_nil
    end

    it "generates an identity-mapped as-const object" do
      prop = described_class.new(name: "role", enum: %w[guest member admin], enum_type_name: "UserRole")
      expect(prop.enum_runtime_definition).to eq(
        "const UserRole = { guest: 'guest', member: 'member', admin: 'admin' } as const"
      )
    end

    it "sorts keys alphabetically when requested" do
      prop = described_class.new(name: "role", enum: %w[zebra apple banana], enum_type_name: "Order")
      expect(prop.enum_runtime_definition(sort_order: :alphabetical)).to eq(
        "const Order = { apple: 'apple', banana: 'banana', zebra: 'zebra' } as const"
      )
    end

    it "uses double quotes when requested" do
      prop = described_class.new(name: "role", enum: %w[guest admin], enum_type_name: "UserRole")
      expect(prop.enum_runtime_definition(prefer_double_quotes: true)).to eq(
        'const UserRole = { guest: "guest", admin: "admin" } as const'
      )
    end

    it "quotes keys that aren't valid JS identifiers" do
      prop = described_class.new(name: "status", enum: ["pending-review", "ok"], enum_type_name: "Status")
      expect(prop.enum_runtime_definition).to eq(
        "const Status = { 'pending-review': 'pending-review', ok: 'ok' } as const"
      )
    end

    it "honors prefer_double_quotes for quoted keys too" do
      prop = described_class.new(name: "status", enum: ["pending-review", "ok"], enum_type_name: "Status")
      expect(prop.enum_runtime_definition(prefer_double_quotes: true)).to eq(
        'const Status = { "pending-review": "pending-review", ok: "ok" } as const'
      )
    end
  end

  describe "determinism" do
    it "produces identical output on multiple runs with sorting" do
      prop = described_class.new(
        name: "sections",
        type: [:WebStrapiSectionsPartnerHero, :WebStrapiSectionsAboutUs, :WebStrapiSectionsChallenges],
        multi: true
      )

      results = 10.times.map { prop.render(sort_order: :alphabetical) }
      expect(results.uniq.size).to eq(1)
      expect(results.first).to eq("sections: Array<WebStrapiSectionsAboutUs | WebStrapiSectionsChallenges | WebStrapiSectionsPartnerHero>")
    end
  end
end
