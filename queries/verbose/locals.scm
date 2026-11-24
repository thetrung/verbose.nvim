[
  (function_declaration)
  (sub_declaration)
  (test_block)
  (if_statement)
  (while_statement)
  (for_statement)
  (match_statement)
  (with_statement)
] @local.scope

(function_declaration name: (identifier) @local.definition.function)
(sub_declaration name: (identifier) @local.definition.function)
(declare_statement name: (identifier) @local.definition.function)
(structure_declaration name: (identifier) @local.definition.type)
(enum_declaration name: (identifier) @local.definition.type)
(parameter name: (identifier) @local.definition.parameter)
(var_declarator name: (identifier) @local.definition.var)
(identifier) @local.reference
