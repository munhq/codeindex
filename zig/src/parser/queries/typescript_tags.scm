; TypeScript/JavaScript. The vendored tags.scm only matched ambient/.d.ts
; signatures, so normal code produced no symbols. This covers real declarations.
(function_declaration name: (identifier) @name) @definition.function
(generator_function_declaration name: (identifier) @name) @definition.function
(class_declaration name: (type_identifier) @name) @definition.class
(abstract_class_declaration name: (type_identifier) @name) @definition.class
(interface_declaration name: (type_identifier) @name) @definition.class
(type_alias_declaration name: (type_identifier) @name) @definition.type
(enum_declaration name: (identifier) @name) @definition.enum
(method_definition name: (property_identifier) @name) @definition.method
(public_field_definition name: (property_identifier) @name) @definition.variable
(variable_declarator name: (identifier) @name) @definition.variable
