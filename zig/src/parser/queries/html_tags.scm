; Custom tags query for HTML. Element tag names form a structural outline.
; (Predicate-based id/class filtering is not supported by the query runner,
; so we surface element tags rather than every attribute value.)
(start_tag (tag_name) @name) @definition.type
(self_closing_tag (tag_name) @name) @definition.type
