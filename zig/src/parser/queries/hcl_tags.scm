; HCL/Terraform: capture block *labels* (the resource type + name, the variable/
; module/output name) — not the block keyword (`resource`/`data`/`provider`),
; which repeats in every file and is pure noise as a symbol.
(block (string_lit) @name) @definition.type
