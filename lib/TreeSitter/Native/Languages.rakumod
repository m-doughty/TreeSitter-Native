use v6.d;

unit module TreeSitter::Native::Languages;

use TreeSitter::Native::FFI;

=begin pod

=head1 NAME

TreeSitter::Native::Languages - the nine bundled grammars, by name

=head1 SYNOPSIS

    use TreeSitter::Native::Languages;

    say languages;                  # (c cpp go java javascript python
                                    #  rust tsx typescript)
    say language-abi('python');     # 15

    my $lang = language('rust');    # a TSLanguage, ready for a Parser

    # The grammar authors' own queries, vendored at the pinned tag.
    my $tags = tags-query('go');
    my $hl   = highlights-query('go');
    my $loc  = query-source('typescript', 'locals');

=head1 DESCRIPTION

Nine grammars are linked into the shared library — there is no dynamic
grammar loading, and no C<tree-sitter-cli> at runtime. This module is
the map from a name to the compiled grammar, and from a name to the
C<.scm> query files that grammar ships.

The queries are vendored in this distribution's C<resources/>, copied
verbatim from each grammar repository at the tag pinned in
C<SOURCE_PINS>. They are MIT-licensed by their authors; see
C<resources/licenses/>. Reading them needs no native library at all,
which is what makes the query surface testable offline.

There is deliberately B<no Raku grammar>: no usable tree-sitter grammar
for Raku exists at the time of writing. That is a limitation of the
ecosystem, not an omission here.

=end pod

# The nine names, and the getter that returns each grammar. Sorted so
# `languages()` and every "valid names are…" message read the same way
# every time. tsx and typescript are separate grammars from one
# repository, not aliases: TSX and TypeScript disagree about `<T>`.
my constant %GETTERS = %(
    'c'          => &tsn_lang_c,
    'cpp'        => &tsn_lang_cpp,
    'go'         => &tsn_lang_go,
    'java'       => &tsn_lang_java,
    'javascript' => &tsn_lang_javascript,
    'python'     => &tsn_lang_python,
    'rust'       => &tsn_lang_rust,
    'tsx'        => &tsn_lang_tsx,
    'typescript' => &tsn_lang_typescript,
);

my constant @NAMES = %GETTERS.keys.sort.List;

# Which .scm files each grammar ships, mirroring META6.json's resources
# list. Hard-coded rather than discovered: %?RESOURCES is a lookup
# table, not a directory, and a typo'd kind should produce "python has
# highlights, tags" rather than a path that does not exist.
my constant %QUERY-KINDS = %(
    'c'          => <highlights tags>,
    'cpp'        => <highlights injections tags>,
    'go'         => <highlights tags>,
    'java'       => <highlights tags>,
    'javascript' => <highlights highlights-jsx highlights-params
                     injections locals tags>,
    'python'     => <highlights tags>,
    'rust'       => <highlights injections tags>,
    'tsx'        => <highlights locals tags>,
    'typescript' => <highlights locals tags>,
);

#| The names of every bundled grammar, sorted.
#|
#|     for languages() -> $name {
#|         say "$name: ABI {language-abi($name)}";
#|     }
sub languages(--> List) is export { @NAMES }

#| True if C<$name> is a bundled grammar. Cheaper and quieter than
#| catching the exception from C<language>.
sub is-language(Str $name --> Bool) is export {
    # Parenthesised: the :exists adverb binds to the whole infix
    # expression otherwise, and `&&` takes no adverbs.
    $name.defined && (%GETTERS{$name}:exists);
}

#| The compiled grammar called C<$name>, as a C<TSLanguage> ready to
#| hand to C<Parser.set-language> or C<Query.new>.
#|
#| Dies listing every valid name if there is no such grammar — the
#| whole list, because the caller is usually a config file or a file
#| extension map and "which ones ARE there?" is the next question.
#|
#|     my $lang = language('cpp');
#|
#| Repeated calls return the same C<TSLanguage> object, not merely one
#| with the same address; the grammars are immortal static data and
#| there is nothing to free.
# File-scoped rather than `state` inside `language`. A `state $lock =
# Lock.new` declared after that sub's argument check would never be
# initialised if the very first call to the sub is a failing one: the
# die jumps past the declaration, and the state slot stays undefined
# for every later call. The first thing t/08 does is ask for a grammar
# that does not exist, which is exactly that case.
my %LANGUAGE-CACHE;
my $LANGUAGE-LOCK = Lock.new;

sub language(Str $name --> TSLanguage) is export {
    unless is-language($name) {
        die "TreeSitter::Native: no bundled grammar named "
          ~ "'{$name // '<undefined>'}'. Valid names are: "
          ~ @NAMES.join(', ') ~ '. (There is no Raku grammar: no '
          ~ 'usable tree-sitter grammar for Raku exists yet.)';
    }
    $LANGUAGE-LOCK.protect: {
        %LANGUAGE-CACHE{$name} //= %GETTERS{$name}();
    }
}

#| The language ABI version the named grammar declares. The bundled
#| runtime accepts anything from C<tsn_min_compatible_abi> to
#| C<tsn_runtime_abi_version> inclusive; the bundled grammars sit at 14
#| and 15.
sub language-abi(Str $name --> Int) is export {
    tsn_language_abi(language($name)).Int;
}

#| The text of one of a grammar's vendored query files.
#|
#| C<$kind> is the C<.scm> basename without its extension — C<'tags'>,
#| C<'highlights'>, C<'locals'>, C<'injections'>, and for javascript
#| also C<'highlights-jsx'> and C<'highlights-params'>. Not every
#| grammar ships every kind; C<query-kinds> says which.
#|
#|     my $q = Query.new('python', query-source('python', 'tags'));
#|
#| Dies listing the kinds that grammar does ship if C<$kind> is not one
#| of them.
sub query-source(Str $name, Str $kind --> Str) is export {
    my @kinds = query-kinds($name);   # validates $name for us
    unless $kind.defined && @kinds.first($kind).defined {
        die "TreeSitter::Native: the '$name' grammar ships no "
          ~ "'{$kind // '<undefined>'}' query. It ships: "
          ~ @kinds.join(', ') ~ '.';
    }
    my Str $key = "queries/$name/$kind.scm";
    my $res     = %?RESOURCES{$key};
    unless $res.defined && $res.IO.f {
        die "TreeSitter::Native: the vendored query '$key' is missing "
          ~ "from this installation's resources. Reinstall the "
          ~ "distribution (zef install --force-install "
          ~ "TreeSitter::Native).";
    }
    $res.IO.slurp;
}

#| The query kinds C<$name> ships, sorted. Dies for an unknown grammar,
#| with the same message C<language> gives.
sub query-kinds(Str $name --> List) is export {
    unless is-language($name) {
        # Reuse language()'s message verbatim rather than paraphrasing
        # it; there is one right answer to "what are the valid names".
        language($name);
    }
    %QUERY-KINDS{$name}.sort.List;
}

#| The grammar's own C<tags.scm> — the query the tree-sitter project
#| uses for code navigation, capturing C<@definition.*> and (for most
#| grammars) C<@reference.*>.
#|
#|     my $q = Query.new('go', tags-query('go'));
#|
#| Note that the C and C++ tags queries are definitions-only upstream:
#| they capture no C<@reference.*> at all.
sub tags-query(Str $name --> Str) is export {
    query-source($name, 'tags');
}

#| The grammar's own C<highlights.scm>, capturing C<@keyword>,
#| C<@string>, C<@function> and friends for syntax colouring.
sub highlights-query(Str $name --> Str) is export {
    query-source($name, 'highlights');
}
