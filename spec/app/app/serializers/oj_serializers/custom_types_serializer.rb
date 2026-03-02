# frozen_string_literal: true

module OjSerializers
  class CustomTypesSerializer < BaseSerializer
    typelize_from ::User

    attributes :id

    typelize provider: "'cloudpayments' | 'tiptoppay'"
    attribute :provider

    typelize metadata: "{ name: string; visitorId: string | null }"
    attribute :metadata

    typelize lookup: "Record<string, number | null>"
    attribute :lookup

    typelize pair: "[string | null, number]"
    attribute :pair

    typelize result: "{ ok: boolean } | { error: string }"
    attribute :result

    typelize config: "{ retries: number | null } | null"
    attribute :config

    typelize status: "'active' | 'inactive' | null"
    attribute :status

    typelize kind: "'user' | null"
    attribute :kind

    typelize [:string, :number]
    attribute :tag
  end
end
