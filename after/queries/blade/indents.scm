; extends

; Upstream's blade indents.scm marks (conditional) (loop) (section) (switch) and
; friends as @indent.begin but supplies no @indent.branch, so every closing and
; branch directive stays at the inner level. That made `=` and `gg=G` actively
; destructive. They put `@endif` one level too deep and, on already correctly
; indented Blade, moved `@empty`, `@endforelse` and `@endsection`, so the
; operator was not idempotent on well-formed input.
;
; The parse tree these three rules target, verified against tree-sitter-blade
; with :InspectTree:
;   conditional -> directive_start, parameter, text,
;                  conditional_keyword(@elseif/@else), directive_end
;   loop        -> directive_start, parameter, text, directive(@empty),
;                  text, directive_end
;   section     -> directive_start, parameter, ...children..., directive_end

; Every @end* directive: @endif, @endforeach, @endsection, @endswitch.
(directive_end) @indent.branch

; @else / @elseif
(conditional_keyword) @indent.branch

; @forelse's @empty. Scoped to (loop) and matched by text because `directive` is
; the generic node, and an unscoped rule would also dedent @csrf, @vite, @method.
(loop
  (directive) @indent.branch
  (#any-of? @indent.branch "@empty"))

; Known remaining gaps, both pre-existing upstream and not caused by the above.
;
;   @php blocks. The body is an injected php_only tree whose indent query answers
;   for those lines, and ownership of the `@endphp` line flips between passes, so
;   its indent oscillates. Reproduced with these rules removed entirely, so it is
;   upstream. Do not chase it by dropping php_statement from @indent.begin and
;   marking it @indent.auto: that was tried, and replacing rather than extending
;   the query breaks the branch rules above.
;
;   @switch. @case/@break/@default all sit one level inside @switch rather than
;   nesting further. That is a legitimate style and, unlike before, it is stable.
