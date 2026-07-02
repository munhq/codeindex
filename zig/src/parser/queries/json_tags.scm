; Custom tags query for JSON. Captures top-level object keys only
; (anchored under document > object) to avoid emitting every nested key.
(document
  (object
    (pair key: (string (string_content) @name) @definition.variable)))
