module Ams
  class PreferDoubleQuotesSerializer < UserSerializer
    typelize_from ::User

    typelizer_config.prefer_double_quotes = true
  end
end
