; Custom tags query for Nix. The upstream tags.scm only captures bindings
; whose value is a function; we capture all attribute bindings (the navigable
; structure of a Nix file) as variables.
(binding attrpath: (attrpath attr: (identifier) @name)) @definition.variable
