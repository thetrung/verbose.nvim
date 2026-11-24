; Comments
(comment) @comment

; Directives
(include_directive "Include" @keyword.import)
(include_directive path: (string_literal) @string.special.path)

; Modifiers & visibility
(visibility) @keyword.modifier
[
  "Static"
  "Volatile"
  "ByRef"
  "Async"
  "At"
] @keyword.modifier

; Declarations
[
  "Structure"
  "Enum"
  "Dim"
  "As"
  "Declare"
  "Test"
] @keyword

[
  "Function"
  "Sub"
  "End"
] @keyword.function

; Control flow
[
  "If"
  "Then"
  "Else"
  "Match"
  "Select"
  "Case"
  "When"
  "With"
] @keyword.conditional

[
  "While"
  "For"
  "To"
  "Do"
] @keyword.repeat

[
  "Return"
  "Await"
  "Assert"
  "Label"
  "GoTo"
] @keyword.return

; Operators
[
  "And"
  "Or"
  "Xor"
  "Not"
  "Mod"
  "Shl"
  "Shr"
] @keyword.operator

[
  "+"
  "-"
  "*"
  "/"
  "="
  "<>"
  "<"
  ">"
  "<="
  ">="
  "&"
] @operator

; Types
(builtin_type) @type.builtin
(task_type "Task" @type.builtin)
(structure_declaration name: (identifier) @type.definition)
(enum_declaration name: (identifier) @type.definition)
(type_spec (identifier) @type)
(struct_literal type: (identifier) @type)

; Functions & Calls
(function_declaration name: (identifier) @function)
(sub_declaration name: (identifier) @function)
(declare_statement name: (identifier) @function)
(builtin_call name: _ @function.builtin)
(call_expression function: (expression (primary_expression (identifier) @function.call)))

; Parameters, fields & enum members
(parameter name: (identifier) @variable.parameter)
(variadic_parameter) @punctuation.special
(field_declarator name: (identifier) @variable.member)
(member_expression field: (identifier) @variable.member)
(with_member_expression field: (identifier) @variable.member)
(field_init name: (identifier) @variable.member)
(enum_member name: (identifier) @constant)
(label_statement name: (identifier) @label)
(goto_statement target: (identifier) @label)

; Literals
(integer_literal) @number
(float_literal) @number.float
(boolean_literal) @boolean
(nothing_literal) @constant.builtin
(string_literal) @string
(interpolated_string) @string
(escape_sequence) @string.escape
(escaped_brace) @string.escape
(interpolation "{" @punctuation.special "}" @punctuation.special)

; Punctuation
[
  "("
  ")"
] @punctuation.bracket

[
  ","
  "."
] @punctuation.delimiter
