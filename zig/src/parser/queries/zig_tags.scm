; Custom tags query for Zig (upstream tree-sitter-zig ships no tags.scm).
; Captures functions, const/var bindings (which is how structs, enums, unions
; and types are declared in Zig), struct fields, and tests.
;
; The function pattern anchors on `Decl`, not on `FnProto`. `FnProto` is the
; signature alone — the grammar puts the body in a sibling `Block` under
; `Decl: seq(…, FnProto, choice(';', Block))` — so capturing `FnProto` gave every
; Zig function a one-line range. That made `read_symbol` return just the
; signature, and it hid function bodies from every containment check that asks
; "is this binding a local?".
;
; The binding pattern is deliberately unanchored: `const X = struct { … }` inside
; a function is real structure and should be captured. Function locals match it
; too, and treesitter.drop_local_bindings removes those afterwards — a binding
; inside a function body that encloses no definition of its own.
(Decl (FnProto function: (IDENTIFIER) @name)) @definition.function
(VarDecl variable_type_function: (IDENTIFIER) @name) @definition.constant
(ContainerField field_member: (IDENTIFIER) @name) @definition.variable
(TestDecl (STRINGLITERALSINGLE) @name) @definition.test
