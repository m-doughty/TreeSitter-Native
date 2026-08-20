use v6.d;

use NativeCall;
use TreeSitter::Native::FFI;
use TreeSitter::Native::Types;
use TreeSitter::Native::Languages;
use TreeSitter::Native :INTERNAL;

=begin pod

=head1 NAME

TreeSitter::Native::Query - tree-sitter queries, with predicates applied

=head1 SYNOPSIS

    use TreeSitter::Native;
    use TreeSitter::Native::Query;

    my $parser = Parser.new('python');
    my $tree   = $parser.parse($source);

    my $q = Query.new('python', tags-query('python'));

    for $q.matches($tree.root-node) -> $match {
        with $match.captures<name> -> $name {
            say $name.text, ' @ ', $name.start-point;
        }
    }

    # Or, ignoring which pattern each capture came from:
    for $q.captures($tree.root-node) -> (:key($name), :value($node)) {
        say "$name: {$node.text}";
    }

=head1 DESCRIPTION

A query is one or more S-expression patterns, compiled against a
grammar, matched against a subtree. This is the same query language the
C<tree-sitter> CLI and every editor integration uses, and the C<.scm>
files each grammar ships (L<TreeSitter::Native::Languages>) are written
in it.

=head2 Predicates are evaluated here

tree-sitter's C library B<parses> predicates — the C<(#eq? @a "x")>
clauses inside a pattern — and then deliberately does nothing with them,
because what they mean depends on how the binding can read node text.
Bindings that skip that step return matches their queries plainly say
should be excluded. The bundled javascript C<tags.scm> is exactly such a
query: without predicate evaluation it reports every C<constructor> as a
method definition and every C<require(…)> as a function call.

So this binding evaluates them. Six are supported:

=begin table
Predicate                     | Meaning
==============================|=========================================
#eq? @a "text"                | every node captured as @a has that text
#eq? @a @b                    | @a and @b capture the same text, pairwise
#not-eq? …                    | the negation of either form
#match? @a "regex"            | every node captured as @a matches
#not-match? @a "regex"        | no node captured as @a matches
#any-of? @a "x" "y"           | every @a node's text is one of the list
#not-any-of? @a "x" "y"       | no @a node's text is
=end table

A capture that a match does not contain has no nodes, and a predicate
over no nodes is vacuously true — the same rule tree-sitter's own Rust
binding uses.

Text comparison for C<#eq?> and C<#any-of?> is done on B<bytes>, so it
is exact regardless of whether the source decodes as UTF-8.

=head2 Directives are exposed, not applied

Clauses ending in C<!> rather than C<?> — C<#set!>, C<#strip!>,
C<#select-adjacent!> — are B<directives>: they do not filter matches,
they tell the consuming application to do something with one. There is
no agreed set of them and no agreed semantics, so this binding parses
them, hands them to you, and applies none:

    for $q.pattern-directives(0) -> $d {
        say $d.name, ' ', $d.args.map(*.value).join(' ');
    }
    # strip! doc ^[\s\*/]+|^[\s\*/]$
    # select-adjacent! doc definition.method

In the bundled C<tags.scm> files, every directive shapes only the
C<@doc> capture — which comment block belongs to which definition, and
how much leading C<*> to strip off it. Nothing else is affected by their
absence.

=head2 Unknown predicates fail closed

A query naming a predicate that is not in the table above is rejected at
construction with an C<X::TreeSitter::Query> of kind
C<QUERY_ERROR_PREDICATE>. Silently ignoring it would mean quietly
returning matches the query says to exclude, which is the bug this whole
module exists to avoid.

If you would rather have the matches anyway — you are exploring someone
else's query, or the predicate is one your own code will apply — pass
C<:lenient>:

    my $q = Query.new('go', $scm, :lenient);
    # (#foo? @x "y") is now parsed, exposed via .pattern-predicates,
    # and ignored when filtering.

C<:lenient> covers unrecognised B<names> only. A C<#eq?> with three
arguments is a malformed query whichever way you look at it, and is
rejected either way.

One vendored query needs C<:lenient>, and exactly one:
C<highlights-query('javascript')> uses C<#is-not? @x local>, an
editor-ecosystem property predicate rather than a text filter. All
twenty-five other vendored query files — every C<tags.scm>, every other
C<highlights.scm>, and the C<locals>, C<injections> and javascript's two
extra highlight queries — compile without it.

    # The one that needs it:
    my $q = Query.new('javascript', highlights-query('javascript'),
                      :lenient);

=head2 Regular expressions

C<#match?> patterns are written in the query file in Perl/PCRE-ish
syntax. They are translated, at query construction, into the equivalent
Raku regex, and anything the translator does not recognise is a
construction-time error rather than a silently different match.

Translated: literals, C<.>, C<^>, C<$>, C<\A>, C<\z>, C<\Z>, C<\b>,
C<\B>, the C<\d \D \w \W \s \S \n \r \t \f \e> escapes, C<\xHH> and
C<\x{HHHH}>, character classes including ranges and negation, groups
(capturing, C<(?:…)>, C<< (?<name>…) >>), lookaround (C<(?=…)>,
C<(?!…)>, C<< (?<=…) >>, C<< (?<!…) >>), the C<(?i)> and C<(?i:…)>
case-insensitivity
flags, alternation, C<* + ?> with their lazy C<*? +? ??> forms, and
C<{n}> / C<{n,}> / C<{n,m}>.

Rejected: backreferences, possessive quantifiers, POSIX bracket classes
(C<[:alpha:]>), and any other C<(?…)> construct.

Two deliberate approximations, both documented so they cannot surprise
you quietly: C<$> means end-of-string here, where Perl also lets it
match before a final newline; and alternation is translated to Raku's
C<||>, which tries alternatives left to right exactly as Perl does
(Raku's bare C<|> would prefer the longest match instead). Since
C<#match?> only ever asks whether a match exists, neither changes an
answer for any pattern that is not itself ambiguous.

=end pod

# Forward declarations: Query names Match in its return types, Match
# names Query in its attributes, and Cursor names both.
class TreeSitter::Native::Query           { ... }
class TreeSitter::Native::Query::Match    { ... }
class TreeSitter::Native::Query::Cursor   { ... }

# ====================================================================
# Perl-ish regex → Raku regex
# ====================================================================
#
# Why translate at all, rather than using Raku's own :P5 adverb? Because
# :P5 is a compile-time slang. `m:P5/$pattern/` interpolates $pattern as
# a LITERAL string to match, exactly as `m/$pattern/` does — there is no
# runtime "compile this string as a Perl 5 regex" anywhere in Rakudo
# short of EVAL, and EVAL on a string that came out of a .scm file
# someone else wrote is a remote code execution hole, not a feature.
#
# The one runtime-string regex Raku does offer is `/<$string>/`, which
# compiles the string as a RAKU regex. That is not P5-compatible in two
# ways that matter and one that is fatal:
#
#   [abc]   is a non-capturing GROUP in Raku, not a character class.
#           A P5 pattern handed straight to <$…> silently matches
#           something else.
#   {2,3}   is a CODE BLOCK in Raku. Handing an untrusted pattern to
#           <$…> would execute it. Same hole as EVAL, wearing a hat.
#
# Hence this translator: it emits only constructs it built itself, with
# every literal run wrapped in a Raku regex quoted literal, so nothing
# from the input is ever interpreted as Raku syntax. Anything it cannot
# translate faithfully is an error at query construction.

class X::TreeSitter::Regex is Exception {
    has Str $.pattern is required;
    has Str $.reason  is required;
    has Int $.offset  = 0;
    method message(--> Str) {
        "cannot translate the regular expression /$!pattern/ at "
        ~ "character $!offset: $!reason";
    }
}

# Escapes that mean the same thing in both dialects and can be passed
# through untouched, inside a character class or out of it.
my constant %SHARED-ESCAPES = %(
    'd' => 1, 'D' => 1, 'w' => 1, 'W' => 1, 's' => 1, 'S' => 1,
    'n' => 1, 'r' => 1, 't' => 1, 'f' => 1, 'e' => 1,
);

#| Quote a run of literal characters as a Raku regex literal. Only
#| C<\> and C<'> need escaping inside one, and nothing inside it is
#| interpreted — which is what makes handing an arbitrary pattern to
#| C<< <$…> >> safe once it has been through here.
my sub rx-literal(Str:D $run --> Str) is export(:INTERNAL) {
    "'" ~ $run.subst(/(<[\\']>)/, { '\\' ~ $0 }, :g) ~ "'";
}

#| Spell one character for use inside a Raku C<< <[…]> >> character
#| class. Alphanumerics stand for themselves; a space becomes an
#| explicit C<\x20> (Raku ignores literal whitespace inside a character
#| class); everything else is backslash-escaped, which Raku accepts for
#| any non-word character.
my sub cc-char(Str:D $ch --> Str) is export(:INTERNAL) {
    return $ch if $ch ~~ /^ <[0..9 a..z A..Z]> $/;
    return '\\x20' if $ch eq ' ';
    '\\' ~ $ch;
}

#| Translate a Perl/PCRE-flavoured regular expression into the
#| equivalent Raku regex source.
#|
#| The result is meant to be used through C<< /<$translated>/ >>. It is
#| built entirely from constructs this function emits, so it carries no
#| syntax from the input into Raku's regex parser.
#|
#|     p5-to-raku('^(require)$')       # ^('require')$
#|     p5-to-raku('^[\s\*/]+')         # ^<[\s\*\/]>+
#|     p5-to-raku('a{2,3}')            # 'a' ** 2..3
#|
#| Throws C<X::TreeSitter::Regex> for anything it cannot translate
#| faithfully — backreferences, possessive quantifiers, POSIX bracket
#| classes, unknown C<(?…)> groups, unbalanced brackets.
my sub p5-to-raku(Str:D $pattern --> Str) is export(:INTERNAL) {
    my @c    = $pattern.comb;
    my Int $n = @c.elems;
    my Int $i = 0;
    my Str @out;
    my Str @lits;
    my Str @closers;

    my sub bail(Str $reason) {
        X::TreeSitter::Regex.new(
            :$pattern, :$reason, :offset($i),
        ).throw;
    }

    # Emit the pending literal run. `:split-last` peels the final
    # character off into an atom of its own, which is what a following
    # quantifier must bind to: P5 `abc*` repeats the `c`, not `abc`.
    my sub flush(Bool :$split-last = False) {
        return unless @lits;
        my Str @run = @lits;
        @lits = ();
        my Str $last = $split-last ?? @run.pop !! Str;
        @out.push(rx-literal(@run.join)) if @run;
        @out.push(rx-literal($last)) if $last.defined;
    }

    # \xHH or \x{HHHH}, already past the 'x'.
    my sub hex-escape(--> Str) {
        if $i < $n && @c[$i] eq '{' {
            $i++;
            my Str $digits = '';
            while $i < $n && @c[$i] ne '}' {
                $digits ~= @c[$i];
                $i++;
            }
            bail('unterminated \\x{…} escape') if $i >= $n;
            $i++;   # past }
            bail('empty \\x{} escape') unless $digits.chars;
            bail("\\x{{$digits}} is not hexadecimal")
                unless $digits ~~ /^ <[0..9 a..f A..F]>+ $/;
            return '\\x[' ~ $digits ~ ']';
        }
        my Str $digits = '';
        while $i < $n && $digits.chars < 2 && @c[$i] ~~ /^<[0..9 a..f A..F]>$/ {
            $digits ~= @c[$i];
            $i++;
        }
        bail('\\x needs at least one hexadecimal digit')
            unless $digits.chars;
        '\\x[' ~ $digits ~ ']';
    }

    # A [...] character class, entered with @c[$i] eq '['.
    my sub char-class(--> Str) {
        $i++;                                   # past [
        my Bool $negated = False;
        if $i < $n && @c[$i] eq '^' {
            $negated = True;
            $i++;
        }
        my Str @items;
        my Bool $first = True;
        loop {
            bail('unterminated character class') if $i >= $n;
            my Str $ch = @c[$i];

            if $ch eq ']' && !$first {
                $i++;
                last;
            }
            if $ch eq '[' && $i + 1 < $n && @c[$i + 1] eq ':' {
                bail('POSIX bracket classes ([:alpha:]) are not '
                   ~ 'supported');
            }
            $first = False;

            # A range: X-Y, where '-' is neither first nor last.
            if $ch eq '-' && @items && $i + 1 < $n && @c[$i + 1] ne ']'
               && @items.tail !~~ /^ '\\' <[dDwWsS]> $/
            {
                $i++;                            # past -
                my Str $hi = @c[$i];
                if $hi eq '\\' {
                    $i++;
                    bail('trailing backslash in character class')
                        if $i >= $n;
                    my Str $e = @c[$i];
                    $i++;
                    if %SHARED-ESCAPES{$e} {
                        bail("\\$e cannot be a range endpoint");
                    }
                    elsif $e eq 'x' {
                        @items[*-1] = @items.tail ~ '..' ~ hex-escape();
                        next;
                    }
                    else {
                        @items[*-1] = @items.tail ~ '..' ~ cc-char($e);
                        next;
                    }
                }
                $i++;
                @items[*-1] = @items.tail ~ '..' ~ cc-char($hi);
                next;
            }

            if $ch eq '\\' {
                $i++;
                bail('trailing backslash in character class')
                    if $i >= $n;
                my Str $e = @c[$i];
                $i++;
                if %SHARED-ESCAPES{$e} {
                    @items.push('\\' ~ $e);
                }
                elsif $e eq 'x' {
                    @items.push(hex-escape());
                }
                elsif $e ~~ /^ <[0..9 a..z A..Z]> $/ {
                    bail("\\$e is not supported inside a character "
                       ~ 'class');
                }
                else {
                    @items.push(cc-char($e));
                }
                next;
            }

            @items.push(cc-char($ch));
            $i++;
        }
        bail('empty character class') unless @items;
        ($negated ?? '<-[' !! '<[') ~ @items.join ~ ']>';
    }

    # {n} / {n,} / {n,m} — or a literal brace if it is not one of
    # those. Returns the Raku spelling, or the Str type object to say
    # "not a quantifier, treat the brace as a literal".
    my sub brace-quantifier(--> Str) {
        my Int $save = $i;
        $i++;                                   # past {
        my Str $body = '';
        while $i < $n && @c[$i] ne '}' {
            $body ~= @c[$i];
            $i++;
        }
        if $i >= $n || $body !~~ /^ \d+ [ ',' \d* ]? $/ {
            $i = $save;
            return Str;
        }
        $i++;                                   # past }
        my ($lo, $hi) = $body.split(',', 2);
        return " ** $lo" unless $hi.defined;
        return " ** $lo..*" unless $hi.chars;
        " ** $lo..$hi";
    }

    while $i < $n {
        my Str $ch = @c[$i];

        if $ch eq '\\' {
            $i++;
            bail('trailing backslash') if $i >= $n;
            my Str $e = @c[$i];
            $i++;
            if %SHARED-ESCAPES{$e} {
                flush();
                @out.push('\\' ~ $e);
            }
            elsif $e eq 'b' { flush(); @out.push('<|w>') }
            elsif $e eq 'B' { flush(); @out.push('<!|w>') }
            elsif $e eq 'A' { flush(); @out.push('^') }
            elsif $e eq 'z' || $e eq 'Z' { flush(); @out.push('$') }
            elsif $e eq 'x' { flush(); @out.push(hex-escape()) }
            elsif $e ~~ /^ \d $/ {
                bail('backreferences are not supported');
            }
            elsif $e ~~ /^ <[a..z A..Z]> $/ {
                bail("\\$e is not supported");
            }
            else {
                @lits.push($e);
            }
            next;
        }

        if $ch eq '[' {
            flush();
            @out.push(char-class());
            next;
        }

        if $ch eq '(' {
            flush();
            if $i + 1 < $n && @c[$i + 1] eq '?' {
                my Str $rest = @c[$i .. $n - 1].join;
                if $rest.starts-with('(?:') {
                    @out.push('[');
                    @closers.push(']');
                    $i += 3;
                }
                elsif $rest.starts-with('(?=') {
                    @out.push('<?before ');
                    @closers.push('>');
                    $i += 3;
                }
                elsif $rest.starts-with('(?!') {
                    @out.push('<!before ');
                    @closers.push('>');
                    $i += 3;
                }
                elsif $rest.starts-with('(?<=') {
                    @out.push('<?after ');
                    @closers.push('>');
                    $i += 4;
                }
                elsif $rest.starts-with('(?<!') {
                    @out.push('<!after ');
                    @closers.push('>');
                    $i += 4;
                }
                elsif $rest ~~ /^ '(?' 'P'? '<' $<name> = [ <[A..Za..z_]> \w* ] '>' / {
                    @out.push('$<' ~ $<name> ~ '>=[');
                    @closers.push(']');
                    $i += $/.chars;
                }
                elsif $rest ~~ /^ '(?i)' / {
                    @out.push(':i ');
                    $i += 4;
                }
                elsif $rest ~~ /^ '(?i:' / {
                    @out.push(':i[');
                    @closers.push(']');
                    $i += 4;
                }
                else {
                    bail('unsupported (?…) group');
                }
            }
            else {
                @out.push('(');
                @closers.push(')');
                $i++;
            }
            next;
        }

        if $ch eq ')' {
            flush();
            bail('unbalanced )') unless @closers;
            @out.push(@closers.pop);
            $i++;
            next;
        }

        if $ch eq '|' {
            flush();
            # Raku's bare | is longest-token alternation; || is
            # left-to-right, which is what Perl means.
            @out.push('||');
            $i++;
            next;
        }

        if $ch eq '.' {
            flush();
            # Perl's . excludes newline unless /s; Raku's . includes
            # it and \N is the exclusive one.
            @out.push('\\N');
            $i++;
            next;
        }

        if $ch eq '^' || $ch eq '$' {
            flush();
            @out.push($ch);
            $i++;
            next;
        }

        if $ch eq '*' || $ch eq '+' || $ch eq '?' {
            flush(:split-last);
            bail("nothing for '$ch' to repeat") unless @out;
            $i++;
            if $i < $n && @c[$i] eq '?' {
                @out.push($ch ~ '?');           # lazy
                $i++;
            }
            elsif $i < $n && @c[$i] eq '+' {
                bail('possessive quantifiers are not supported');
            }
            else {
                @out.push($ch);
            }
            next;
        }

        if $ch eq '{' {
            my Str $quant = brace-quantifier();
            if $quant.defined {
                # Split the pending literal run only once we know the
                # brace really was a quantifier: `a{x}` keeps its brace
                # as an ordinary character.
                flush(:split-last);
                bail('nothing for {…} to repeat') unless @out;
                @out.push($quant);
            }
            else {
                @lits.push($ch);
                $i++;
            }
            next;
        }

        @lits.push($ch);
        $i++;
    }

    flush();
    bail('unbalanced (') if @closers;
    @out.elems ?? @out.join !! "''";
}

# ====================================================================
# Predicate structures
# ====================================================================

#| One argument of a predicate or directive: either a capture name or a
#| string literal, per C<$.kind>.
#|
#|     $arg.kind    # PREDICATE_STEP_CAPTURE or PREDICATE_STEP_STRING
#|     $arg.value   # 'name'                 or 'constructor'
#|
#| Capture values are the bare name, without the leading C<@>.
class TreeSitter::Native::Query::Arg {
    has PredicateStepType $.kind is required;
    has Str $.value is required;

    #| C<True> for a capture argument.
    method is-capture(--> Bool) { $!kind == PREDICATE_STEP_CAPTURE }

    multi method Str(TreeSitter::Native::Query::Arg:D: --> Str) {
        self.is-capture ?? '@' ~ $!value !! '"' ~ $!value ~ '"';
    }
    multi method gist(TreeSitter::Native::Query::Arg:D: --> Str) { self.Str }
}

#| One C<(#name …)> clause of a pattern, decoded from tree-sitter's
#| flat step list.
#|
#|     my $p = $query.pattern-predicates(0)[0];
#|     say $p.name;                    # not-eq?
#|     say $p.args>>.Str.join(' ');    # @name "constructor"
#|     say $p.is-directive;            # False
class TreeSitter::Native::Query::Predicate {
    #| The clause name with its C<?> or C<!> suffix and without the
    #| leading C<#>: C<'not-eq?'>, C<'strip!'>.
    has Str $.name is required;

    #| The arguments, in order, as C<Arg> objects.
    has TreeSitter::Native::Query::Arg @.args;

    #| Which pattern this clause belongs to.
    has UInt $.pattern-index is required;

    #| C<True> for a C<!>-suffixed directive, which this module parses
    #| and exposes but never applies.
    method is-directive(--> Bool) { $!name.ends-with('!') }

    #| C<True> when this module evaluates the clause when filtering.
    #| C<False> for directives, and for unknown predicates admitted by
    #| C<:lenient>.
    has Bool $.evaluated = False;

    multi method Str(TreeSitter::Native::Query::Predicate:D: --> Str) {
        '(#' ~ $!name ~ (@!args ?? ' ' ~ @!args.map(*.Str).join(' ') !! '')
             ~ ')';
    }
    multi method gist(TreeSitter::Native::Query::Predicate:D: --> Str) { self.Str }
}

# ====================================================================
# Match
# ====================================================================

#| One match: which pattern produced it, and what it captured.
#|
#| Not exported — Raku's core already binds C<Match> — so name it in
#| full as C<TreeSitter::Native::Query::Match> on the rare occasion you
#| need the type rather than an instance.
#|
#|     for $q.matches($root) -> $m {
#|         say $m.pattern-index;
#|         say $m.captures.keys.sort;         # (definition.function name)
#|         say $m.captures<name>.text;
#|         say $m.nodes('doc').map(*.text);   # every @doc node
#|     }
class TreeSitter::Native::Query::Match {
    #| Index of the pattern within the query that produced this match.
    has UInt $.pattern-index is required;

    #| Every capture, in tree-sitter's order, as C<name => Node> pairs.
    #| A capture name may appear more than once — C<(comment)* @doc>
    #| captures one node per comment — which is why this is a list and
    #| not a hash.
    has @.entries;

    #| The query this match came from.
    has TreeSitter::Native::Query $.query is required;

    #| C<name => Node> for every capture, keeping the B<first> node
    #| when a name was captured more than once. The convenient view;
    #| use C<.nodes> or C<.entries> when duplicates matter.
    method captures(--> Hash) {
        my %h;
        for @!entries -> $pair {
            %h{$pair.key} = $pair.value
                unless %h{$pair.key}:exists;
        }
        %h;
    }

    #| Every node captured under C<$name>, in order. Empty when the
    #| match has no such capture.
    method nodes(Str:D $name --> List) {
        @!entries.grep({ .key eq $name }).map({ .value }).List;
    }

    #| The first node captured under C<$name>, or the C<Node> type
    #| object.
    method node(Str:D $name --> TreeSitter::Native::Node) {
        self.nodes($name).head // TreeSitter::Native::Node;
    }

    #| The C<!>-directives attached to this match's pattern. Parsed,
    #| never applied — see the DESCRIPTION.
    method directives(--> List) {
        $!query.pattern-directives($!pattern-index);
    }

    #| Every C<(#…)> clause attached to this match's pattern,
    #| directives included.
    method predicates(--> List) {
        $!query.pattern-predicates($!pattern-index);
    }

    multi method gist(TreeSitter::Native::Query::Match:D: --> Str) {
        "Match[pattern $!pattern-index] "
        ~ @!entries.map({ '@' ~ .key ~ '=' ~ .value.gist }).join(' ');
    }
}

# ====================================================================
# Query cursor
# ====================================================================

#| Execution state for one query over one node: tree-sitter's
#| C<TSQueryCursor> plus the reusable match record it fills in.
#|
#| C<Query.matches> creates, drives and disposes one of these for you.
#| Reach for it directly only when you want to drive the iteration
#| yourself — and remember that C<.next-match> returns raw matches, with
#| no predicate filtering; C<Query.accepts> is the filter.
#|
#|     my $c = $query.cursor($root, :start-byte(0), :end-byte(4096));
#|     LEAVE $c.dispose;
#|     while $c.next-match -> $m {
#|         next unless $query.accepts($m);
#|         …
#|     }
#|
#| Not exported (Raku's core binds C<Cursor>); its full name is
#| C<TreeSitter::Native::Query::Cursor>.
class TreeSitter::Native::Query::Cursor {
    has TSQueryCursor $!handle;
    has TSQueryMatch  $!record;

    #| The query being run.
    has TreeSitter::Native::Query $.query is required;

    #| The node it is being run over.
    has TreeSitter::Native::Node $.node is required;

    # Set when the caller asked for an empty byte range: see `new`.
    has Bool $!exhausted = False;

    submethod BUILD(
        TSQueryCursor :$handle,
        TSQueryMatch  :$record,
        Bool :$exhausted = False,
        :$!query,
        :$!node,
    ) {
        $!handle    = $handle;
        $!record    = $record;
        $!exhausted = $exhausted;
    }

    #| Create and start a cursor. C<:start-byte>/C<:end-byte> restrict
    #| matching to a byte range of the source — both are byte offsets,
    #| per the byte doctrine — and default to the whole node.
    method new(
        TreeSitter::Native::Query:D :$query!,
        TreeSitter::Native::Node:D  :$node!,
        UInt :$start-byte,
        UInt :$end-byte,
    ) {
        my TSQueryCursor $handle = tsn_query_cursor_new();
        unless $handle.defined {
            die "TreeSitter::Native::Query::Cursor: tree-sitter "
              ~ "refused to allocate a query cursor (out of memory).";
        }
        my TSQueryMatch $record = tsn_match_new();
        unless $record.defined {
            tsn_query_cursor_delete($handle);
            die "TreeSitter::Native::Query::Cursor: could not "
              ~ "allocate a match record (out of memory).";
        }

        my Bool $empty = False;
        if $start-byte.defined || $end-byte.defined {
            my UInt $from = $start-byte // 0;
            my UInt $to   = $end-byte // $node.tree.bytes.elems;
            if $from > $to {
                tsn_match_delete($record);
                tsn_query_cursor_delete($handle);
                die "TreeSitter::Native::Query::Cursor: byte range "
                  ~ "$from..$to was rejected; the start must not be "
                  ~ "past the end.";
            }
            # An empty range is handled on this side of the boundary.
            # tree-sitter reads an end byte of 0 as "no limit", so
            # asking it for 0..0 would quietly return everything —
            # the exact opposite of what the caller asked for.
            $empty = $from == $to;
            unless $empty {
                unless tsn_query_cursor_set_byte_range(
                           $handle, $from, $to) {
                    tsn_match_delete($record);
                    tsn_query_cursor_delete($handle);
                    die "TreeSitter::Native::Query::Cursor: "
                      ~ "tree-sitter refused the byte range "
                      ~ "$from..$to.";
                }
            }
        }

        # Exec even for an empty range: a cursor that has never been
        # exec'd has no query to advance over, and next_match would
        # walk a null pointer. The Raku-side flag is what makes the
        # iteration empty.
        tsn_query_cursor_exec($handle, $query.handle, $node.buf);
        self.bless(:$handle, :$record, :$query, :$node,
                   :exhausted($empty));
    }

    method !live(--> TSQueryCursor:D) {
        if $!node.tree.disposed {
            die "TreeSitter::Native::Query::Cursor: the tree this "
              ~ "cursor is querying has been disposed.";
        }
        $!handle // die "TreeSitter::Native::Query::Cursor: this "
                      ~ "cursor has already been disposed.";
    }

    #| True once C<.dispose> (or C<DESTROY>) has run.
    method disposed(--> Bool) { !$!handle.defined }

    #| The next raw match, or the C<Match> type object when the
    #| iteration is exhausted. B<No predicate filtering>: pass the
    #| result through C<Query.accepts> if you want that.
    #|
    #| Captures are copied out immediately, because tree-sitter
    #| invalidates the previous match's capture array on every call.
    method next-match(--> TreeSitter::Native::Query::Match) {
        my TSQueryCursor $handle = self!live;
        return TreeSitter::Native::Query::Match if $!exhausted;
        return TreeSitter::Native::Query::Match
            unless tsn_query_cursor_next_match($handle, $!record);

        my UInt $pattern = tsn_match_pattern_index($!record).Int;
        my UInt $count   = tsn_match_capture_count($!record).Int;
        my @entries;
        for ^$count -> UInt $index {
            my uint32 $capture-id;
            my TSNodeBuf $buf .= new;
            next unless
                tsn_match_capture($!record, $index, $capture-id, $buf);
            my Str $name = $!query.capture-name($capture-id.Int);
            next unless $name.defined;
            @entries.push($name => wrap-node($buf, $!node.tree));
        }
        TreeSitter::Native::Query::Match.new(
            :pattern-index($pattern), :@entries, :query($!query),
        );
    }

    #| Free the cursor and its match record. Idempotent.
    method dispose(--> Nil) {
        my TSQueryCursor $handle = $!handle;
        my TSQueryMatch  $record = $!record;
        $!handle = TSQueryCursor;
        $!record = TSQueryMatch;
        tsn_match_delete($record) if $record.defined;
        tsn_query_cursor_delete($handle) if $handle.defined;
    }

    submethod DESTROY() { self.dispose }
}

# ====================================================================
# Predicate evaluation helpers
# ====================================================================
#
# Text comparison is done on BYTES, via a latin-1 decode: every byte
# value maps to exactly one codepoint, so Str equality over the result
# is byte equality, and it works on source that is not valid UTF-8. The
# regex predicate is the exception — a regex needs real text — and
# falls back to latin-1 only when the bytes will not decode as UTF-8.

my sub byte-key-of-node(TreeSitter::Native::Node:D $node --> Str) {
    $node.byte-slice.decode('latin-1');
}

my sub byte-key-of-str(Str:D $text --> Str) {
    $text.encode('utf-8').decode('latin-1');
}

my sub text-of-node(TreeSitter::Native::Node:D $node --> Str) {
    (try $node.text) // $node.byte-slice.decode('latin-1');
}

# `#eq? @a "literal"` and its negation: EVERY node captured under $name
# must (not) have that text. No nodes means vacuously true, which is
# the rule tree-sitter's own bindings use.
my sub eq-literal(%by-name, Str $name, Str $key, Bool $negate --> Bool) {
    for (%by-name{$name} // []).list -> $node {
        my Bool $same = byte-key-of-node($node) eq $key;
        return False if $same == $negate;
    }
    True;
}

# `#eq? @a @b`: the captures are zipped pairwise, which is what
# tree-sitter's own bindings do when either name captured more than one
# node.
my sub eq-captures(%by-name, Str $left, Str $right,
                   Bool $negate --> Bool) {
    my @l = (%by-name{$left}  // []).list;
    my @r = (%by-name{$right} // []).list;
    for ^(@l.elems min @r.elems) -> $i {
        my Bool $same =
            byte-key-of-node(@l[$i]) eq byte-key-of-node(@r[$i]);
        return False if $same == $negate;
    }
    True;
}

my sub match-nodes(%by-name, Str $name, $rx, Bool $negate --> Bool) {
    for (%by-name{$name} // []).list -> $node {
        my Bool $hit = so (text-of-node($node) ~~ $rx);
        return False if $hit == $negate;
    }
    True;
}

my sub any-of-nodes(%by-name, Str $name, Set $set,
                    Bool $negate --> Bool) {
    for (%by-name{$name} // []).list -> $node {
        my Bool $hit = $set{byte-key-of-node($node)}.so;
        return False if $hit == $negate;
    }
    True;
}

# Enum lookups by C value. `QueryErrorKind(7)` does NOT do this — an
# out-of-range value comes back as a plain Int, which would then fail
# the enum type constraint somewhere less obvious.
my constant @ERROR-KINDS =
    QUERY_ERROR_NONE,      QUERY_ERROR_SYNTAX,
    QUERY_ERROR_NODE_TYPE, QUERY_ERROR_FIELD,
    QUERY_ERROR_CAPTURE,   QUERY_ERROR_STRUCTURE,
    QUERY_ERROR_LANGUAGE,  QUERY_ERROR_PREDICATE;

my sub error-kind-for(Int $code --> QueryErrorKind) {
    @ERROR-KINDS[$code] // QUERY_ERROR_SYNTAX;
}

my constant @STEP-KINDS =
    PREDICATE_STEP_DONE, PREDICATE_STEP_CAPTURE, PREDICATE_STEP_STRING;

my sub step-kind-for(Int $code --> PredicateStepType) {
    @STEP-KINDS[$code] // PREDICATE_STEP_DONE;
}

# ====================================================================
# Query
# ====================================================================

#| A compiled tree-sitter query.
#|
#|     my $q = Query.new('rust', '(function_item name: (identifier) @fn)');
#|     say $q.pattern-count;      # 1
#|     say $q.capture-names;      # (fn)
#|
#|     for $q.matches($tree.root-node) -> $m {
#|         say $m.captures<fn>.text;
#|     }
#|
#| Compiling is the expensive part — a big C<tags.scm> is hundreds of
#| patterns — so build a query once and reuse it across files. Queries
#| are tied to the grammar they were compiled against, not to any
#| particular tree.
class TreeSitter::Native::Query is export {
    has TSQuery $!handle;

    #| The grammar this query was compiled against.
    has TSLanguage $.language is required;

    #| The query source, as given.
    has Str $.source is required;

    #| Whether unknown predicates were admitted rather than rejected.
    has Bool $.lenient is required;

    has Str @!capture-names;
    has @!predicates;       # pattern index → List[Predicate]
    has @!filters;          # pattern index → List[Callable]

    submethod BUILD(
        TSQuery :$handle,
        :$!language,
        :$!source,
        :$!lenient,
    ) {
        $!handle = $handle;
    }

    #| Compile C<$source> against C<$language>, which may be a grammar
    #| name or a C<TSLanguage>.
    #|
    #|     my $q = Query.new('python', tags-query('python'));
    #|     my $q = Query.new(language('python'), $scm);
    #|
    #| Throws C<X::TreeSitter::Query> — carrying the error kind and the
    #| BYTE offset into C<$source> — if tree-sitter rejects the query,
    #| or if it names a predicate this module will not evaluate. See
    #| C<:lenient> in the DESCRIPTION.
    method new($language, Str:D $source, Bool :$lenient = False) {
        my TSLanguage $lang = do given $language {
            when TSLanguage { $_ }
            # The sub imported from TreeSitter::Native::Languages, not
            # this class's own `language` accessor: a bare name here is
            # a sub call.
            when Str        { language($_) }
            default {
                die "TreeSitter::Native::Query.new expects a grammar "
                  ~ "name or a TSLanguage, not a {$language.^name}.";
            }
        };

        my Blob $bytes = $source.encode('utf-8');
        my uint32 ($error-offset, $error-type);
        my TSQuery $handle = tsn_query_new(
            $lang, $bytes, $bytes.elems, $error-offset, $error-type,
        );
        unless $handle.defined {
            X::TreeSitter::Query.new(
                kind   => error-kind-for($error-type.Int),
                offset => $error-offset.Int,
                :$source,
            ).throw;
        }

        my $query = self.bless(
            :$handle, :language($lang), :$source, :$lenient,
        );
        # Anything that goes wrong from here on has to free the query
        # before it propagates: the object exists but nothing is
        # holding it, so DESTROY would be the only other route and it
        # is not guaranteed to run promptly. Written as an explicit
        # CATCH rather than a LEAVE phaser because Rakudo runs a LEAVE
        # on every exit from the enclosing block, including exits that
        # happen before the phaser's own declaration was reached.
        {
            $query!decode-captures;
            $query!decode-predicates;
            CATCH {
                default {
                    $query.dispose;
                    .rethrow;
                }
            }
        }
        $query;
    }

    method !live(--> TSQuery:D) {
        $!handle // die "TreeSitter::Native::Query: this query has "
                      ~ "already been disposed.";
    }

    #| The underlying C<TSQuery>. For
    #| C<TreeSitter::Native::Query::Cursor>, which has to hand it to
    #| the shim; there is nothing useful to do with it otherwise.
    method handle(--> TSQuery) { self!live }

    #| True once C<.dispose> (or C<DESTROY>) has run.
    method disposed(--> Bool) { !$!handle.defined }

    # --- introspection ----------------------------------------------

    #| How many patterns the query source compiled to.
    method pattern-count(--> UInt) {
        tsn_query_pattern_count(self!live).Int;
    }

    #| How many distinct capture names the query uses.
    method capture-count(--> UInt) {
        tsn_query_capture_count(self!live).Int;
    }

    #| How many distinct string literals the query uses.
    method string-count(--> UInt) {
        tsn_query_string_count(self!live).Int;
    }

    #| Every capture name, indexed by capture id.
    method capture-names(--> List) { @!capture-names.List }

    #| The capture name with id C<$id>, or the C<Str> type object.
    method capture-name(UInt:D $id --> Str) { @!capture-names[$id] }

    #| Byte offset of pattern C<$index> within the query source.
    method start-byte-for-pattern(UInt:D $index --> UInt) {
        tsn_query_start_byte_for_pattern(self!live, $index).Int;
    }

    #| Every C<(#…)> clause attached to pattern C<$index>, predicates
    #| and directives alike, in source order.
    method pattern-predicates(UInt:D $index --> List) {
        (@!predicates[$index] // []).List;
    }

    #| Just the C<!>-directives of pattern C<$index> — the clauses this
    #| module exposes but does not apply.
    method pattern-directives(UInt:D $index --> List) {
        self.pattern-predicates($index).grep(*.is-directive).List;
    }

    # --- decoding ---------------------------------------------------

    method !decode-captures(--> Nil) {
        my TSQuery $handle = self!live;
        my UInt $count = tsn_query_capture_count($handle).Int;
        @!capture-names = (^$count).map(-> UInt $id {
            my uint32 $len;
            tsn-borrowed-str(
                tsn_query_capture_name_for_id($handle, $id, $len),
                $len.Int,
            ) // '';
        });
    }

    method !string-value(UInt:D $id --> Str) {
        my uint32 $len;
        tsn-borrowed-str(
            tsn_query_string_value_for_id(self!live, $id, $len),
            $len.Int,
        ) // '';
    }

    method !decode-predicates(--> Nil) {
        my TSQuery $handle = self!live;
        my UInt $patterns = tsn_query_pattern_count($handle).Int;
        @!predicates = ();
        @!filters    = ();

        for ^$patterns -> UInt $pattern {
            my UInt $steps =
                tsn_query_predicate_step_count($handle, $pattern).Int;
            my @clauses;
            my @args;
            my Str $name;
            my Bool $started = False;

            for ^$steps -> UInt $step {
                my uint32 ($type, $value);
                next unless tsn_query_predicate_step(
                    $handle, $pattern, $step, $type, $value);
                my PredicateStepType $kind = step-kind-for($type.Int);

                if $kind == PREDICATE_STEP_DONE {
                    @clauses.push(
                        self!build-clause($pattern, $name, @args))
                        if $started;
                    $name    = Str;
                    @args    = ();
                    $started = False;
                    next;
                }

                my Str $text = $kind == PREDICATE_STEP_CAPTURE
                    ?? (@!capture-names[$value.Int] // '')
                    !! self!string-value($value.Int);

                unless $started {
                    # The first step of a clause is always the
                    # predicate's own name, as a string literal.
                    if $kind != PREDICATE_STEP_STRING {
                        self!predicate-error($pattern,
                            'a predicate must start with its name');
                    }
                    $name    = $text;
                    $started = True;
                    next;
                }
                @args.push(
                    TreeSitter::Native::Query::Arg.new(
                        :$kind, :value($text)));
            }
            # tree-sitter always terminates the last clause with a DONE
            # step; this is belt and braces for a truncated list.
            @clauses.push(self!build-clause($pattern, $name, @args))
                if $started;

            @!predicates[$pattern] = @clauses.List;
        }
    }

    method !predicate-error(UInt $pattern, Str $detail) {
        X::TreeSitter::Query.new(
            kind   => QUERY_ERROR_PREDICATE,
            offset => self.start-byte-for-pattern($pattern),
            source => $!source,
            :$detail,
        ).throw;
    }

    # Turn one decoded clause into a Predicate, and — for the six
    # predicates this module evaluates — into a filter closure.
    method !build-clause(UInt $pattern, Str $name, @args) {
        # `// ''` rather than a type check: a clause with no name at
        # all cannot come out of tree-sitter, but this runs over data
        # from a C library and an unnamed clause must produce an
        # exception with an offset in it, not a "requires an instance"
        # from .ends-with.
        my Str $spelled    = $name // '';
        my Bool $directive = $spelled.ends-with('!');
        my Bool $evaluated = False;

        unless $directive {
            $evaluated = self!compile-filter($pattern, $spelled, @args);
        }

        TreeSitter::Native::Query::Predicate.new(
            :name($spelled),
            :args(@args.List),
            :pattern-index($pattern),
            :$evaluated,
        );
    }

    # Returns True if a filter was installed for this clause.
    method !compile-filter(UInt $pattern, Str $name, @args --> Bool) {
        my Str $spelled = $name // '';
        my Str $base    = $spelled.subst(/'?' $/, '');
        my Bool $negate = so $base.starts-with('not-');
        my Str $core    = $negate ?? $base.substr(4) !! $base;

        unless $spelled.ends-with('?')
               && ($core eq 'eq' || $core eq 'match'
                   || $core eq 'any-of')
        {
            return False if $!lenient;
            self!predicate-error($pattern,
                "unsupported predicate (#$name …). This binding "
              ~ "evaluates #eq?, #not-eq?, #match?, #not-match?, "
              ~ "#any-of? and #not-any-of?; pass :lenient to accept "
              ~ "and ignore the rest.");
        }

        unless @args && @args[0].is-capture {
            self!predicate-error($pattern,
                "(#$name …) needs a capture as its first argument");
        }
        my Str $subject = @args[0].value;

        given $core {
            when 'eq' {
                unless @args.elems == 2 {
                    self!predicate-error($pattern,
                        "(#$name …) takes exactly two arguments, "
                      ~ "got {@args.elems}");
                }
                my $other = @args[1];
                if $other.is-capture {
                    my Str $rhs = $other.value;
                    @!filters[$pattern].push(-> %by-name {
                        eq-captures(%by-name, $subject, $rhs, $negate);
                    });
                }
                else {
                    my Str $key = byte-key-of-str($other.value);
                    @!filters[$pattern].push(-> %by-name {
                        eq-literal(%by-name, $subject, $key, $negate);
                    });
                }
            }
            when 'match' {
                unless @args.elems == 2 && !@args[1].is-capture {
                    self!predicate-error($pattern,
                        "(#$name …) takes a capture and a string "
                      ~ "pattern");
                }
                my Str $translated;
                {
                    $translated = p5-to-raku(@args[1].value);
                    CATCH {
                        when X::TreeSitter::Regex {
                            self!predicate-error($pattern, .message);
                        }
                    }
                }
                my $rx = rx/<$translated>/;
                @!filters[$pattern].push(-> %by-name {
                    match-nodes(%by-name, $subject, $rx, $negate);
                });
            }
            when 'any-of' {
                unless @args.elems >= 2
                       && @args[1..*].grep(*.is-capture).elems == 0
                {
                    self!predicate-error($pattern,
                        "(#$name …) takes a capture followed by one "
                      ~ "or more string literals");
                }
                my $set = @args[1..*].map({
                    byte-key-of-str(.value)
                }).Set;
                @!filters[$pattern].push(-> %by-name {
                    any-of-nodes(%by-name, $subject, $set, $negate);
                });
            }
        }
        True;
    }

    # --- matching ---------------------------------------------------

    #| A cursor over C<$node>, for driving the iteration yourself.
    #| C<:start-byte>/C<:end-byte> restrict matching to a byte range.
    method cursor(TreeSitter::Native::Node:D $node,
                  UInt :$start-byte, UInt :$end-byte
                  --> TreeSitter::Native::Query::Cursor) {
        self!live;
        TreeSitter::Native::Query::Cursor.new(
            :query(self), :$node, :$start-byte, :$end-byte,
        );
    }

    #| C<True> if C<$match> satisfies every predicate on its pattern.
    #| C<Query.matches> applies this for you; it is public so that a
    #| hand-driven cursor loop can too.
    method accepts(TreeSitter::Native::Query::Match:D $match --> Bool) {
        my @filters = (@!filters[$match.pattern-index] // []).List;
        return True unless @filters;
        my %by-name;
        for $match.entries -> $pair {
            %by-name{$pair.key}.push($pair.value);
        }
        for @filters -> &filter {
            return False unless filter(%by-name);
        }
        True;
    }

    #| Every match of this query inside C<$node>, as a lazy C<Seq>,
    #| with predicates applied.
    #|
    #|     for $q.matches($tree.root-node) -> $m { … }
    #|
    #| C<:start-byte>/C<:end-byte> restrict matching to a byte range of
    #| the source, which is how you query one function of a large file
    #| without re-parsing it:
    #|
    #|     $q.matches($root, :start-byte($fn.start-byte),
    #|                       :end-byte($fn.end-byte));
    #|
    #| Both are byte offsets. An empty range (C<:start-byte> equal to
    #| C<:end-byte>) yields nothing, which needs saying because
    #| tree-sitter itself reads an end byte of 0 as "no limit" and
    #| would hand back the whole file; that quirk is normalised here. A
    #| range whose start is past its end is a caller mistake and
    #| throws.
    #|
    #| The underlying cursor is disposed when the C<Seq> is exhausted.
    #| Abandoning a partly-consumed C<Seq> leaves it to the garbage
    #| collector instead, which is safe but not prompt; use
    #| C<.cursor> with a C<LEAVE> if that matters.
    method matches(TreeSitter::Native::Node:D $node,
                   UInt :$start-byte, UInt :$end-byte --> Seq) {
        my $cursor = self.cursor($node, :$start-byte, :$end-byte);
        my $query  = self;
        gather {
            LEAVE $cursor.dispose;
            loop {
                my $match = $cursor.next-match;
                last unless $match.defined;
                take $match if $query.accepts($match);
            }
        }
    }

    #| Every capture of every accepted match, flattened into a lazy
    #| C<Seq> of C<name => Node> pairs — the convenient shape when you
    #| do not care which pattern or which match a capture came from.
    #|
    #|     my %by-name = $q.captures($root).classify(*.key);
    method captures(TreeSitter::Native::Node:D $node,
                    UInt :$start-byte, UInt :$end-byte --> Seq) {
        self.matches($node, :$start-byte, :$end-byte)
            .map({ .entries.Slip });
    }

    #| Free the query. Idempotent. Cursors already running over it stop
    #| being usable.
    method dispose(--> Nil) {
        my TSQuery $handle = $!handle;
        $!handle = TSQuery;
        tsn_query_delete($handle) if $handle.defined;
    }

    submethod DESTROY() { self.dispose }

    multi method gist(TreeSitter::Native::Query:D: --> Str) {
        self.disposed
            ?? 'TreeSitter::Native::Query(disposed)'
            !! "TreeSitter::Native::Query({self.pattern-count} patterns)";
    }
}
