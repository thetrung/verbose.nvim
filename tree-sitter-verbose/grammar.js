/// <reference types="tree-sitter-cli/dsl" />
// Tree-sitter grammar for VerBose-Lang v0.6.0+

module.exports = grammar({
  name: "verbose",

  extras: $ => [
    /[ \t\r]/,
    $.comment,
  ],

  word: $ => $.identifier,

  conflicts: $ => [
    [$.primary_expression, $.struct_literal],
    [$.type_spec, $.array_type_spec],
  ],

  rules: {
    source_file: $ => repeat(choice(
      $._top_level_item,
      $._newline,
    )),

    _newline: _ => /\n/,

    comment: _ => token(seq("'", /[^\n]*/)),

    _top_level_item: $ => choice(
      $.include_directive,
      $.structure_declaration,
      $.enum_declaration,
      $.declare_statement,
      $.function_declaration,
      $.sub_declaration,
      $.test_block,
      $._statement,
    ),

    visibility: _ => choice("Public", "Private"),

    include_directive: $ => seq(
      "Include",
      field("path", $.string_literal),
      $._newline,
    ),

    // --- Structures ---
    structure_declaration: $ => seq(
      optional($.visibility),
      "Structure",
      field("name", $.identifier),
      $._newline,
      repeat(choice($.structure_field, $._newline)),
      "End", "Structure",
    ),

    structure_field: $ => seq(
      "Dim",
      commaSep1($.field_declarator),
      $._newline,
    ),

    field_declarator: $ => seq(
      field("name", $.identifier),
      optional($.array_bounds),
      optional(seq("As", field("type", $.type_spec))),
    ),

    // --- Enums ---
    enum_declaration: $ => seq(
      optional($.visibility),
      "Enum",
      field("name", $.identifier),
      $._newline,
      repeat(choice($.enum_member, $._newline)),
      "End", "Enum",
    ),

    enum_member: $ => seq(
      field("name", $.identifier),
      optional(seq("=", field("value", $.expression))),
      $._newline,
    ),

    // --- External C FFI Declare ---
    declare_statement: $ => seq(
      optional($.visibility),
      "Declare",
      choice("Function", "Sub"),
      field("name", $.identifier),
      "(",
      optional($.parameter_list),
      ")",
      optional(seq("As", field("return_type", $.type_spec))),
      $._newline,
    ),

    // --- Functions & Subs ---
    function_declaration: $ => seq(
      optional($.visibility),
      optional("Async"),
      "Function",
      field("name", $.identifier),
      "(",
      optional($.parameter_list),
      ")",
      optional(seq("As", field("return_type", $.type_spec))),
      $._newline,
      repeat(choice($._statement, $._newline)),
      "End", "Function",
    ),

    sub_declaration: $ => seq(
      optional($.visibility),
      optional("Async"),
      "Sub",
      field("name", $.identifier),
      "(",
      optional($.parameter_list),
      ")",
      $._newline,
      repeat(choice($._statement, $._newline)),
      "End", "Sub",
    ),

    test_block: $ => seq(
      "Test",
      field("name", $.string_literal),
      $._newline,
      repeat(choice($._statement, $._newline)),
      "End", "Test",
    ),

    parameter_list: $ => commaSep1(choice($.parameter, $.variadic_parameter)),

    variadic_parameter: _ => "...",

    parameter: $ => seq(
      optional("ByRef"),
      field("name", $.identifier),
      optional(seq("(", ")")),
      optional(seq("As", field("type", $.type_spec))),
    ),

    // --- Static & Dim ---
    static_declaration: $ => seq(
      optional($.visibility),
      optional("Volatile"),
      "Static",
      commaSep1($.var_declarator),
      optional(seq("At", field("address", $.expression))),
      $._newline,
    ),

    dim_statement: $ => seq(
      optional("Volatile"),
      "Dim",
      commaSep1($.var_declarator),
      $._newline,
    ),

    var_declarator: $ => seq(
      field("name", $.identifier),
      optional($.array_bounds),
      optional(choice(
        seq("As", field("type", $.type_spec), optional(choice(seq("=", field("value", $.expression)), $.with_initializer))),
        seq("=", field("value", $.expression), optional(seq("As", field("type", $.type_spec)))),
        $.with_initializer,
      )),
    ),

    array_bounds: $ => seq("(", optional($.expression), ")"),

    // --- Statements ---
    _statement: $ => choice(
      $.dim_statement,
      $.static_declaration,
      $.if_statement,
      $.while_statement,
      $.for_statement,
      $.match_statement,
      $.select_statement,
      $.with_statement,
      $.return_statement,
      $.assert_statement,
      $.label_statement,
      $.goto_statement,
      $.assignment_statement,
      $.expression_statement,
    ),

    if_statement: $ => seq(
      "If",
      field("condition", $.expression),
      "Then",
      $._newline,
      repeat(choice($._statement, $._newline)),
      optional(seq(
        "Else",
        $._newline,
        repeat(choice($._statement, $._newline)),
      )),
      "End", "If",
    ),

    while_statement: $ => seq(
      "While",
      field("condition", $.expression),
      "Do",
      $._newline,
      repeat(choice($._statement, $._newline)),
      "End", "While",
    ),

    for_statement: $ => seq(
      "For",
      field("variable", $.identifier),
      "=",
      field("start", $.expression),
      "To",
      field("end", $.expression),
      "Do",
      $._newline,
      repeat(choice($._statement, $._newline)),
      "End", "For",
    ),

    match_statement: $ => seq(
      "Match",
      optional(field("scrutinee", $.expression)),
      "With",
      $._newline,
      repeat($._newline),
      repeat($.match_arm),
      "End", "Match",
    ),

    match_arm: $ => prec.right(seq(
      "Case",
      choice(
        "_",
        "Else",
        commaSep1($.expression),
      ),
      optional(seq("When", field("guard", $.expression))),
      "Then",
      choice(
        seq($._statement),
        seq($._newline, repeat(choice($._statement, $._newline))),
      ),
    )),

    select_statement: $ => seq(
      "Select", "Case",
      field("scrutinee", $.expression),
      $._newline,
      repeat($._newline),
      repeat($.case_branch),
      "End", "Select",
    ),

    case_branch: $ => prec.right(seq(
      "Case",
      choice("Else", commaSep1($.expression)),
      $._newline,
      repeat(choice($._statement, $._newline)),
    )),

    with_statement: $ => seq(
      "With",
      field("target", $.expression),
      $._newline,
      repeat(choice($._statement, $._newline)),
      "End", "With",
    ),

    return_statement: $ => seq(
      "Return",
      optional($.expression),
      $._newline,
    ),

    assert_statement: $ => seq(
      "Assert",
      field("condition", $.expression),
      optional(seq(",", field("message", $.expression))),
      $._newline,
    ),

    label_statement: $ => seq(
      "Label",
      field("name", $.identifier),
      $._newline,
    ),

    goto_statement: $ => seq(
      "GoTo",
      field("target", $.identifier),
      $._newline,
    ),

    assignment_statement: $ => prec(1, seq(
      field("left", $.expression),
      "=",
      field("right", $.expression),
      $._newline,
    )),

    expression_statement: $ => seq(
      $.expression,
      $._newline,
    ),

    // --- Types ---
    type_spec: $ => choice(
      $.builtin_type,
      $.task_type,
      $.identifier,
    ),

    array_type_spec: $ => seq($.type_spec, "(", ")"),

    builtin_type: _ => choice(
      "Integer", "Byte", "Short", "Long",
      "Single", "Double", "Boolean",
      "Pointer", "String", "Arena", "Task",
    ),

    task_type: $ => seq("Task", "(", $.type_spec, ")"),

    // --- Expressions ---
    expression: $ => choice(
      $.binary_expression,
      $.unary_expression,
      $.await_expression,
      $.postfix_expression,
      $.primary_expression,
    ),

    unary_expression: $ => prec(9, seq(
      choice("-", "Not"),
      $.expression,
    )),

    await_expression: $ => prec(9, seq(
      "Await",
      $.expression,
    )),

    binary_expression: $ => choice(
      prec.left(1, seq($.expression, "Or", $.expression)),
      prec.left(2, seq($.expression, "Xor", $.expression)),
      prec.left(3, seq($.expression, "And", $.expression)),
      prec.left(4, seq($.expression, choice("=", "<>", "<", ">", "<=", ">="), $.expression)),
      prec.left(5, seq($.expression, choice("Shl", "Shr"), $.expression)),
      prec.left(6, seq($.expression, "&", optional($._newline), $.expression)),
      prec.left(7, seq($.expression, choice("+", "-"), $.expression)),
      prec.left(8, seq($.expression, choice("*", "/", "Mod"), $.expression)),
    ),

    postfix_expression: $ => prec.left(10, choice(
      $.call_expression,
      $.member_expression,
    )),

    call_expression: $ => prec.left(10, seq(
      field("function", $.expression),
      "(",
      optional(commaSep1($.argument)),
      ")",
    )),

    argument: $ => seq(
      optional("ByRef"),
      $.expression,
    ),

    member_expression: $ => prec.left(10, seq(
      field("object", $.expression),
      ".",
      field("field", $.identifier),
    )),

    with_member_expression: $ => prec(10, seq(
      ".",
      field("field", $.identifier),
    )),

    primary_expression: $ => choice(
      $.builtin_call,
      $.struct_literal,
      $.with_member_expression,
      $.identifier,
      $.integer_literal,
      $.float_literal,
      $.boolean_literal,
      $.nothing_literal,
      $.string_literal,
      $.interpolated_string,
      $.parenthesized_expression,
      $.array_literal,
    ),

    builtin_call: $ => seq(
      field("name", choice(
        "SizeOf", "ArenaAlloc", "HeapAlloc", "HeapRealloc",
        "VolatileLoad", "VolatileStore", "AddressOf",
        "PtrRead", "PtrWrite", "PtrAdd",
      )),
      "(",
      optional(commaSep1($.argument)),
      ")",
    ),

    struct_literal: $ => seq(
      field("type", $.identifier),
      $.with_initializer,
    ),

    with_initializer: $ => seq(
      "With",
      "(",
      repeat(choice(
        seq($.field_init, optional(",")),
        $._newline,
      )),
      ")",
    ),

    field_init: $ => seq(
      field("name", $.identifier),
      "=",
      field("value", $.expression),
    ),

    parenthesized_expression: $ => seq("(", $.expression, ")"),

    array_literal: $ => seq(
      "(",
      optional(seq($.expression, ",", commaSep1($.expression))),
      ")",
    ),

    // --- Literals ---
    identifier: _ => /[A-Za-z_][A-Za-z0-9_]*/,
    integer_literal: _ => token(choice(/0[xX][0-9a-fA-F]+/, /[0-9]+/)),
    float_literal: _ => token(/[0-9]+\.[0-9]+([eE][+-]?[0-9]+)?/),
    boolean_literal: _ => choice("True", "False"),
    nothing_literal: _ => "Nothing",

    string_literal: $ => seq(
      '"',
      repeat(choice(
        $.escape_sequence,
        /[^"\\\n]+/,
      )),
      '"',
    ),

    interpolated_string: $ => seq(
      '$"',
      repeat(choice(
        $.escape_sequence,
        $.escaped_brace,
        $.interpolation,
        /[^"\\{}\n]+/,
      )),
      '"',
    ),

    escaped_brace: _ => choice("{{", "}}"),

    interpolation: $ => seq(
      "{",
      $.expression,
      "}",
    ),

    escape_sequence: _ => token.immediate(/\\[nrt0"\\]/),
  },
});

function commaSep1(rule) {
  return seq(rule, repeat(seq(",", rule)));
}
