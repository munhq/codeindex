; Custom tags query for SQL (DerekStride/tree-sitter-sql). DDL create
; statements become symbols keyed by their object reference.
(create_table (object_reference) @name) @definition.class
(create_view (object_reference) @name) @definition.class
(create_materialized_view (object_reference) @name) @definition.class
(create_function (object_reference) @name) @definition.function
(create_procedure (object_reference) @name) @definition.function
(create_index (identifier) @name) @definition.constant
(create_type (object_reference) @name) @definition.type
(create_schema (identifier) @name) @definition.module
(create_sequence (object_reference) @name) @definition.constant
