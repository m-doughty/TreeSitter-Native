use v6.d;

unit module TreeSitter::Native::FFI;

use NativeCall;

=begin pod

=head1 NAME

TreeSitter::Native::FFI - raw NativeCall bindings for libtreesitter-native

=head1 DESCRIPTION

One Raku C<sub> per exported C<tsn_*> function in C<src/ts_shim.h>, plus
the handle types they traffic in. Nothing here has an opinion: no RAII,
no encoding, no null checks beyond what the shim already does. Reach for
L<TreeSitter::Native> and L<TreeSitter::Native::Query> unless you are
implementing something they do not cover.

C<src/ts_shim.h> is the contract. If a signature here and a declaration
there disagree, the header wins and this file is a bug.

=head2 Nodes cross as buffers

tree-sitter returns C<TSNode> by value everywhere, and NativeCall cannot
express that. The shim takes a caller-allocated 32-byte buffer instead —
C<const void *> going in, C<void *> coming out — and C<memcpy>s through
it. C<TSNodeBuf> is that buffer: a C<CStruct> whose only job is to be
exactly C<sizeof(TSNode)> bytes of writable memory.

Allocate a fresh one for every node you want to keep. They are plain
memory with no lifetime of their own, but the C<TSTree> whose bytes they
hold must outlive them, which is why L<TreeSitter::Native>'s C<Node>
keeps a reference to its C<Tree>.

    use TreeSitter::Native::FFI;

    my $parser = tsn_parser_new;
    tsn_parser_set_language($parser, tsn_lang_python);

    my Blob $src = "def f(): pass".encode('utf-8');
    my $tree = tsn_parser_parse_utf8($parser, TSTree, $src, $src.elems);

    my $root = TSNodeBuf.new;
    tsn_tree_root_node($tree, $root);
    say tsn_node_type($root);          # module

    tsn_tree_delete($tree);
    tsn_parser_delete($parser);

=head2 Out-params

Anything the C API returns by value as a pair of scalars — points, query
errors, predicate steps — comes back through C<is rw> parameters:

    my uint32 ($row, $col);
    tsn_node_start_point($root, $row, $col);

=head2 Strings

Borrowed C<const char *> returns are declared C<--> Str> and are copied
into a Raku C<Str> by NativeCall; nothing needs freeing. The two that may
contain embedded NULs (capture names, query string literals) and the one
that is malloc'd (C<tsn_node_string>) are declared C<--> Pointer[uint8]>
instead, because C<Str> would truncate at the first NUL and would give
you nothing to hand back to C<tsn_free_string>. Decode them with
C<tsn-borrowed-str> and C<tsn-owned-str>.

=end pod

# === Library resolution =============================================
#
# Resolution order, and only these two:
#
#   1. $TREESITTER_NATIVE_LIB — an explicit, ABSOLUTE path to a
#      libtreesitter-native built elsewhere. Handed to dlopen /
#      LoadLibrary VERBATIM (see below), so it must be a real path to
#      a real file; a relative path or a missing file is a hard error
#      rather than a silent fall-through, because someone who sets
#      this variable means it.
#   2. %?RESOURCES<lib/libtreesitter-native.EXT> — the copy
#      Build.rakumod staged at install time, either downloaded from
#      the pinned binary release or compiled from the pinned sources.
#      This is the path every ordinary install takes.
#
# There is no system-library probe and there never will be: the shim
# symbols only exist in a library this distribution built, so a
# "libtreesitter-native" found on $LD_LIBRARY_PATH would be either ours
# or a stranger's, and we cannot tell which.
#
# Every binding below uses the CALLABLE form of the trait — `is
# native(&_libpath)`. NativeCall hands a Callable's return value to
# dlopen() verbatim, with no 'lib' prefix and no extension guessing,
# which is exactly what we want for an absolute path. The *string* form
# would mangle the name. The trait is resolved lazily, on the first call
# to each sub, so merely loading this module does not open anything —
# the load-time size assertion at the bottom of this file is what forces
# the library open.
#
# _libpath is a state-cached SUB rather than a `constant` on purpose. A
# `constant` is computed at COMPILE time and frozen into the precompiled
# bytecode, so a library staged at a different path after precompilation
# — a reinstall, a moved home directory, a CI cache restore — would
# still be looked for at the old one. The sub recomputes on first use in
# each fresh process and caches for the rest of it.

#| Shared-library extension for a platform: 'dylib' on macOS, 'dll' on
#| Windows, 'so' everywhere else. Taken as parameters rather than read
#| from C<$*KERNEL> so it can be exercised for all three platforms from
#| any host.
my sub _lib-extension(Str:D $kernel-name, Bool:D $is-win --> Str)
    is export(:INTERNAL)
{
    return 'dll' if $is-win;
    return 'dylib' if $kernel-name.lc.contains('darwin');
    'so';
}

#| Basename of the staged library for a platform, matching what
#| Build.rakumod writes into C<resources/lib/>.
my sub _lib-basename(Str:D $kernel-name, Bool:D $is-win --> Str)
    is export(:INTERNAL)
{
    'libtreesitter-native.' ~ _lib-extension($kernel-name, $is-win);
}

#| The resolution policy itself, as a pure function of its inputs:
#| C<$override> is the raw C<$TREESITTER_NATIVE_LIB> value (C<Str>
#| type object or empty string when unset) and C<$staged> is the path
#| C<%?RESOURCES> produced.
#|
#| Returns an absolute path. Dies — loudly, naming the variable or the
#| reinstall — rather than returning something dlopen would fail on in
#| a less informative way.
#|
#|     _pick-libpath('/opt/ts/libtreesitter-native.dylib', $staged)
#|     # → '/opt/ts/libtreesitter-native.dylib'
#|
#| The staged file is checked for non-zero size as well as existence:
#| Build.rakumod parks EMPTY placeholder files under the two library
#| names this platform is not, so that META6.json's `resources` list is
#| satisfiable everywhere. An empty file that dlopen rejects with
#| "invalid image" is a much worse error message than this one.
my sub _pick-libpath(Str $override, Str $staged --> Str)
    is export(:INTERNAL)
{
    if $override.defined && $override.trim.chars {
        my Str $path = $override.trim;
        unless $path.IO.is-absolute {
            die "TREESITTER_NATIVE_LIB must be an absolute path to a "
              ~ "shared library (got '$path'). NativeCall hands this "
              ~ "value to the dynamic loader verbatim, so a relative "
              ~ "path resolves against the loader's search list rather "
              ~ "than the current directory.";
        }
        unless $path.IO.f {
            die "TREESITTER_NATIVE_LIB points at '$path', which is not "
              ~ "a readable file.";
        }
        return $path;
    }

    unless $staged.defined && $staged.chars && $staged.IO.f {
        die "TreeSitter::Native: the bundled library was not found at "
          ~ "'{$staged // '<unset>'}'. Reinstall the distribution so "
          ~ "Build.rakumod can stage it (zef install --force-install "
          ~ "TreeSitter::Native), or point TREESITTER_NATIVE_LIB at a "
          ~ "copy you built yourself.";
    }

    unless $staged.IO.s {
        die "TreeSitter::Native: the bundled library at '$staged' is "
          ~ "empty. That file is the placeholder Build.rakumod stages "
          ~ "for the platforms this machine is not, which means the "
          ~ "install never produced a library for "
          ~ "{$*KERNEL.name}-{$*KERNEL.hardware}. Reinstall with "
          ~ "TREESITTER_NATIVE_BUILD_FROM_SOURCE=1, or point "
          ~ "TREESITTER_NATIVE_LIB at a copy you built yourself.";
    }

    $staged.IO.absolute;
}

# File-scoped rather than `state` inside _libpath: a `state $x = …`
# initialiser only runs when execution reaches its declaration, so a
# sub that can die before that point would be left with an undefined
# state slot for the rest of the process.
my $LIBPATH-LOCK = Lock.new;

#| Absolute path of the native library, resolved once per process.
sub _libpath(--> Str) is export(:INTERNAL) {
    state Str $cached;
    $LIBPATH-LOCK.protect: {
        $cached //= _pick-libpath(
            # An unset environment variable reads back as Any, which
            # would not bind to _pick-libpath's Str parameter.
            %*ENV<TREESITTER_NATIVE_LIB> // Str,
            do {
                my Str $name =
                    _lib-basename($*KERNEL.name, $*DISTRO.is-win);
                my $res = %?RESOURCES{"lib/$name"};
                # .IO, not .absolute: Distribution::Resource.absolute
                # is deprecated and warns on every load.
                $res.defined ?? $res.IO.absolute !! Str;
            },
        );
    }
    $cached;
}

# === Opaque handles ==================================================
#
# All five are tree-sitter's own opaque pointers, or (for the cursor and
# the match record) shim-owned heap boxes around a by-value type. Raku
# never dereferences any of them; CPointer is the whole binding.

#| A compiled grammar. Immortal and borrowed — the C<tsn_lang_*> getters
#| hand back pointers into static data, and there is nothing to free.
class TSLanguage    is repr('CPointer') is export { }

#| A parser. Owns its language setting and its scratch state; free with
#| C<tsn_parser_delete>.
class TSParser      is repr('CPointer') is export { }

#| A parsed syntax tree. Independent of the parser that produced it and
#| outlives it happily; free with C<tsn_tree_delete>.
class TSTree        is repr('CPointer') is export { }

#| A compiled query. Free with C<tsn_query_delete>.
class TSQuery       is repr('CPointer') is export { }

#| Query execution state, including the current match's capture array.
#| Free with C<tsn_query_cursor_delete>.
class TSQueryCursor is repr('CPointer') is export { }

#| Heap-boxed C<TSTreeCursor>. Allocated by C<tsn_cursor_new> and freed
#| by C<tsn_cursor_delete>, which also runs tree-sitter's own destructor
#| — the size of the boxed struct is the shim's business, not ours.
class TSTreeCursor  is repr('CPointer') is export { }

#| Heap-boxed C<TSQueryMatch>. Allocate one with C<tsn_match_new>, reuse
#| it for a whole iteration, free it with C<tsn_match_delete>. The
#| capture array it points at belongs to the query cursor and is
#| invalidated by the next C<tsn_query_cursor_next_match>.
class TSQueryMatch  is repr('CPointer') is export { }

#| Caller-allocated storage for one C<TSNode>: four C<uint32> of opaque
#| context followed by two pointers, 32 bytes on every platform this
#| distribution ships to.
#|
#| The attributes exist to make the layout — and therefore
#| C<nativesizeof> — right. Nothing in this distribution reads them; the
#| bytes are tree-sitter's and are only ever handed straight back to it.
#| The load-time assertion at the foot of this file checks the size
#| against the compiled library's own C<sizeof(TSNode)>, which is the
#| one thing standing between an upstream layout change and silent
#| memory corruption.
#|
#|     my $buf = TSNodeBuf.new;      # 32 bytes of writable memory
#|     tsn_tree_root_node($tree, $buf);
class TSNodeBuf is repr('CStruct') is export {
    has uint32  $.context0;
    has uint32  $.context1;
    has uint32  $.context2;
    has uint32  $.context3;
    has Pointer $.id;
    has Pointer $.tree;
}

# === Meta ============================================================

sub tsn_shim_abi_version(--> uint32)
    is native(&_libpath) is export { * }
sub tsn_node_size(--> uint32)
    is native(&_libpath) is export { * }
sub tsn_runtime_abi_version(--> uint32)
    is native(&_libpath) is export { * }
sub tsn_min_compatible_abi(--> uint32)
    is native(&_libpath) is export { * }
sub tsn_language_abi_supported(uint32 --> int32)
    is native(&_libpath) is export { * }

# === Bundled languages ===============================================

sub tsn_lang_c(--> TSLanguage)
    is native(&_libpath) is export { * }
sub tsn_lang_cpp(--> TSLanguage)
    is native(&_libpath) is export { * }
sub tsn_lang_python(--> TSLanguage)
    is native(&_libpath) is export { * }
sub tsn_lang_javascript(--> TSLanguage)
    is native(&_libpath) is export { * }
sub tsn_lang_typescript(--> TSLanguage)
    is native(&_libpath) is export { * }
sub tsn_lang_tsx(--> TSLanguage)
    is native(&_libpath) is export { * }
sub tsn_lang_go(--> TSLanguage)
    is native(&_libpath) is export { * }
sub tsn_lang_rust(--> TSLanguage)
    is native(&_libpath) is export { * }
sub tsn_lang_java(--> TSLanguage)
    is native(&_libpath) is export { * }

# === Language introspection ==========================================

sub tsn_language_abi(TSLanguage --> uint32)
    is native(&_libpath) is export { * }
sub tsn_language_symbol_count(TSLanguage --> uint32)
    is native(&_libpath) is export { * }
sub tsn_language_field_count(TSLanguage --> uint32)
    is native(&_libpath) is export { * }
sub tsn_language_symbol_name(TSLanguage, uint16 --> Str)
    is native(&_libpath) is export { * }
sub tsn_language_field_name_for_id(TSLanguage, uint16 --> Str)
    is native(&_libpath) is export { * }

# === Parser ==========================================================

sub tsn_parser_new(--> TSParser)
    is native(&_libpath) is export { * }
sub tsn_parser_delete(TSParser)
    is native(&_libpath) is export { * }
sub tsn_parser_set_language(TSParser, TSLanguage --> int32)
    is native(&_libpath) is export { * }

#| Parse C<$len> bytes of UTF-8. Pass the C<TSTree> type object for
#| C<$old-tree> to parse from scratch. The C<Blob> is passed as a
#| pointer to its own memory — no copy — so it must stay reachable for
#| the duration of the call, and for as long as you intend to resolve
#| node text from the resulting tree's byte offsets.
sub tsn_parser_parse_utf8(TSParser, TSTree, Blob, uint32 --> TSTree)
    is native(&_libpath) is export { * }
sub tsn_parser_reset(TSParser)
    is native(&_libpath) is export { * }

# === Tree ============================================================

sub tsn_tree_delete(TSTree)
    is native(&_libpath) is export { * }
sub tsn_tree_copy(TSTree --> TSTree)
    is native(&_libpath) is export { * }
sub tsn_tree_root_node(TSTree, TSNodeBuf)
    is native(&_libpath) is export { * }
sub tsn_tree_language(TSTree --> TSLanguage)
    is native(&_libpath) is export { * }

#| C<TSInputEdit> flattened into scalars: start byte, old end byte, new
#| end byte, then the three matching row/column pairs.
sub tsn_tree_edit(TSTree, uint32, uint32, uint32,
                  uint32, uint32, uint32, uint32, uint32, uint32)
    is native(&_libpath) is export { * }

# === Node: predicates ================================================

sub tsn_node_is_null(TSNodeBuf --> int32)
    is native(&_libpath) is export { * }
sub tsn_node_is_named(TSNodeBuf --> int32)
    is native(&_libpath) is export { * }
sub tsn_node_is_missing(TSNodeBuf --> int32)
    is native(&_libpath) is export { * }
sub tsn_node_is_extra(TSNodeBuf --> int32)
    is native(&_libpath) is export { * }
sub tsn_node_is_error(TSNodeBuf --> int32)
    is native(&_libpath) is export { * }
sub tsn_node_has_error(TSNodeBuf --> int32)
    is native(&_libpath) is export { * }
sub tsn_node_has_changes(TSNodeBuf --> int32)
    is native(&_libpath) is export { * }
sub tsn_node_eq(TSNodeBuf, TSNodeBuf --> int32)
    is native(&_libpath) is export { * }

# === Node: position ==================================================

sub tsn_node_start_byte(TSNodeBuf --> uint32)
    is native(&_libpath) is export { * }
sub tsn_node_end_byte(TSNodeBuf --> uint32)
    is native(&_libpath) is export { * }
sub tsn_node_start_point(TSNodeBuf, uint32 is rw, uint32 is rw)
    is native(&_libpath) is export { * }
sub tsn_node_end_point(TSNodeBuf, uint32 is rw, uint32 is rw)
    is native(&_libpath) is export { * }

# === Node: identity ==================================================

sub tsn_node_type(TSNodeBuf --> Str)
    is native(&_libpath) is export { * }
sub tsn_node_symbol(TSNodeBuf --> uint16)
    is native(&_libpath) is export { * }
sub tsn_node_grammar_type(TSNodeBuf --> Str)
    is native(&_libpath) is export { * }

# === Node: navigation ================================================

sub tsn_node_parent(TSNodeBuf, TSNodeBuf)
    is native(&_libpath) is export { * }
sub tsn_node_child(TSNodeBuf, uint32, TSNodeBuf)
    is native(&_libpath) is export { * }
sub tsn_node_named_child(TSNodeBuf, uint32, TSNodeBuf)
    is native(&_libpath) is export { * }
sub tsn_node_child_count(TSNodeBuf --> uint32)
    is native(&_libpath) is export { * }
sub tsn_node_named_child_count(TSNodeBuf --> uint32)
    is native(&_libpath) is export { * }
sub tsn_node_next_sibling(TSNodeBuf, TSNodeBuf)
    is native(&_libpath) is export { * }
sub tsn_node_prev_sibling(TSNodeBuf, TSNodeBuf)
    is native(&_libpath) is export { * }
sub tsn_node_next_named_sibling(TSNodeBuf, TSNodeBuf)
    is native(&_libpath) is export { * }
sub tsn_node_prev_named_sibling(TSNodeBuf, TSNodeBuf)
    is native(&_libpath) is export { * }

#| The field name is passed as bytes plus an explicit length; it need
#| not be NUL-terminated.
sub tsn_node_child_by_field_name(TSNodeBuf, Blob, uint32, TSNodeBuf)
    is native(&_libpath) is export { * }
sub tsn_node_field_name_for_child(TSNodeBuf, uint32 --> Str)
    is native(&_libpath) is export { * }
sub tsn_node_descendant_for_byte_range(TSNodeBuf, uint32, uint32,
                                       TSNodeBuf)
    is native(&_libpath) is export { * }
sub tsn_node_named_descendant_for_byte_range(TSNodeBuf, uint32, uint32,
                                             TSNodeBuf)
    is native(&_libpath) is export { * }

#| OWNED. Decode with C<tsn-owned-str>, which frees it for you.
sub tsn_node_string(TSNodeBuf --> Pointer[uint8])
    is native(&_libpath) is export { * }

# === Tree cursor =====================================================

sub tsn_cursor_new(TSNodeBuf --> TSTreeCursor)
    is native(&_libpath) is export { * }
sub tsn_cursor_delete(TSTreeCursor)
    is native(&_libpath) is export { * }
sub tsn_cursor_reset(TSTreeCursor, TSNodeBuf)
    is native(&_libpath) is export { * }
sub tsn_cursor_current_node(TSTreeCursor, TSNodeBuf)
    is native(&_libpath) is export { * }
sub tsn_cursor_current_field_name(TSTreeCursor --> Str)
    is native(&_libpath) is export { * }
sub tsn_cursor_goto_first_child(TSTreeCursor --> int32)
    is native(&_libpath) is export { * }
sub tsn_cursor_goto_next_sibling(TSTreeCursor --> int32)
    is native(&_libpath) is export { * }
sub tsn_cursor_goto_parent(TSTreeCursor --> int32)
    is native(&_libpath) is export { * }
sub tsn_cursor_current_depth(TSTreeCursor --> uint32)
    is native(&_libpath) is export { * }

# === Query ===========================================================

#| Compile a query. On failure returns the C<TSQuery> type object and
#| writes the byte offset and C<QueryErrorKind> value of the first
#| problem into the two out-params.
sub tsn_query_new(TSLanguage, Blob, uint32,
                  uint32 is rw, uint32 is rw --> TSQuery)
    is native(&_libpath) is export { * }
sub tsn_query_delete(TSQuery)
    is native(&_libpath) is export { * }
sub tsn_query_pattern_count(TSQuery --> uint32)
    is native(&_libpath) is export { * }
sub tsn_query_capture_count(TSQuery --> uint32)
    is native(&_libpath) is export { * }
sub tsn_query_string_count(TSQuery --> uint32)
    is native(&_libpath) is export { * }

#| BORROWED, and may contain embedded NULs — hence the length out-param
#| and the C<Pointer> return. Decode with C<tsn-borrowed-str>.
sub tsn_query_capture_name_for_id(TSQuery, uint32, uint32 is rw
                                  --> Pointer[uint8])
    is native(&_libpath) is export { * }
sub tsn_query_string_value_for_id(TSQuery, uint32, uint32 is rw
                                  --> Pointer[uint8])
    is native(&_libpath) is export { * }
sub tsn_query_predicate_step_count(TSQuery, uint32 --> uint32)
    is native(&_libpath) is export { * }
sub tsn_query_predicate_step(TSQuery, uint32, uint32,
                             uint32 is rw, uint32 is rw --> int32)
    is native(&_libpath) is export { * }
sub tsn_query_start_byte_for_pattern(TSQuery, uint32 --> uint32)
    is native(&_libpath) is export { * }

# === Query cursor and matches ========================================

sub tsn_query_cursor_new(--> TSQueryCursor)
    is native(&_libpath) is export { * }
sub tsn_query_cursor_delete(TSQueryCursor)
    is native(&_libpath) is export { * }
sub tsn_query_cursor_exec(TSQueryCursor, TSQuery, TSNodeBuf)
    is native(&_libpath) is export { * }
sub tsn_query_cursor_set_byte_range(TSQueryCursor, uint32, uint32
                                    --> int32)
    is native(&_libpath) is export { * }
sub tsn_match_new(--> TSQueryMatch)
    is native(&_libpath) is export { * }
sub tsn_match_delete(TSQueryMatch)
    is native(&_libpath) is export { * }
sub tsn_query_cursor_next_match(TSQueryCursor, TSQueryMatch --> int32)
    is native(&_libpath) is export { * }
sub tsn_match_pattern_index(TSQueryMatch --> uint32)
    is native(&_libpath) is export { * }
sub tsn_match_capture_count(TSQueryMatch --> uint32)
    is native(&_libpath) is export { * }
sub tsn_match_capture(TSQueryMatch, uint32, uint32 is rw, TSNodeBuf
                      --> int32)
    is native(&_libpath) is export { * }

# === Memory ==========================================================

sub tsn_free_string(Pointer)
    is native(&_libpath) is export { * }

# === String helpers ==================================================

#| Decode exactly C<$len> bytes from a borrowed C<const char *>.
#|
#| Used for capture names and query string literals, which tree-sitter
#| reports with an explicit length precisely because they may contain
#| embedded NULs — a query can match a literal C<"\0">, and C<Str>'s
#| NUL-terminated decoding would silently truncate at it.
#|
#|     my uint32 $len;
#|     my $p = tsn_query_capture_name_for_id($q, 0, $len);
#|     say tsn-borrowed-str($p, $len);      # 'name'
#|
#| Returns the C<Str> type object for a NULL pointer.
sub tsn-borrowed-str(Pointer $ptr, Int() $len --> Str) is export {
    return Str unless $ptr.defined && $ptr.Int;
    return '' unless $len > 0;
    my $bytes = nativecast(CArray[uint8], $ptr);
    Buf[uint8].new($bytes[^$len]).decode('utf-8');
}

#| Decode a malloc'd, NUL-terminated C<char *> and free it. The only
#| producer is C<tsn_node_string>.
#|
#|     say tsn-owned-str(tsn_node_string($buf));
#|     # (module (function_definition name: (identifier) …))
#|
#| Returns the C<Str> type object for a NULL pointer, and frees nothing
#| in that case — C<tsn_free_string> tolerates NULL, but there is no
#| point calling it.
sub tsn-owned-str(Pointer $ptr --> Str) is export {
    return Str unless $ptr.defined && $ptr.Int;
    my Str $decoded = nativecast(Str, $ptr);
    tsn_free_string($ptr);
    $decoded;
}

# === Load-time layout assertion ======================================
#
# The one check that keeps a silent memory-corruption bug from an
# upstream TSNode layout change. It runs when this module is loaded,
# which also means the library is opened here rather than at some
# arbitrary later first call — a missing or unstageable library
# announces itself at `use` time with _pick-libpath's message.
{
    my Int $native = tsn_node_size().Int;
    my Int $raku   = nativesizeof(TSNodeBuf);
    unless $native == $raku {
        die "TreeSitter::Native::FFI: sizeof(TSNode) is $native bytes "
          ~ "in {_libpath()}, but TSNodeBuf is $raku bytes. The node "
          ~ "buffers this binding allocates would be the wrong size, "
          ~ "so every navigation call would read or write past their "
          ~ "end. Refusing to load. This means the installed library "
          ~ "was built from a tree-sitter whose TSNode layout differs "
          ~ "from the one this release was written against — "
          ~ "reinstall TreeSitter::Native so Build.rakumod stages a "
          ~ "matching library.";
    }
}
