use v6.d;

unit module TreeSitter::Native;

use NativeCall;
use TreeSitter::Native::FFI;
use TreeSitter::Native::Languages;

=begin pod

=head1 NAME

TreeSitter::Native - parse and navigate source code with tree-sitter

=head1 SYNOPSIS

    use TreeSitter::Native;

    my $parser = Parser.new('python');
    my $tree   = $parser.parse(q:to/PY/);
        def greet(name):
            return f"hello {name}"
        PY

    my $root = $tree.root-node;
    say $root.type;                        # module
    say $root.sexp;                        # (module (function_definition …

    my $def = $root.named-child(0);
    say $def.child-by-field-name('name').text;   # greet
    say $def.start-point.gist;                   # 0:0

    $tree.dispose;
    $parser.dispose;

Or, letting scope do the freeing:

    {
        my $parser = Parser.new('go');
        my $tree   = $parser.parse($source);
        say $tree.root-node.walk.grep(*.type eq 'function_declaration').elems;
    }   # both collected, both freed, in any order

=head1 DESCRIPTION

Four classes, in the order you meet them.

C<Parser> holds a grammar and turns source into trees. C<Tree> owns a
parse result and the bytes it describes. C<Node> is an immutable handle
on one node of a tree — a value object, so two handles on the same node
compare equal and hash the same. C<Cursor> walks a tree without
allocating a C<Node> per step.

C<Parser>, C<Tree> and C<Node> are exported. C<Cursor> and C<Point> are
not, because Raku's core already has a C<Cursor> and importing a second
one over it would be rude; reach them through C<Node.cursor> and
C<Node.start-point>, or by their full names
C<TreeSitter::Native::Cursor> and C<TreeSitter::Native::Point>.

=head2 Byte offsets, always

Every offset in this distribution — C<start-byte>, C<end-byte>, point
columns, the byte ranges you can restrict a query to — is a byte offset
into the B<UTF-8 encoding> of the source. Not a character index, and
emphatically not a grapheme index.

This matters more than it sounds. In Raku C<"\r\n"> is B<one> grapheme,
so a Windows-line-ended file's C<.chars> and its byte length disagree by
one per line; a file with any non-ASCII identifier disagrees by more.
Slicing source text with C<.substr> and a tree-sitter offset produces
quiet nonsense.

C<Parser.parse> encodes its argument to UTF-8 exactly once and hands the
resulting C<Blob> to the C<Tree>, which keeps it. C<Node.text> slices
B<that> buffer and decodes the slice. Do your own slicing the same way:

    my $bytes = $tree.bytes;
    my $slice = $bytes.subbuf($node.start-byte,
                              $node.end-byte - $node.start-byte);
    say $slice.decode('utf-8');     # exactly $node.text

=head2 Lifetimes

C<Parser>, C<Tree> and C<Cursor> each own a C allocation. Each has an
idempotent C<.dispose> and a C<DESTROY> that calls it, so you may free
them explicitly or leave them to the garbage collector, and calling
C<.dispose> twice — or after C<DESTROY> already ran — is harmless.

A C<Tree> outlives the C<Parser> that made it; disposing the parser does
not touch trees it produced. A C<Node> keeps its C<Tree> alive by
holding a reference to it, so a node is never left pointing into freed
memory by ordinary garbage collection.

The one thing you can still do wrong is dispose a C<Tree> explicitly and
then use a C<Node> from it. That is checked: every node accessor asks
its tree whether it is still alive first, and throws rather than reading
freed memory.

=end pod

# Forward declarations. Node's attributes name Tree, Tree's methods name
# Node, and Cursor names both; the stubs let each be spelled before it
# is defined.
class Tree   { ... }
class Node   { ... }
class Cursor { ... }

#| A row/column position. Both are zero-based, and C<column> is a
#| B<byte> offset within its row, not a character offset — tree-sitter
#| counts bytes everywhere and this is no exception.
#|
#| Not exported (reach it as C<TreeSitter::Native::Point>); you get
#| instances from C<Node.start-point> and C<Node.end-point>.
#|
#|     my $p = $node.start-point;
#|     say "$p";           # 3:8
#|     say $p.row;         # 3
class Point {
    has UInt $.row    is required;
    has UInt $.column is required;

    # Constrained to defined invocants so that the type object keeps
    # Mu's versions. Pod rendering calls .raku on every declarand,
    # including type objects, and an override that reads attributes
    # would take `mi6 build` down with it.
    multi method Str(Point:D: --> Str)  { "$!row:$!column" }
    multi method gist(Point:D: --> Str) { self.Str }
}

#| Wrap a filled-in node buffer, or return the C<Node> type object if
#| the buffer holds the null node.
#|
#| Returning a type object rather than a "null Node" is the one place
#| this layer departs from the C API's shape, and it is deliberate: in
#| Raku, absence is an undefined value, so C<with $node.parent { … }>
#| and C<$node.parent // $fallback> do the obvious thing. Every
#| navigation accessor here can therefore be read as "the node, or
#| nothing".
#|
#| Internal; exported under C<:INTERNAL> only because
#| L<TreeSitter::Native::Query> has to wrap capture nodes the same way.
sub wrap-node(TSNodeBuf $buf, Tree $tree --> Node) is export(:INTERNAL) {
    tsn_node_is_null($buf) ?? Node !! Node.new(:$buf, :$tree);
}

# ====================================================================
# Parser
# ====================================================================

#| A tree-sitter parser: a grammar plus the scratch state one parse
#| needs. Not thread-safe — give each thread its own — but cheap enough
#| to make per-file if that is simpler than pooling.
#|
#|     my $parser = Parser.new('rust');
#|     my $tree   = $parser.parse('fn main() {}');
#|
#| The language may be a name from
#| L<TreeSitter::Native::Languages>C<::languages> or a C<TSLanguage>
#| you already have:
#|
#|     my $parser = Parser.new;
#|     $parser.set-language('tsx');
#|     $parser.set-language(language('tsx'));   # identical
class Parser is export {
    has TSParser   $!handle;
    has TSLanguage $!language;

    submethod BUILD(TSParser :$handle) { $!handle = $handle }

    #| Create a parser, optionally setting its language straight away.
    method new($language = Str) {
        my TSParser $handle = tsn_parser_new();
        unless $handle.defined {
            die "TreeSitter::Native::Parser: tree-sitter refused to "
              ~ "allocate a parser (out of memory).";
        }
        my $parser = self.bless(:$handle);
        $parser.set-language($language) if $language.defined;
        $parser;
    }

    method !live(--> TSParser:D) {
        $!handle // die "TreeSitter::Native::Parser: this parser has "
                      ~ "already been disposed.";
    }

    #| True once C<.dispose> (or C<DESTROY>) has run.
    method disposed(--> Bool) { !$!handle.defined }

    #| Point the parser at a grammar, by name or by C<TSLanguage>.
    #|
    #| Throws if the name is not one of the bundled grammars (listing
    #| the ones that are), and if tree-sitter rejects the grammar
    #| outright — which in practice means an ABI mismatch between the
    #| grammar and the bundled runtime.
    method set-language($lang --> Nil) {
        my TSParser $handle = self!live;
        # `language` here is the sub imported from
        # TreeSitter::Native::Languages, which is what turns a name
        # into a grammar (and which produces the "valid names are…"
        # message for a name that is not one).
        my TSLanguage $resolved = do given $lang {
            when TSLanguage { $_ }
            when Str        { language($_) }
            default {
                die "TreeSitter::Native::Parser.set-language expects a "
                  ~ "grammar name or a TSLanguage, not a "
                  ~ "{$lang.^name}.";
            }
        };
        unless tsn_parser_set_language($handle, $resolved) {
            die "TreeSitter::Native::Parser: tree-sitter refused this "
              ~ "grammar (ABI {tsn_language_abi($resolved)}; the "
              ~ "bundled runtime accepts {tsn_min_compatible_abi()} "
              ~ "through {tsn_runtime_abi_version()}).";
        }
        $!language = $resolved;
    }

    #| The grammar currently set, or the C<TSLanguage> type object if
    #| none is.
    method language(--> TSLanguage) {
        self!live;
        $!language;
    }

    #| Parse a string. It is encoded to UTF-8 B<once>, here, and the
    #| resulting buffer is handed to the C<Tree>, which keeps it for
    #| C<Node.text> to slice.
    #|
    #|     my $tree = $parser.parse("class C { }");
    #|
    #| Parsing never fails on malformed input — tree-sitter recovers
    #| and marks the damage, so check C<$tree.root-node.has-error> if
    #| you care. It does throw if no language has been set.
    method parse(Str:D $source --> Tree) {
        self!parse-blob($source.encode('utf-8'), $source);
    }

    #| Parse raw bytes, for when you already have the file's contents
    #| as a C<Blob> and do not want a decode/encode round trip.
    #|
    #| The bytes are given to tree-sitter as-is. tree-sitter is
    #| byte-oriented and will happily parse a buffer that is not valid
    #| UTF-8 — it treats the offending bytes as an C<ERROR> node and
    #| carries on — so this is also the way to survive a file with a
    #| stray latin-1 byte in it. What you cannot then do is call
    #| C<.text> on a node covering those bytes: decoding throws.
    #| C<.byte-slice> always works.
    method parse-bytes(Blob:D $bytes --> Tree) {
        self!parse-blob($bytes, Str);
    }

    method !parse-blob(Blob:D $bytes, Str $source --> Tree) {
        my TSParser $handle = self!live;
        unless $!language.defined {
            die "TreeSitter::Native::Parser: no grammar set. Call "
              ~ ".set-language('python') — or construct with "
              ~ "Parser.new('python') — before parsing.";
        }
        my TSTree $tree =
            tsn_parser_parse_utf8($handle, TSTree, $bytes, $bytes.elems);
        unless $tree.defined {
            die "TreeSitter::Native::Parser: the parse produced no "
              ~ "tree. tree-sitter returns nothing only when no "
              ~ "language is set or the parse was cancelled.";
        }
        Tree.new(:handle($tree), :$bytes, :$source);
    }

    #| Drop scratch state left over from a failed or cancelled parse.
    #| Trees already produced are unaffected.
    method reset(--> Nil) {
        tsn_parser_reset(self!live);
    }

    #| Free the parser. Idempotent. Trees this parser produced stay
    #| valid — they own their own memory.
    method dispose(--> Nil) {
        my TSParser $handle = $!handle;
        $!handle   = TSParser;
        $!language = TSLanguage;
        tsn_parser_delete($handle) if $handle.defined;
    }

    submethod DESTROY() { self.dispose }
}

# ====================================================================
# Tree
# ====================================================================

#| A parse result: the syntax tree plus the exact bytes it describes.
#|
#| Trees are independent of the parser that produced them and of each
#| other. Freeing one frees the whole tree, which invalidates every
#| C<Node> taken from it — hence the liveness check on node accessors.
#|
#|     my $tree = $parser.parse($source);
#|     say $tree.root-node.type;
#|     say $tree.bytes.elems;      # source length IN BYTES
#|     say $tree.source;           # the original Str, or Str for
#|                                 # parse-bytes trees
class Tree is export {
    has TSTree $!handle;

    #| The UTF-8 bytes this tree describes. Every byte offset the tree
    #| reports indexes into this buffer.
    has Blob $.bytes is required;

    #| The C<Str> the tree was parsed from, or the C<Str> type object
    #| for a tree parsed with C<parse-bytes>.
    has Str $.source;

    submethod BUILD(TSTree :$handle, Blob :$!bytes, Str :$!source) {
        $!handle = $handle;
    }

    method !live(--> TSTree:D) {
        $!handle // die "TreeSitter::Native::Tree: this tree has "
                      ~ "already been disposed.";
    }

    #| True once C<.dispose> (or C<DESTROY>) has run. Node accessors
    #| consult this before touching anything.
    method disposed(--> Bool) { !$!handle.defined }

    #| The tree's root node. Never undefined for a live tree.
    method root-node(--> Node) {
        my TSTree $handle = self!live;
        my TSNodeBuf $buf .= new;
        tsn_tree_root_node($handle, $buf);
        wrap-node($buf, self);
    }

    #| The grammar this tree was parsed with.
    method language(--> TSLanguage) { tsn_tree_language(self!live) }

    #| A fresh cursor positioned on the root node.
    method cursor(--> Cursor) { self.root-node.cursor }

    #| Byte length of the source. C<$tree.bytes.elems>, spelled to read
    #| like an offset.
    method byte-length(--> UInt) { $!bytes.elems }

    #| An independent copy of the tree, with its own C allocation and
    #| its own lifetime, sharing the same source buffer.
    method clone(--> Tree) {
        my TSTree $copy = tsn_tree_copy(self!live);
        unless $copy.defined {
            die "TreeSitter::Native::Tree: tree-sitter refused to copy "
              ~ "this tree (out of memory).";
        }
        Tree.new(:handle($copy), :$!bytes, :$!source);
    }

    #| Free the tree. Idempotent. Every C<Node> taken from it stops
    #| working — deliberately, and loudly — from here on.
    method dispose(--> Nil) {
        my TSTree $handle = $!handle;
        $!handle = TSTree;
        tsn_tree_delete($handle) if $handle.defined;
    }

    submethod DESTROY() { self.dispose }

    multi method gist(Tree:D: --> Str) {
        self.disposed
            ?? 'TreeSitter::Native::Tree(disposed)'
            !! "TreeSitter::Native::Tree({$!bytes.elems} bytes)";
    }
}

# ====================================================================
# Node
# ====================================================================

#| One node of a syntax tree: an immutable value object holding a copy
#| of tree-sitter's 32-byte node handle and a reference to the C<Tree>
#| it belongs to.
#|
#| Nodes are values, not identities. Two C<Node> objects naming the same
#| node of the same tree are C<===>, hash to the same slot and set-op
#| the same way, which is what makes graph building over a tree
#| pleasant:
#|
#|     my %seen;
#|     %seen{$_}++ for $root.walk;
#|
#| Navigation accessors return the C<Node> type object when there is no
#| such node — no parent, no next sibling, index past the end — so they
#| compose with C<with>, C<//> and C<andthen>:
#|
#|     with $node.child-by-field-name('name') -> $name {
#|         say $name.text;
#|     }
class Node is export {
    #| The raw 32-byte node handle. Do not write to it.
    has TSNodeBuf $.buf is required;

    #| The tree this node belongs to, held to keep it alive.
    has Tree $.tree is required;

    # Every accessor goes through here: a node whose tree has been
    # explicitly disposed points into freed memory, and reading it would
    # be a segfault rather than an exception.
    method !live(--> TSNodeBuf:D) {
        if $!tree.disposed {
            die "TreeSitter::Native::Node: this node's tree has been "
              ~ "disposed. Nodes are only valid while the Tree they "
              ~ "came from is alive.";
        }
        $!buf;
    }

    # Run a shim navigation call that writes into an out-buffer, and
    # wrap whatever it produced.
    method !navigate(&op --> Node) {
        my TSNodeBuf $out .= new;
        op(self!live, $out);
        wrap-node($out, $!tree);
    }

    # --- identity ---------------------------------------------------

    #| Value identity: the node's own address plus its tree's, which is
    #| exactly what tree-sitter's C<ts_node_eq> compares.
    method WHICH(--> ValueObjAt) {
        my $id   = $!buf.id;
        my $tree = $!buf.tree;
        ValueObjAt.new(
            'TreeSitter::Native::Node|'
            ~ ($id.defined   ?? $id.Int   !! 0) ~ '|'
            ~ ($tree.defined ?? $tree.Int !! 0)
        );
    }

    #| C<True> if C<$other> is the same node of the same tree. The same
    #| answer as C<===>, spelled for people who would rather call a
    #| method, and computed by tree-sitter rather than by us.
    method equals(Node $other --> Bool) {
        return False unless $other.defined;
        so tsn_node_eq(self!live, $other.buf);
    }

    #| The node's type as queries see it: C<'function_definition'>,
    #| C<'identifier'>, C<'"'>. Never undefined for a live node.
    method type(--> Str) { tsn_node_type(self!live) }

    #| The grammar's own name for this node, which differs from
    #| C<.type> only where a supertype aliases it.
    method grammar-type(--> Str) { tsn_node_grammar_type(self!live) }

    #| The numeric symbol id behind C<.type>, for when you are
    #| comparing against thousands of nodes and would rather not
    #| compare strings.
    method symbol(--> UInt) { tsn_node_symbol(self!live).Int }

    # --- predicates -------------------------------------------------

    #| C<True> for nodes the grammar gives a name to, C<False> for
    #| anonymous tokens like C<'('> and C<'+'>.
    method is-named(--> Bool)   { so tsn_node_is_named(self!live) }

    #| C<True> for a node tree-sitter inserted during error recovery to
    #| stand in for something the source was missing.
    method is-missing(--> Bool) { so tsn_node_is_missing(self!live) }

    #| C<True> for a node the grammar allows anywhere, such as a
    #| comment.
    method is-extra(--> Bool)   { so tsn_node_is_extra(self!live) }

    #| C<True> if this node I<is> an error node.
    method is-error(--> Bool)   { so tsn_node_is_error(self!live) }

    #| C<True> if this node or anything under it is an error or a
    #| missing node. The cheap way to ask "did this file parse?".
    method has-error(--> Bool)  { so tsn_node_has_error(self!live) }

    #| C<True> if this node has been edited since the tree was parsed.
    method has-changes(--> Bool) { so tsn_node_has_changes(self!live) }

    # --- position ---------------------------------------------------

    #| First byte of this node, as an offset into C<$tree.bytes>.
    method start-byte(--> UInt) { tsn_node_start_byte(self!live).Int }

    #| One past the last byte of this node.
    method end-byte(--> UInt)   { tsn_node_end_byte(self!live).Int }

    #| C<end-byte - start-byte>.
    method byte-length(--> UInt) { self.end-byte - self.start-byte }

    #| Zero-based row and B<byte> column of the node's first byte.
    method start-point(--> Point) {
        my TSNodeBuf $buf = self!live;
        my uint32 ($row, $column);
        tsn_node_start_point($buf, $row, $column);
        Point.new(:row($row.Int), :column($column.Int));
    }

    #| Zero-based row and B<byte> column one past the node's last byte.
    method end-point(--> Point) {
        my TSNodeBuf $buf = self!live;
        my uint32 ($row, $column);
        tsn_node_end_point($buf, $row, $column);
        Point.new(:row($row.Int), :column($column.Int));
    }

    # --- text -------------------------------------------------------

    #| The node's bytes, sliced out of the tree's source buffer. Always
    #| safe, even when those bytes are not valid UTF-8.
    method byte-slice(--> Blob) {
        my UInt $start = self.start-byte;
        my UInt $end   = self.end-byte;
        my UInt $limit = $!tree.bytes.elems;
        $start = $limit if $start > $limit;
        $end   = $limit if $end   > $limit;
        $end   = $start if $end   < $start;
        $!tree.bytes.subbuf($start, $end - $start);
    }

    #| The node's source text: C<.byte-slice> decoded as UTF-8.
    #|
    #|     say $node.text;      # greet
    #|
    #| Throws if those bytes are not valid UTF-8, which can only happen
    #| for a tree built by C<parse-bytes> from a buffer that was not
    #| UTF-8 to begin with. Use C<.byte-slice> when you need to survive
    #| that.
    method text(--> Str) { self.byte-slice.decode('utf-8') }

    #| A debugging S-expression of the whole subtree, from tree-sitter.
    #| Big for big nodes — this is a debugging aid, not a serialisation
    #| format.
    #|
    #|     say $root.sexp;
    #|     # (module (function_definition name: (identifier) …))
    method sexp(--> Str) { tsn-owned-str(tsn_node_string(self!live)) }

    # --- navigation -------------------------------------------------

    #| Total children, named and anonymous.
    method child-count(--> UInt) { tsn_node_child_count(self!live).Int }

    #| Children the grammar names, excluding punctuation and keywords.
    method named-child-count(--> UInt) {
        tsn_node_named_child_count(self!live).Int;
    }

    #| The C<$index>th child, or the C<Node> type object if there is
    #| none.
    method child(Int:D $index --> Node) {
        return Node if $index < 0;
        self!navigate(-> $b, $o { tsn_node_child($b, $index, $o) });
    }

    #| The C<$index>th B<named> child, or the C<Node> type object.
    method named-child(Int:D $index --> Node) {
        return Node if $index < 0;
        self!navigate(-> $b, $o { tsn_node_named_child($b, $index, $o) });
    }

    #| All children, in source order.
    method children(--> Seq) {
        my UInt $n = self.child-count;
        (^$n).map({ self.child($_) });
    }

    #| All named children, in source order.
    method named-children(--> Seq) {
        my UInt $n = self.named-child-count;
        (^$n).map({ self.named-child($_) });
    }

    #| The enclosing node, or the C<Node> type object at the root.
    method parent(--> Node) {
        self!navigate(-> $b, $o { tsn_node_parent($b, $o) });
    }

    method next-sibling(--> Node) {
        self!navigate(-> $b, $o { tsn_node_next_sibling($b, $o) });
    }

    method prev-sibling(--> Node) {
        self!navigate(-> $b, $o { tsn_node_prev_sibling($b, $o) });
    }

    method next-named-sibling(--> Node) {
        self!navigate(-> $b, $o { tsn_node_next_named_sibling($b, $o) });
    }

    method prev-named-sibling(--> Node) {
        self!navigate(-> $b, $o { tsn_node_prev_named_sibling($b, $o) });
    }

    #| The child filling a named field, or the C<Node> type object.
    #| Fields are the grammar's own labels — C<name>, C<body>,
    #| C<condition> — and are the readable way to reach into a node:
    #|
    #|     $def.child-by-field-name('name').text;
    method child-by-field-name(Str:D $field --> Node) {
        my Blob $bytes = $field.encode('utf-8');
        return Node unless $bytes.elems;
        self!navigate(-> $b, $o {
            tsn_node_child_by_field_name($b, $bytes, $bytes.elems, $o);
        });
    }

    #| The field name the C<$index>th child fills, or the C<Str> type
    #| object if it fills none.
    method field-name-for-child(Int:D $index --> Str) {
        return Str if $index < 0;
        tsn_node_field_name_for_child(self!live, $index);
    }

    #| The smallest node covering C<[$start, $end)>, or the C<Node>
    #| type object if the range falls outside this node.
    method descendant-for-byte-range(UInt:D $start, UInt:D $end --> Node) {
        self!navigate(-> $b, $o {
            tsn_node_descendant_for_byte_range($b, $start, $end, $o);
        });
    }

    #| As C<descendant-for-byte-range>, but skipping anonymous nodes.
    method named-descendant-for-byte-range(UInt:D $start, UInt:D $end
                                           --> Node) {
        self!navigate(-> $b, $o {
            tsn_node_named_descendant_for_byte_range($b, $start, $end, $o);
        });
    }

    #| Pre-order traversal of this node and everything under it,
    #| including anonymous nodes, as a lazy C<Seq>.
    #|
    #|     my @calls = $root.walk.grep(*.type eq 'call').eager;
    #|
    #| Allocates a C<Node> per step. C<Node.cursor.walk> yields the
    #| same nodes in the same order without the intermediate objects,
    #| and is what to reach for on big files.
    method walk(--> Seq) {
        my sub descend(Node:D $node) {
            take $node;
            descend($_) for $node.children;
        }
        gather { descend(self) }
    }

    #| Pre-order traversal of the named nodes only.
    method named-walk(--> Seq) {
        my sub descend(Node:D $node) {
            take $node;
            descend($_) for $node.named-children;
        }
        gather { descend(self) }
    }

    #| A fresh tree cursor positioned on this node. The cursor's depths
    #| are relative to it: C<current-depth> is 0 here.
    method cursor(--> Cursor) {
        Cursor.new(:node(self));
    }

    multi method gist(Node:D: --> Str) {
        return 'TreeSitter::Native::Node(<tree disposed>)'
            if $!tree.disposed;
        "({self.type} {self.start-byte}..{self.end-byte})";
    }

    multi method Str(Node:D: --> Str) { self.gist }
}

# ====================================================================
# Cursor
# ====================================================================

#| A stateful position in a tree. Where C<Node> navigation allocates a
#| new node handle per step, a cursor moves in place, which is what you
#| want for a full-file walk.
#|
#| Not exported — Raku's core already binds C<Cursor> — so build one
#| with C<Node.cursor> or C<Tree.cursor>, or name it in full as
#| C<TreeSitter::Native::Cursor>.
#|
#|     my $c = $tree.cursor;
#|     LEAVE $c.dispose;
#|
#|     while $c.goto-first-child {
#|         say '  ' x $c.current-depth,
#|             $c.current-field-name // '-', ' ', $c.current-node.type;
#|     }
#|
#| Depths are relative to the node the cursor started on: that node is
#| depth 0, and the cursor will not climb above it.
class Cursor {
    has TSTreeCursor $!handle;

    #| The tree being walked, held to keep it alive.
    has Tree $.tree is required;

    submethod BUILD(TSTreeCursor :$handle, Tree :$!tree) {
        $!handle = $handle;
    }

    #| Create a cursor on C<$node>.
    method new(Node:D :$node!) {
        my TSTreeCursor $handle = tsn_cursor_new($node.buf);
        unless $handle.defined {
            die "TreeSitter::Native::Cursor: could not allocate a "
              ~ "cursor for {$node.gist}.";
        }
        self.bless(:$handle, :tree($node.tree));
    }

    method !live(--> TSTreeCursor:D) {
        if $!tree.disposed {
            die "TreeSitter::Native::Cursor: this cursor's tree has "
              ~ "been disposed.";
        }
        $!handle // die "TreeSitter::Native::Cursor: this cursor has "
                      ~ "already been disposed.";
    }

    #| True once C<.dispose> (or C<DESTROY>) has run.
    method disposed(--> Bool) { !$!handle.defined }

    #| The node the cursor is on.
    method current-node(--> Node) {
        my TSNodeBuf $buf .= new;
        tsn_cursor_current_node(self!live, $buf);
        wrap-node($buf, $!tree);
    }

    #| The field name the current node fills in its parent, or the
    #| C<Str> type object if it fills none.
    method current-field-name(--> Str) {
        tsn_cursor_current_field_name(self!live);
    }

    #| Depth below the node the cursor was created on or last reset to.
    method current-depth(--> UInt) {
        tsn_cursor_current_depth(self!live).Int;
    }

    #| Move to the first child. C<False>, and no movement, if there is
    #| none.
    method goto-first-child(--> Bool) {
        so tsn_cursor_goto_first_child(self!live);
    }

    #| Move to the next sibling. C<False>, and no movement, if there is
    #| none.
    method goto-next-sibling(--> Bool) {
        so tsn_cursor_goto_next_sibling(self!live);
    }

    #| Move to the parent. C<False>, and no movement, at the node the
    #| cursor started from.
    method goto-parent(--> Bool) {
        so tsn_cursor_goto_parent(self!live);
    }

    #| Re-aim the cursor at C<$node>, which becomes its new depth 0.
    #| Cheaper than allocating a second cursor.
    method reset(Node:D $node --> Nil) {
        tsn_cursor_reset(self!live, $node.buf);
    }

    #| Pre-order traversal from the cursor's current position, as a
    #| lazy C<Seq>.
    #|
    #|     my $c = $tree.cursor;
    #|     LEAVE $c.dispose;
    #|     for $c.walk -> $node { … }
    #|
    #| This B<drives the cursor>: it is the cursor's position that
    #| advances, so do not interleave C<walk> with your own C<goto->
    #| calls, and do not walk the same cursor twice without a C<reset>
    #| in between. Yields the same nodes in the same order as
    #| C<Node.walk>.
    method walk(--> Seq) {
        self!live;              # fail now, not on first consumption
        my $cursor = self;
        gather {
            take $cursor.current-node;
            my Bool $running = True;
            while $running {
                if $cursor.goto-first-child {
                    take $cursor.current-node;
                    next;
                }
                # No children: take the next sibling, climbing until
                # one exists. Never climb past the starting node —
                # its siblings are outside the walk.
                my Bool $moved = False;
                until $moved {
                    if $cursor.current-depth == 0 {
                        $running = False;
                        $moved   = True;
                    }
                    elsif $cursor.goto-next-sibling {
                        take $cursor.current-node;
                        $moved = True;
                    }
                    elsif !$cursor.goto-parent {
                        $running = False;
                        $moved   = True;
                    }
                }
            }
        }
    }

    #| Free the cursor. Idempotent.
    method dispose(--> Nil) {
        my TSTreeCursor $handle = $!handle;
        $!handle = TSTreeCursor;
        tsn_cursor_delete($handle) if $handle.defined;
    }

    submethod DESTROY() { self.dispose }

    multi method gist(Cursor:D: --> Str) {
        self.disposed
            ?? 'TreeSitter::Native::Cursor(disposed)'
            !! "TreeSitter::Native::Cursor(depth {self.current-depth})";
    }
}
