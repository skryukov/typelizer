module Panko
  class VerbatimModuleSyntaxSerializer < BaseSerializer
    typelize_from ::User

    attributes :id, :username

    typelizer_config.verbatim_module_syntax = true
  end
end
