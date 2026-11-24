" Vim syntax fallback for VerBose-Lang v0.6.0+
" Used automatically when Tree-sitter parser is not yet compiled.
if exists("b:current_syntax")
  finish
endif

syn keyword verboseInclude    Include
syn keyword verboseModifier   Public Private Static Volatile ByRef Async At
syn keyword verboseKeyword    Structure Enum Dim As Declare Test End
syn keyword verboseFunction   Function Sub
syn keyword verboseControl    If Then Else Match Select Case When With
syn keyword verboseRepeat     While For To Do
syn keyword verboseStatement  Return Await Assert Label GoTo
syn keyword verboseOperator   And Or Xor Not Mod Shl Shr
syn keyword verboseType       Integer Byte Short Long Single Double Boolean Pointer String Arena Task
syn keyword verboseBoolean    True False
syn keyword verboseConstant   Nothing
syn keyword verboseBuiltin    SizeOf ArenaCreate ArenaFromBuffer ArenaAlloc ArenaAllocBytes ArenaReset ArenaMark ArenaRewind ArenaUsed ArenaRemaining ArenaCapacity ArenaDestroy IsNull HeapAlloc HeapRealloc HeapAllocBytes HeapFree VolatileLoad VolatileStore AddressOf PtrRead PtrWrite PtrAdd Len Printf PrintLn

syn match   verboseNumber     "\<\d\+\>"
syn match   verboseNumber     "\<0[xX][0-9a-fA-F]\+\>"
syn match   verboseFloat      "\<\d\+\.\d\+\([eE][+-]\?\d\+\)\?\>"
syn match   verboseFuncCall   "\<[A-Za-z_][A-Za-z0-9_]*\ze\s*("
syn match   verboseMember     "\.\zs[A-Za-z_][A-Za-z0-9_]*\>"

syn match   verboseEscape     contained "\\[nrt0\"\\]"
syn region  verboseString     start=+"+ skip=+\\\\\|\\"+ end=+"+ contains=verboseEscape
syn region  verboseInterpExpr contained matchgroup=Special start=+{+ end=+}+ contains=TOP
syn region  verboseInterp     start=+\$"+ skip=+\\\\\|\\"+ end=+"+ contains=verboseEscape,verboseInterpExpr
syn match   verboseComment    "'.*$"

hi def link verboseInclude    Include
hi def link verboseModifier   StorageClass
hi def link verboseKeyword    Keyword
hi def link verboseFunction   Keyword
hi def link verboseControl    Conditional
hi def link verboseRepeat     Repeat
hi def link verboseStatement  Statement
hi def link verboseOperator   Operator
hi def link verboseType       Type
hi def link verboseBoolean    Boolean
hi def link verboseConstant   Constant
hi def link verboseBuiltin    Function
hi def link verboseNumber     Number
hi def link verboseFloat      Float
hi def link verboseFuncCall   Function
hi def link verboseMember     Identifier
hi def link verboseEscape     SpecialChar
hi def link verboseString     String
hi def link verboseInterp     String
hi def link verboseComment    Comment

let b:current_syntax = "verbose"
