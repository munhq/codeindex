; Custom tags query for TOML. Table/array-of-table headers become modules;
; top-level keys become variables.
(table (bare_key) @name) @definition.module
(table (dotted_key) @name) @definition.module
(table_array_element (bare_key) @name) @definition.module
(table_array_element (dotted_key) @name) @definition.module
(document (pair (bare_key) @name) @definition.variable)
(document (pair (dotted_key) @name) @definition.variable)
