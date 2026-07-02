; Custom tags query for Zig (upstream tree-sitter-zig ships no tags.scm).
; Captures functions, top-level const/var bindings (which is how structs,
; enums, unions and types are declared in Zig), struct fields, and tests.
(FnProto function: (IDENTIFIER) @name) @definition.function
(VarDecl variable_type_function: (IDENTIFIER) @name) @definition.constant
(ContainerField field_member: (IDENTIFIER) @name) @definition.variable
(TestDecl (STRINGLITERALSINGLE) @name) @definition.test
