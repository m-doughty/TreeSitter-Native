[![Actions Status](https://github.com/m-doughty/TreeSitter-Native/actions/workflows/test.yml/badge.svg)](https://github.com/m-doughty/TreeSitter-Native/actions)

NAME
====

TreeSitter::Native — tree-sitter for Raku: parse, navigate and query source code in nine bundled languages

SYNOPSIS
========

```raku
use TreeSitter::Native;
use TreeSitter::Native::Query;
use TreeSitter::Native::Languages;

my $parser = Parser.new('python');
my $tree   = $parser.parse(q:to/PY/);
    def greet(name):
        return shout(name)
    PY

# Navigate: fields are the readable way into a node.
my $def = $tree.root-node.named-child(0);
say $def.type;                                 # function_definition
say $def.child-by-field-name('name').text;     # greet
say $def.start-point;                          # 0:0

# Query: the grammar author's own tags.scm, predicates and all.
my $tags = Query.new('python', tags-query('python'));

for $tags.matches($tree.root-node) -> $match {
    my $kind = $match.captures.keys.first(*.contains('.'));
    say "$kind\t{$match.captures<name>.text}";
}
# definition.function    greet
# reference.call         shout
```

No C toolchain, no `tree-sitter` CLI, no grammar shopping: the runtime and all nine grammars are compiled into one shared library that `zef install` either downloads prebuilt or builds from pinned sources.

DESCRIPTION
===========

[tree-sitter](https://tree-sitter.github.io/tree-sitter/) is an incremental parser generator with error recovery: it produces a concrete syntax tree for a file whether or not that file is valid, which is what makes it the parsing engine behind most editors' structural features. This distribution is a NativeCall binding to it, bundling the tree-sitter runtime and nine generated grammars in a single library.

Five modules, in the order you are likely to need them:

<table class="pod-table">
<thead><tr>
<th>Module</th> <th>What it gives you</th>
</tr></thead>
<tbody>
<tr> <td>TreeSitter::Native</td> <td>Parser, Tree, Node, Cursor — the ergonomic layer</td> </tr> <tr> <td>TreeSitter::Native::Query</td> <td>Query, Match, and predicate evaluation</td> </tr> <tr> <td>TreeSitter::Native::Languages</td> <td>the nine grammars by name, and their vendored .scm queries</td> </tr> <tr> <td>TreeSitter::Native::Types</td> <td>enums (QueryErrorKind, PredicateStepType, …) and X::TreeSitter::Query</td> </tr> <tr> <td>TreeSitter::Native::FFI</td> <td>the raw tsn_* bindings, for what the layers above do not cover</td> </tr>
</tbody>
</table>

Two things distinguish this binding from a thin wrapper, and both are correctness rather than convenience:

  * **Query predicates are evaluated.** The C library parses `(#eq? …)` and `(#match? …)` clauses and then deliberately ignores them, leaving their meaning to bindings. A binding that skips that step returns matches its own queries say to exclude — the bundled javascript `tags.scm` reports every `constructor` as a method and every `require(…)` as a call. See **QUERIES**, below.

  * **Offsets are byte offsets, and the API refuses to pretend otherwise.** `Node.text` slices the tree's UTF-8 buffer rather than the `Str`, because `"\r\n"` is one Raku grapheme and two bytes. See **BYTE OFFSETS**, below.

INSTALLATION
============

```shell
zef install TreeSitter::Native
```

The prebuilt path (default)
---------------------------

`Build.rakumod` downloads one prebuilt library for the detected platform from this distribution's GitHub releases, verifies its SHA-256 against the `resources/checksums.txt` that shipped in the distribution, and stages it into `resources/lib/`. A checksum that is absent or does not match is a hard failure of that path, never a "warn and continue" — the bundled digests are a security boundary.

<table class="pod-table">
<thead><tr>
<th>Platform</th> <th>Artefact slug</th>
</tr></thead>
<tbody>
<tr> <td>macOS, arm64 and x86_64</td> <td>macos-universal (one universal dylib)</td> </tr> <tr> <td>Linux x86_64, glibc</td> <td>linux-x86_64-glibc</td> </tr> <tr> <td>Linux aarch64, glibc</td> <td>linux-aarch64-glibc</td> </tr> <tr> <td>Windows x86_64</td> <td>windows-x86_64</td> </tr> <tr> <td>Windows arm64</td> <td>windows-arm64</td> </tr>
</tbody>
</table>

The Linux artefacts are built against glibc 2.35. On an older glibc the prebuilt would load and then die at the first call, so `Build.rakumod` reads `ldd --version` and skips straight to the source path instead. musl systems take the source path for the same reason.

The source path (fallback)
--------------------------

Taken automatically when there is no usable prebuilt, and on demand with `TREESITTER_NATIVE_BUILD_FROM_SOURCE=1`. It needs:

  * A C compiler — `cc` on Unix (Xcode command line tools, GCC, Clang), `cl.exe` from MSVC on Windows. Build from a Developer Command Prompt, or run `vsdevcmd.bat` first, so `cl.exe` is on the path. `/bigobj` and `/utf-8` are applied for you: the largest generated parser (C++, 17 MB of C) exceeds MSVC's default section limit, and several grammars carry non-ASCII bytes in string literals.

  * `curl` and `tar`. Both ship with every Unix we target and with Windows 10 1803 and later (Windows' `tar` is bsdtar, which handles the `.tar.gz` archives fine). They are probed before the first download so that a missing one is a sentence rather than a zero-byte tarball.

  * Network access to `github.com`, or a pre-staged source tree — see **Offline and air-gapped installs**, below.

The generated C for nine grammars totals around 56 MB, which is far too much to vendor in a distribution tarball, so the source path downloads nine tag archives pinned by name, tag, URL and SHA-256 in the `SOURCE_PINS` file at the distribution root. Each is verified before it is unpacked, cached under `$XDG_CACHE_HOME` so a second install reuses it, then compiled as 17 translation units and linked into one library. Budget one to three minutes on a cold cache; most of that is the download. macOS builds a universal binary (arm64 + x86_64) exactly as the release pipeline does, so the two paths produce interchangeable artefacts.

The result is one library of roughly 20 MB with no dependencies beyond libc — that is the price of nine grammars' parse tables, and it is paid once.

Environment variables
---------------------

Build-time knobs, read by `Build.rakumod`:

<table class="pod-table">
<thead><tr>
<th>Variable</th> <th>Effect</th>
</tr></thead>
<tbody>
<tr> <td>TREESITTER_NATIVE_BUILD_FROM_SOURCE=1</td> <td>Skip the prebuilt download; always compile.</td> </tr> <tr> <td>TREESITTER_NATIVE_BINARY_ONLY=1</td> <td>Refuse to fall back to compiling. Fail instead. (CI fail-fast.)</td> </tr> <tr> <td>TREESITTER_NATIVE_BINARY_URL=URL</td> <td>Base URL for prebuilt artefacts — mirrors, internal repos.</td> </tr> <tr> <td>TREESITTER_NATIVE_CACHE_DIR=PATH</td> <td>Root of both caches: downloaded binaries and extracted sources.</td> </tr> <tr> <td>TREESITTER_NATIVE_VENDOR_DIR=PATH</td> <td>Compile from a pre-staged source tree instead of downloading.</td> </tr>
</tbody>
</table>

And one runtime knob, `TREESITTER_NATIVE_LIB`, read by `TreeSitter::Native::FFI` when the library is first opened: it loads the library at that path instead of the staged one. It must be an **absolute** path to an existing file, because the value goes to `dlopen` / `LoadLibrary` verbatim — a relative path would be resolved against the loader's search list rather than your working directory. A value that is relative, or that names no readable file, is an error rather than a silent fall-through: someone who sets that variable means it.

Offline and air-gapped installs
-------------------------------

`TREESITTER_NATIVE_VENDOR_DIR` points the source path at a directory you laid out yourself, and skips both the download and the digest check:

```shell
# One directory per SOURCE_PINS row, named <name>-<tag>, each holding
# that upstream's repository root:
#
#   /srv/ts-sources/tree-sitter-v0.26.12/lib/src/lib.c
#   /srv/ts-sources/tree-sitter-python-v0.25.0/src/parser.c
#   …
TREESITTER_NATIVE_VENDOR_DIR=/srv/ts-sources \
TREESITTER_NATIVE_BUILD_FROM_SOURCE=1 \
  zef install TreeSitter::Native
```

GitHub's tag archives are not guaranteed byte-stable across archiver upgrades, so a digest mismatch is possible without anything sinister having happened. It still aborts the build — compiling unverified source is not a thing this distribution does — and the recovery is either the vendor directory above or re-pinning the row in `SOURCE_PINS` after re-hashing the tarball yourself.

LANGUAGES
=========

Nine grammars are linked in. There is no dynamic grammar loading and no `tree-sitter-cli` at runtime; `TreeSitter::Native::Languages` is the map from a name to a compiled grammar.

<table class="pod-table">
<thead><tr>
<th>Name</th> <th>Upstream tag</th> <th>Language ABI</th> <th>Vendored queries</th>
</tr></thead>
<tbody>
<tr> <td>c</td> <td>v0.24.2</td> <td>15</td> <td>highlights, tags</td> </tr> <tr> <td>cpp</td> <td>v0.23.4</td> <td>14</td> <td>highlights, injections, tags</td> </tr> <tr> <td>go</td> <td>v0.25.0</td> <td>15</td> <td>highlights, tags</td> </tr> <tr> <td>java</td> <td>v0.23.5</td> <td>14</td> <td>highlights, tags</td> </tr> <tr> <td>javascript</td> <td>v0.25.0</td> <td>15</td> <td>highlights, highlights-jsx, highlights-params, injections, locals, tags</td> </tr> <tr> <td>python</td> <td>v0.25.0</td> <td>15</td> <td>highlights, tags</td> </tr> <tr> <td>rust</td> <td>v0.24.2</td> <td>15</td> <td>highlights, injections, tags</td> </tr> <tr> <td>tsx</td> <td>v0.23.2</td> <td>14</td> <td>highlights, locals, tags</td> </tr> <tr> <td>typescript</td> <td>v0.23.2</td> <td>14</td> <td>highlights, locals, tags</td> </tr>
</tbody>
</table>

The bundled runtime is tree-sitter 0.26.12, which implements language ABI 15 and accepts grammars down to ABI 13, so the ABI-14 grammars are supported rather than merely tolerated. `tsx` and `typescript` come from one repository but are two distinct grammars, not aliases: they disagree about `<T> `.

```raku
use TreeSitter::Native::Languages;

say languages();                   # (c cpp go java javascript python
                                   #  rust tsx typescript)
say is-language('python');         # True
say is-language('Python');         # False — names are case-sensitive
say language-abi('cpp');           # 14

my $lang = language('rust');       # a TSLanguage for Parser/Query
```

An unknown name dies with the whole list of valid ones, because the caller is usually a file-extension map and "which ones *are* there?" is always the next question.

PARSING
=======

`Parser` holds a grammar plus the scratch state one parse needs. It is not thread-safe — give each thread its own — but it is cheap enough to make per file if that is simpler than pooling.

```raku
use TreeSitter::Native;

my $parser = Parser.new('go');          # or Parser.new then .set-language
my $tree   = $parser.parse('package main; func main() {}');

say $tree.root-node.type;               # source_file

# Parsing never fails on malformed input: tree-sitter recovers and marks
# the damage. Ask the tree whether it is damaged.
my $broken = $parser.parse('package main; func main( {');
say $broken.root-node.has-error;        # True
```

`.parse(Str)` encodes to UTF-8 exactly once and hands the buffer to the `Tree`. `.parse-bytes(Blob)` takes bytes you already have — a slurped file, a network payload — with no decode/encode round trip, and works even when those bytes are not valid UTF-8 (see **BYTES THAT ARE NOT UTF-8**).

TREES
=====

A `Tree` is a parse result: the syntax tree plus the exact bytes it describes. It is independent of the parser that produced it — disposing the parser does not touch it — and of every other tree.

```raku
say $tree.root-node.type;      # module
say $tree.byte-length;         # source length IN BYTES
say $tree.source;              # the original Str (Str type object for
                               # a parse-bytes tree)
say $tree.bytes.elems;         # same as .byte-length

my $copy = $tree.clone;        # independent C allocation, shared bytes
$copy.dispose;
```

NODES
=====

`Node` is an immutable handle on one node: a copy of tree-sitter's 32-byte node handle plus a reference to the `Tree`, which is what keeps the tree alive for as long as any node of it is reachable.

Nodes are **value objects**. Two handles on the same node of the same tree are `===`, hash to the same slot, and behave in sets and bags the way you would want when building a graph over a file:

```raku
my $a = $root.named-child(0);
my $b = $root.child(0);

say $a === $b;                          # True
say ($a, $b).Set.elems;                 # 1
say $a.equals($b);                      # True — asked of tree-sitter

my %count is Bag = $root.walk;          # node => how many times seen
say %count{$a};                         # 1
```

Navigation accessors return the `Node` **type object** when there is no such node, so they compose with `with`, `//` and `andthen` instead of with null checks:

```raku
with $node.child-by-field-name('name') -> $name {
    say $name.text;                     # greet
}
say $root.parent.defined;               # False — the root has no parent
say ($node.next-sibling // 'none').Str; # none
```

The accessors, grouped:

  * **Identity and kind** — `.type`, `.grammar-type`, `.symbol`, `.equals($other)`, `.WHICH`.

  * **Predicates** — `.is-named`, `.is-missing`, `.is-extra`, `.is-error`, `.has-error`, `.has-changes`.

  * **Position** — `.start-byte`, `.end-byte`, `.byte-length`, `.start-point`, `.end-point`. Points are `row`/`column` pairs, both zero-based, the column in bytes.

  * **Text** — `.text` (the bytes, decoded as UTF-8) and `.byte-slice` (the bytes themselves, which always works).

  * **Structure** — `.child($i)`, `.named-child($i)`, `.children`, `.named-children`, `.child-count`, `.named-child-count`, `.parent`, `.next-sibling`, `.prev-sibling`, `.next-named-sibling`, `.prev-named-sibling`, `.child-by-field-name($field)`, `.field-name-for-child($i)`, `.descendant-for-byte-range($a, $b)`, `.named-descendant-for-byte-range($a, $b)`.

  * **Traversal** — `.walk` and `.named-walk` are lazy pre-order `Seq`s; `.cursor` is the allocation-free alternative below.

  * **Debugging** — `.sexp` is tree-sitter's own S-expression of the whole subtree. Useful at a REPL, far too big for a log line.

"Named" is the distinction between the nodes a grammar gives names to and the punctuation and keywords it does not:

```raku
my $call = $root.walk.first(*.type eq 'call');
say $call.children.map(*.type).join(' ');        # identifier argument_list
say $call.named-children.map(*.type).join(' ');  # identifier argument_list

my $args = $call.child-by-field-name('arguments');
say $args.children.map(*.type).join(' ');        # ( identifier )
say $args.named-children.map(*.type).join(' ');  # identifier
```

Finding things is `.walk` plus `.grep`, which reads the way you would say it out loud:

```raku
my @calls = $root.walk.grep(*.type eq 'call').eager;
say @calls.map({ .child-by-field-name('function').text });   # (shout)
```

CURSORS
=======

`Node.walk` allocates a `Node` per step. A cursor moves in place, and is what to reach for on a whole-file walk. It is not exported — Raku's core already binds `Cursor` — so build one with `Node.cursor` or `Tree.cursor`, or name it `TreeSitter::Native::Cursor` in full.

```raku
my $c = $tree.cursor;
LEAVE $c.dispose;

while $c.goto-first-child {
    say '  ' x $c.current-depth,
        ($c.current-field-name // '-'), ' ', $c.current-node.type;
}
#   - function_definition
#     - def
```

`.walk` on a cursor yields the same nodes in the same order as `Node.walk` without the intermediate objects. It **drives the cursor**, so do not interleave it with your own `goto-` calls, and `.reset` a cursor before walking it twice:

```raku
my $cursor = $root.cursor;
LEAVE $cursor.dispose;

say $cursor.walk.map(*.type).head(4).join(' ');
# module function_definition def identifier

$cursor.reset($root);
say $cursor.walk.elems == $root.walk.elems;      # True
```

Depths are relative to the node the cursor started on or was last reset to: that node is depth 0, and the cursor will not climb above it.

BYTE OFFSETS
============

Every offset in this distribution — `start-byte`, `end-byte`, point columns, the byte ranges you can restrict a query to, the offset in a query error — is a byte offset into the **UTF-8 encoding** of the source. Not a character index, and emphatically not a grapheme index.

This matters more than it sounds, because Raku's `Str` is a sequence of graphemes:

```raku
say 'größe'.chars;                     # 5
say 'größe'.encode('utf-8').elems;     # 7
say "\r\n".chars;                      # 1  — ONE grapheme
say "\r\n".encode('utf-8').elems;      # 2  — TWO bytes
```

So a file with any non-ASCII identifier, or any Windows line ending, has character offsets that drift further from its byte offsets on every occurrence. Slicing the source `Str` with `.substr` and a tree-sitter offset produces quiet nonsense — the worst kind.

`Parser.parse` therefore encodes once and hands the buffer to the `Tree`; `Node.text` slices **that** and decodes the slice. Do your own slicing the same way:

```raku
my $mb   = $parser.parse("def größe(wert):\n    return wert\n");
my $name = $mb.root-node.named-child(0).child-by-field-name('name');

say $name.text;                        # größe
say $name.start-byte, '..', $name.end-byte;   # 4..11
say $name.byte-length;                 # 7 bytes for 5 characters

# The right way to slice by hand:
say $mb.bytes.subbuf($name.start-byte,
                     $name.end-byte - $name.start-byte)
            .decode('utf-8');          # größe

# …which is what .byte-slice already does:
say $name.byte-slice.decode('utf-8') eq $name.text;      # True

# And the wrong way, kept here as a warning:
say $mb.source.substr($name.start-byte,
                      $name.end-byte - $name.start-byte); # größe(w
```

Point columns are byte columns too, for the same reason.

QUERIES
=======

A query is one or more S-expression patterns compiled against a grammar and matched against a subtree. It is the same language the `tree-sitter` CLI and every editor integration uses, and the `.scm` files each grammar ships are written in it.

```raku
use TreeSitter::Native;
use TreeSitter::Native::Query;

my $parser = Parser.new('rust');
my $tree   = $parser.parse('fn greet(name: &str) -> &str { name }');

my $q = Query.new('rust', '(function_item name: (identifier) @fn)');
say $q.pattern-count;                            # 1
say $q.capture-names;                            # (fn)

for $q.matches($tree.root-node) -> $m {
    say $m.pattern-index, ' ', $m.captures<fn>.text;    # 0 greet
}
```

Compiling is the expensive part — a full `tags.scm` is hundreds of patterns — so build a query once and reuse it across files. A query is tied to the grammar it was compiled against, not to any particular tree.

Two shapes of result:

  * `.matches($node)` — a lazy `Seq` of `Match` objects, each carrying its `.pattern-index` and its captures. `.captures` is a `name =` Node> hash keeping the first node per name; `.nodes($name)` returns every node captured under a name (a `(comment)* @doc` capture yields several); `.entries` is the raw ordered list.

  * `.captures($node)` — every capture of every accepted match, flattened into a lazy `Seq` of `name =` Node> pairs, for when you do not care which pattern or match produced them.

```raku
my $q = Query.new('python', '(identifier) @id');

for $q.captures($root) -> (:key($name), :value($n)) {
    say "$name: {$n.text}";
}
# id: greet
# id: name
# id: shout
# id: name
```

Predicates are evaluated here
-----------------------------

tree-sitter's C library parses the `(#eq? @a "x")` clauses inside a pattern and then does nothing with them, because what they mean depends on how the binding can read node text. This binding evaluates six:

<table class="pod-table">
<thead><tr>
<th>Predicate</th> <th>Meaning</th>
</tr></thead>
<tbody>
<tr> <td>(#eq? @a &quot;text&quot;)</td> <td>every node captured as @a has that text</td> </tr> <tr> <td>(#eq? @a @b)</td> <td>@a and @b capture the same text, pairwise</td> </tr> <tr> <td>(#not-eq? …)</td> <td>the negation of either form</td> </tr> <tr> <td>(#match? @a &quot;regex&quot;)</td> <td>every node captured as @a matches</td> </tr> <tr> <td>(#not-match? @a &quot;regex&quot;)</td> <td>no node captured as @a matches</td> </tr> <tr> <td>(#any-of? @a &quot;x&quot; &quot;y&quot;)</td> <td>every @a node&#39;s text is one of the list</td> </tr> <tr> <td>(#not-any-of? @a &quot;x&quot; &quot;y&quot;)</td> <td>no @a node&#39;s text is</td> </tr>
</tbody>
</table>

A capture a match does not contain has no nodes, and a predicate over no nodes is vacuously true — the rule tree-sitter's own bindings use. Text comparison for `#eq?` and `#any-of?` is done on bytes, so it is exact even for source that does not decode as UTF-8.

This is not a nicety. The bundled javascript `tags.scm` is wrong without it:

```raku
use TreeSitter::Native;
use TreeSitter::Native::Query;
use TreeSitter::Native::Languages;

my $parser = Parser.new('javascript');
my $tree   = $parser.parse(q:to/JS/);
    class Widget {
        constructor(opts) { this.opts = opts; }
        render() { return draw(this.opts); }
    }
    const fs = require('fs');
    JS

my $q = Query.new('javascript', tags-query('javascript'));

my @names = $q.matches($tree.root-node)
             .map({ .captures<name> andthen .text })
             .grep(*.defined).unique.sort;
say @names;              # [Widget draw render]

# constructor was excluded by (#not-eq? @name "constructor"), and
# require by (#not-match? @name "^(require)$"). The raw cursor — which
# applies no predicates — still sees both:
my $c = $q.cursor($tree.root-node);
LEAVE $c.dispose;
my @raw;
while $c.next-match -> $m {
    @raw.push($_) with ($m.captures<name> andthen .text);
}
say @raw.grep({ $_ eq 'constructor' | 'require' }).unique.sort;
# (constructor require)
```

`.accepts($match)` is that filter, and is public precisely so a hand-driven cursor loop can apply it: `next unless $q.accepts($m)`.

Directives are exposed, not applied
-----------------------------------

Clauses ending in `!` rather than `?` — `#set!`, `#strip!`, `#select-adjacent!` — are **directives**. They do not filter matches; they tell the consuming application to do something with one. There is no agreed set of them and no agreed semantics, so this binding parses them, hands them to you, and applies none:

```raku
use TreeSitter::Native::Query;
use TreeSitter::Native::Languages;

my $q = Query.new('javascript', tags-query('javascript'));

my $p = (^$q.pattern-count).first({
    $q.pattern-directives($_).elems >= 2;
});

for $q.pattern-directives($p) -> $d {
    say $d.name, ' ', $d.args.map(*.value).join(' ');
}
# strip! doc ^[\s\*/]+|^[\s\*/]$
# select-adjacent! doc definition.method
```

In every bundled `tags.scm`, the directives shape only the `@doc` capture — which comment block belongs to which definition, and how much leading `*` to strip off it. Nothing else is affected by their absence. Each clause is a `Predicate` object with `.name`, `.args` (each an `Arg` with `.kind` and `.value`), `.is-directive` and `.evaluated`; `.pattern-predicates($i)` returns all clauses of a pattern, `.pattern-directives($i)` just the `!` ones.

Unknown predicates fail closed
------------------------------

A query naming a predicate outside the table above is rejected at construction with an `X::TreeSitter::Query` of kind `QUERY_ERROR_PREDICATE`. Ignoring it silently would mean returning matches the query says to exclude, which is the bug this module exists to avoid.

```raku
use TreeSitter::Native::Query;
use TreeSitter::Native::Types;

my $scm = '((identifier) @a (#is-not? @a local))';

my $err = (try Query.new('python', $scm)) // $!;
say $err.kind;                              # QUERY_ERROR_PREDICATE
say $err.message.contains('pass :lenient'); # True

# Take the matches anyway — the clause is parsed, exposed, and ignored:
my $q = Query.new('python', $scm, :lenient);
say $q.pattern-predicates(0)[0].name;       # is-not?
say $q.pattern-predicates(0)[0].evaluated;  # False
```

`:lenient` covers unrecognised **names** only. A `#eq?` with three arguments is a malformed query however lenient you feel, and is rejected either way.

Exactly one vendored query needs `:lenient` — javascript's `highlights.scm`, which uses `#is-not? @x local`, an editor-ecosystem property predicate rather than a text filter. The other twenty-five vendored queries, `tags.scm` and `highlights.scm` alike, compile without it:

```raku
use TreeSitter::Native::Query;
use TreeSitter::Native::Languages;

for languages() -> $lang {
    for query-kinds($lang) -> $kind {
        my Bool $lenient = $lang eq 'javascript' && $kind eq 'highlights';
        my $q = Query.new($lang, query-source($lang, $kind), :$lenient);
        say sprintf('%-11s %-18s %3d patterns%s', $lang, $kind,
                    $q.pattern-count, $lenient ?? '  (:lenient)' !! '');
        $q.dispose;
    }
}
```

Regular expressions
-------------------

`#match?` patterns are written in the query file in Perl/PCRE-ish syntax. Raku's regex engine is not Perl's, and Raku has no runtime "compile this string as a Perl 5 regex" short of `EVAL` — which, on a pattern that came out of someone else's `.scm` file, is a remote code execution hole rather than a feature. Nor can the string be handed to Raku's `/<$pattern>/ ` directly: in Raku `[abc]` is a non-capturing *group* rather than a character class, and `{2,3}` is a *code block*, which would execute the very input we are trying not to trust.

So patterns are translated, at query construction, into equivalent Raku regex source built entirely out of constructs the translator emits, with every literal run quoted. Anything it cannot translate faithfully is a construction-time error rather than a silently different match.

Translated: literals, `.`, `^`, `$`, `\A`, `\z`, `\Z`, `\b`, `\B`, the `\d \D \w \W \s \S \n \r \t \f \e` escapes, `\xHH` and `\x{HHHH}`, character classes with ranges and negation, groups (capturing, `(?:…)`, `(?<name>…) `), lookaround (`(?=…)`, `(?!…)`, `(?<=…) `, `(?<!…) `), the `(?i)` and `(?i:…)` flags, alternation, `*` `+` `?` with their lazy forms, and `{n}` / `{n,}` / `{n,m}`.

Rejected, loudly: backreferences, possessive quantifiers, POSIX bracket classes (`[:alpha:]`), and any other `(?…)` construct.

Two deliberate approximations, documented so they cannot surprise you quietly:

  * `$` means end-of-string here, where Perl also lets it match before a final newline.

  * Alternation becomes Raku's `||`, which tries alternatives left to right exactly as Perl does. Raku's bare `|` would prefer the longest match instead.

Since `#match?` only ever asks whether a match exists, neither changes an answer for any pattern that is not itself ambiguous.

Restricting a query to a byte range
-----------------------------------

Querying one function of a large file does not need a re-parse:

```raku
use TreeSitter::Native;
use TreeSitter::Native::Query;

my $parser = Parser.new('python');
my $tree   = $parser.parse("a = 1\nb = 2\nc = 3\n");
my $root   = $tree.root-node;
my $q      = Query.new('python', '(identifier) @id');

say $q.captures($root).map({ .value.text });                   # (a b c)
say $q.captures($root, :start-byte(6), :end-byte(11))
      .map({ .value.text });                                   # (b)

my $stmt = $root.named-child(2);
say $q.captures($root, :start-byte($stmt.start-byte),
                       :end-byte($stmt.end-byte))
      .map({ .value.text });                                   # (c)
```

Both are byte offsets. An empty range (equal start and end) yields nothing — which needs saying, because tree-sitter itself reads an end byte of `0` as "no limit" and would hand back the whole file; that quirk is normalised here. A range whose start is past its end is a caller mistake and throws.

Driving the cursor yourself
---------------------------

`.matches` creates, drives and disposes a query cursor for you, and disposes it when the `Seq` is exhausted. Abandoning a partly-consumed `Seq` leaves the cursor to the garbage collector — safe, but not prompt. When that matters, or when you want the raw unfiltered matches, drive it yourself:

```raku
use TreeSitter::Native;
use TreeSitter::Native::Query;

my $parser = Parser.new('python');
my $tree   = $parser.parse("foo(1)\nbar(2)\n");
my $q      = Query.new('python', '((call function: (identifier) @f)
                                   (#eq? @f "foo"))');

my $c = $q.cursor($tree.root-node);
LEAVE $c.dispose;

while $c.next-match -> $m {
    next unless $q.accepts($m);          # .next-match does NOT filter
    say $m.captures<f>.text;             # foo
}
```

ERRORS
======

Query failures are typed. `X::TreeSitter::Query` carries a machine- readable `.kind` (a `QueryErrorKind` from `TreeSitter::Native::Types`), the byte `.offset` into the query source, and the `.source` itself, from which the human-facing `.line`, `.column` and `.snippet` are derived:

```raku
use TreeSitter::Native::Query;
use TreeSitter::Native::Types;

my $err = (try Query.new('python', '(no_such_node) @x')) // $!;

say $err.kind;                  # QUERY_ERROR_NODE_TYPE
say $err.kind-description;      # node type
say $err.offset;                # 1     (a BYTE offset)
say $err.line, ':', $err.column;# 1:2
say $err.snippet;               # no_such_node) @x
say $err.message;
# tree-sitter query error (node type) at byte 1, line 1 column 2: no_such_node) @x
```

The kinds are tree-sitter's own — `QUERY_ERROR_SYNTAX`, `QUERY_ERROR_NODE_TYPE`, `QUERY_ERROR_FIELD`, `QUERY_ERROR_CAPTURE`, `QUERY_ERROR_STRUCTURE`, `QUERY_ERROR_LANGUAGE` — plus one addition, `QUERY_ERROR_PREDICATE`, for a query that is valid tree-sitter but names a predicate this binding will not evaluate. It needs a kind of its own so a `when` chain can tell "your query is not valid" apart from "your query is valid but I cannot honour it":

```raku
use TreeSitter::Native::Query;
use TreeSitter::Native::Types;

for '(function_definition',                     # syntax
    '(no_such_node) @x',                        # node type
    '((identifier) @a (#nope? @a "x"))'         # predicate
    -> $scm
{
    my $e = (try Query.new('python', $scm)) // $!;
    given $e.kind {
        when QUERY_ERROR_SYNTAX    { say 'not a valid query' }
        when QUERY_ERROR_PREDICATE { say 'unsupported #…?' }
        default                    { say $e.kind-description }
    }
}
# not a valid query
# node type
# unsupported #…?
```

Everything else — an unknown grammar name, a query kind a grammar does not ship, use after `.dispose`, an inside-out byte range — throws a plain exception whose message names the mistake and, where there is a list to give, gives it.

VENDORED QUERIES AND LICENCES
=============================

Every grammar's own `.scm` query files are vendored in this distribution's `resources/`, copied verbatim from the grammar repository at the tag pinned in `SOURCE_PINS`. Reading them needs no native library at all:

```raku
use TreeSitter::Native::Languages;

my $tags = tags-query('go');            # queries/go/tags.scm
my $hl   = highlights-query('go');      # queries/go/highlights.scm
my $loc  = query-source('typescript', 'locals');

say query-kinds('rust');                # (highlights injections tags)
say $tags.lines.grep(*.contains('@definition.function')).head.trim;
# name: (identifier) @name) @definition.function
```

`tags.scm` is the code-navigation query the tree-sitter project maintains, capturing `@definition.*` and — for most grammars — `@reference.*`. Note that the C and C++ tags queries are definitions-only upstream: they capture no `@reference.*` at all. `highlights.scm` is the syntax-colouring query, capturing `@keyword`, `@string`, `@function` and friends.

The queries and the compiled grammars are the work of the tree-sitter project and its grammar authors, MIT-licensed; the runtime additionally carries Unicode's ICU licence for its character-property tables. Every upstream licence file is vendored under `resources/licenses/` and installed with the distribution. This binding — the shim, the Raku modules, the build machinery — is Artistic 2.0.

LIFETIMES
=========

`Parser`, `Tree`, `Cursor`, `Query` and the query cursor each own a C allocation. Each has an idempotent `.dispose` and a `DESTROY` that calls it, so you may free them explicitly or leave them to the garbage collector, and calling `.dispose` twice — or after `DESTROY` already ran — is harmless.

The rules worth knowing:

  * A `Tree` outlives the `Parser` that made it. Disposing a parser does not touch trees it produced.

  * A `Node` keeps its `Tree` alive by holding a reference to it, so ordinary garbage collection can never leave a node pointing into freed memory. A `Cursor` and a query cursor hold the tree the same way.

  * The one thing you can still do wrong is dispose a `Tree` explicitly and then use a `Node` from it. That is checked: every node accessor asks its tree whether it is still alive and throws rather than reading freed memory.

```raku
use TreeSitter::Native;

my $root = do {
    my $parser = Parser.new('python');
    my $tree   = $parser.parse('x = 1');
    $parser.dispose;                    # the tree does not care
    $tree.root-node;
};
say $root.type;                         # module — the tree is still alive

$root.tree.dispose;
say (try $root.type) // 'throws';       # throws
```

BYTES THAT ARE NOT UTF-8
========================

Pinned behaviour, verified against the bundled runtime rather than assumed. tree-sitter is byte-oriented: it does not validate UTF-8, does not refuse the input, and does not throw. It parses what it can and marks the rest as an `ERROR` node. This binding passes that through unchanged and draws exactly one line — `.byte-slice` always works, `.text` decodes and therefore throws:

```raku
use TreeSitter::Native;

my $parser = Parser.new('python');
my $bytes  = Blob[uint8].new(
    0x64, 0x65, 0x66, 0x20,           # 'def '
    0xff, 0xfe,                       # not valid UTF-8
    0x28, 0x29, 0x3a, 0x20,           # '(): '
    0x70, 0x61, 0x73, 0x73,           # 'pass'
);

my $tree = $parser.parse-bytes($bytes);
my $root = $tree.root-node;

say $root.type;                          # module
say $root.has-error;                     # True
say $root.walk.grep(*.is-error).elems;   # 2
say $root.byte-slice.elems;              # 14 — every byte, always
say (try $root.text) // 'does not decode';  # does not decode

# The parts that DO decode are still readable: one stray byte does not
# cost you the rest of the file.
say $root.walk.first(*.type eq 'pass_statement').text;   # pass
```

`parse(Str)` can never be in this position: a Raku `Str` always encodes to valid UTF-8.

LIMITATIONS
===========

  * **There is no Raku grammar.** No usable tree-sitter grammar for Raku exists at the time of writing. That is a gap in the ecosystem, not an omission here, and `language('raku')` says so explicitly. If one appears it can be added without any API change.

  * **No incremental parsing at the Raku layer yet.** tree-sitter's headline feature — re-parsing an edited file in time proportional to the edit — is wired through the C shim (the parse entry point takes a nullable old tree, and `ts_tree_edit` is exported) but is not exposed in Raku. Adding it later is purely additive, with no ABI change to the library. Until then, re-parse the file: for the file sizes an editor or a code-analysis pass deals with, a full parse is milliseconds.

  * **UTF-8 only, and no streaming input.** The `TSInput` callback interface, UTF-16 input and custom decoders are not wrapped. Source arrives as a `Str` or a `Blob`, entirely in memory.

  * **Directives are parsed, not applied** — see **Directives are exposed, not applied** under QUERIES.

  * **Also not wrapped:** the parser logger, DOT-graph output, included ranges (parsing one language embedded in another), and the wasm grammar loader.

  * **C and C++ tag queries are definitions-only upstream**, so a reference graph over those two languages needs a supplementary query of your own.

  * **A parser is not thread-safe.** Give each thread its own; trees, being immutable once produced, are safe to read from several.

SEE ALSO
========

  * [tree-sitter](https://tree-sitter.github.io/tree-sitter/) — the upstream project, whose [query syntax reference](https://tree-sitter.github.io/tree-sitter/using-parsers/queries/index.html) documents the pattern language this distribution compiles.

AUTHOR
======

Matt Doughty

LICENSE
=======

Artistic 2.0. The bundled tree-sitter runtime and grammars are MIT, and the runtime's Unicode tables carry the ICU licence; see `resources/licenses/`.

