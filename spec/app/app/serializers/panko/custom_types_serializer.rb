# frozen_string_literal: true

module Panko
  class CustomTypesSerializer < BaseSerializer
    typelize_from ::User

    attributes :id

    typelize provider: "'cloudpayments' | 'tiptoppay'"
    attributes :provider

    typelize metadata: "{ name: string; visitorId: string | null }"
    attributes :metadata

    typelize lookup: "Record<string, number | null>"
    attributes :lookup

    typelize pair: "[string | null, number]"
    attributes :pair

    typelize result: "{ ok: boolean } | { error: string }"
    attributes :result

    typelize config: "{ retries: number | null } | null"
    attributes :config

    typelize status: "'active' | 'inactive' | null"
    attributes :status

    typelize kind: "'user' | null"
    attributes :kind

    typelize tag: [:string, :number]
    attributes :tag
  end
end
