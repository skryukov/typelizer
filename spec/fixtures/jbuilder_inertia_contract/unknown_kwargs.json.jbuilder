# FROZEN CONTRACT fixture (see spec/typelizer/jbuilder_inertia_contract_spec.rb).
# A reserved-looking but unknown kwarg is NOT inertia vocabulary: no widening
# in the generated type, and SetExt must forward it untouched at render time
# (no over-stripping).
typelize_as "ContractUnknownKwargs"

json.value @value, frobnicate: :defer
