/*
 * ts_shim.h — public surface of libtreesitter-native.
 *
 * This header exists for documentation only. Raku's NativeCall doesn't
 * read C headers; lib/TreeSitter/Native/FFI.rakumod declares each
 * symbol below directly. Keep the signatures here in sync with that
 * file — they are the contract, and nothing checks them for you except
 * the load-time size assertion described under "TSNode buffers".
 *
 * ---------------------------------------------------------------------
 * Why a shim exists at all
 * ---------------------------------------------------------------------
 *
 * tree-sitter's C API passes and returns small structs by value all
 * over the place: TSNode (32 bytes) is the return type of every
 * navigation function, TSPoint comes back from the position accessors,
 * TSTreeCursor is returned by value from ts_tree_cursor_new, and
 * TSQueryMatch is filled in through a pointer to a struct whose
 * `captures` member points at an array of by-value TSQueryCapture.
 *
 * NativeCall cannot pass or return a struct by value. Every function
 * here exists to turn one of those by-value shapes into something FFI
 * can express: an out-pointer, a pair of scalar out-params, or an
 * opaque heap pointer.
 *
 * The shim adds no policy. It does not cache, it does not allocate
 * trees or parsers behind the caller's back, and it does not second-
 * guess tree-sitter's own lifetime rules. Anything that looks like a
 * decision (UTF-8 only, byte offsets only) is stated below and is
 * mirrored by the Raku layer rather than hidden by it.
 *
 * ---------------------------------------------------------------------
 * TSNode buffers
 * ---------------------------------------------------------------------
 *
 * TSNode is `{ uint32_t context[4]; const void *id; const TSTree *tree; }`
 * — 32 bytes on every 64-bit platform we ship. The shim never passes it
 * by value. Instead:
 *
 *   - Functions that CONSUME a node take `const void *node`: a pointer
 *     to a caller-allocated 32-byte buffer holding a TSNode's bytes.
 *   - Functions that PRODUCE a node take `void *out_node`: a pointer to
 *     a caller-allocated 32-byte buffer the shim memcpy's into.
 *
 * The buffers are plain memory. The shim memcpy's in and out rather
 * than casting, so the caller's buffer needs no particular alignment
 * and no strict-aliasing games are played.
 *
 * `tsn_node_size()` returns sizeof(TSNode) so the Raku side can assert
 * at load time that its CStruct agrees with the compiled library. That
 * assertion is the only thing standing between a layout change upstream
 * and silent memory corruption — do not drop it.
 *
 * A produced node may be the null node (all-zero id). Callers should
 * test with `tsn_node_is_null` before using it. Unlike the underlying
 * API — where every accessor dereferences the node's id unchecked and
 * a null node means a segfault — the shim guards: on a null node,
 * scalar accessors return 0, borrowed-string accessors return NULL,
 * and navigation writes the null node into the out buffer. Out-of-range
 * child indices degrade the same way. That is a safety net for a
 * caller bug, not a licence to skip the null check: a null node still
 * carries no information.
 *
 * A TSNode is only valid while the TSTree it came from is alive. The
 * shim cannot enforce that; the Raku layer does, by keeping a reference
 * to the owning Tree inside every Node value object.
 *
 * ---------------------------------------------------------------------
 * Points
 * ---------------------------------------------------------------------
 *
 * TSPoint is `{ uint32_t row; uint32_t column; }`. Wherever the C API
 * returns one, the shim writes it through two `uint32_t *` out-params
 * instead. `column` is a BYTE offset within the row, not a character or
 * grapheme offset — see the byte doctrine below.
 *
 * ---------------------------------------------------------------------
 * Byte doctrine
 * ---------------------------------------------------------------------
 *
 * Every offset crossing this boundary — start_byte, end_byte, point
 * columns, query byte ranges, error offsets, edit positions — is a byte
 * offset into the UTF-8 encoding of the source. The shim parses UTF-8
 * and nothing else (`tsn_parser_parse_utf8`). UTF-16 input, the
 * streaming TSInput callback interface and custom decoders are
 * deliberately not wrapped in v1.
 *
 * The caller owns the source buffer passed to `tsn_parser_parse_utf8`
 * and must keep it alive for as long as it wants to resolve node text
 * from byte offsets. tree-sitter copies nothing.
 *
 * ---------------------------------------------------------------------
 * Booleans and errors
 * ---------------------------------------------------------------------
 *
 * Predicates and success flags are returned as `int`, 1 for true and 0
 * for false, rather than C99 `bool` — one less ABI subtlety to agree on
 * across five platform toolchains.
 *
 * Fallible constructors return NULL and fill their out-params with
 * detail. `tsn_query_new` is the only one with structured failure: it
 * writes the byte offset and the TSQueryError code of the first problem
 * before returning NULL. Both out-params are optional (pass NULL to
 * discard), and neither is written on success.
 *
 * ---------------------------------------------------------------------
 * String ownership
 * ---------------------------------------------------------------------
 *
 * Two kinds of `char *` cross this boundary:
 *
 *   BORROWED `const char *` — node types, grammar types, field names,
 *     symbol names, capture names, query string literals. These point
 *     into memory owned by the language, query or tree that produced
 *     them, are valid until that object is freed, and MUST NOT be
 *     passed to tsn_free_string.
 *
 *   OWNED `char *` — only `tsn_node_string`, which returns a malloc'd
 *     S-expression. Release it with `tsn_free_string`, which is a plain
 *     free() and is always safe to call with NULL.
 *
 * Capture names and query string literals also come back with an
 * explicit length out-param, because they may legitimately contain
 * embedded NULs (a query can match a literal "\0"). Callers should
 * prefer the length over strlen.
 *
 * ---------------------------------------------------------------------
 * Heap-owned handles
 * ---------------------------------------------------------------------
 *
 * Three objects are returned by value from the C API and so are
 * heap-boxed here, with the shim owning the allocation:
 *
 *   TSTreeCursor  — `tsn_cursor_new` malloc's, `tsn_cursor_delete`
 *                   calls ts_tree_cursor_delete then free. The caller
 *                   never needs to know sizeof(TSTreeCursor).
 *   TSQueryMatch  — `tsn_match_new` allocates a zeroed match record to
 *                   be filled by `tsn_query_cursor_next_match`;
 *                   `tsn_match_delete` frees it. The `captures` array a
 *                   filled-in match points at is owned by the query
 *                   cursor and is invalidated by the next call to
 *                   next_match on that cursor — read captures out
 *                   before advancing.
 *
 * TSParser, TSTree, TSQuery and TSQueryCursor are already opaque
 * pointers upstream and are simply passed through; their delete
 * functions are the upstream ones and all tolerate NULL.
 *
 * ---------------------------------------------------------------------
 * Not wrapped in v1 (deliberate, documented)
 * ---------------------------------------------------------------------
 *
 * TSInput streaming parse, TSLogger, the DOT-graph debug output,
 * included ranges, the wasm store, non-UTF-8 encodings, lookahead
 * iterators, and the point-range (as opposed to byte-range) query and
 * descendant lookups. `tsn_tree_edit` and the nullable old_tree
 * argument to `tsn_parser_parse_utf8` ARE wrapped, so incremental
 * parsing can be exposed at the Raku layer later without an ABI change
 * here.
 */

#ifndef TS_SHIM_H
#define TS_SHIM_H

#include <stddef.h>
#include <stdint.h>

/* MSVC doesn't export symbols from DLLs by default; every public
 * function needs __declspec(dllexport) at its definition. GCC / Clang
 * export all non-static symbols from a shared library by default, so
 * the visibility attribute is belt-and-braces there (it also keeps the
 * surface correct if someone ever builds with -fvisibility=hidden).
 * Both this header and the definitions in ts_shim.c use TSN_EXPORT.
 *
 * On Windows src/exports.def is the authoritative export list — it is
 * handed to `link /DEF:` and is what keeps the DLL's surface to tsn_*
 * only. The macro and the .def file must agree; xt/ checks that. */
#if defined(_WIN32) || defined(__CYGWIN__)
#  define TSN_EXPORT __declspec(dllexport)
#else
#  define TSN_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handles. These are tree-sitter's own types, forward-declared
 * so this header stands alone; the caller (Raku) treats them as opaque
 * Pointer[]s and never dereferences them.
 *
 * Skipped entirely when tree-sitter's api.h is already in scope (it
 * defines TREE_SITTER_API_H_). C11 permits repeating a typedef with
 * the same underlying type, but older MSVC C modes reject it, and
 * ts_shim.c is the one translation unit that includes both headers. */
#ifndef TREE_SITTER_API_H_
typedef struct TSLanguage    TSLanguage;
typedef struct TSParser      TSParser;
typedef struct TSTree        TSTree;
typedef struct TSQuery       TSQuery;
typedef struct TSQueryCursor TSQueryCursor;

/* Heap-boxed by-value types (see "Heap-owned handles"). Declared as
 * incomplete types here on purpose: the size is the shim's business. */
typedef struct TSTreeCursor  TSTreeCursor;
typedef struct TSQueryMatch  TSQueryMatch;
#endif

/* --- Meta ---------------------------------------------------------- */

/* Version of the tsn_* contract itself. Bumped whenever a signature in
 * this header changes shape, so a Raku layer newer than its installed
 * library can refuse to load rather than mis-call it. */
TSN_EXPORT uint32_t tsn_shim_abi_version(void);

/* sizeof(TSNode). Expected to be 32 everywhere we ship; the Raku layer
 * asserts against its own struct at load time. */
TSN_EXPORT uint32_t tsn_node_size(void);

/* The language ABI the bundled runtime implements — the ceiling. No
 * grammar declaring a higher version can be loaded. */
TSN_EXPORT uint32_t tsn_runtime_abi_version(void);

/* The oldest language ABI the bundled runtime still accepts — the
 * floor. Bundled grammars sit at 14 and 15. */
TSN_EXPORT uint32_t tsn_min_compatible_abi(void);

/* 1 if `abi` is within [tsn_min_compatible_abi, tsn_runtime_abi_version]. */
TSN_EXPORT int tsn_language_abi_supported(uint32_t abi);

/* --- Bundled languages --------------------------------------------- */

/* Each returns a borrowed, immortal pointer to a statically-linked
 * grammar. Never NULL, never freed, safe to call from any thread and
 * as often as you like. */
TSN_EXPORT const TSLanguage *tsn_lang_c(void);
TSN_EXPORT const TSLanguage *tsn_lang_cpp(void);
TSN_EXPORT const TSLanguage *tsn_lang_python(void);
TSN_EXPORT const TSLanguage *tsn_lang_javascript(void);
TSN_EXPORT const TSLanguage *tsn_lang_typescript(void);
TSN_EXPORT const TSLanguage *tsn_lang_tsx(void);
TSN_EXPORT const TSLanguage *tsn_lang_go(void);
TSN_EXPORT const TSLanguage *tsn_lang_rust(void);
TSN_EXPORT const TSLanguage *tsn_lang_java(void);

/* --- Language introspection ---------------------------------------- */

TSN_EXPORT uint32_t tsn_language_abi(const TSLanguage *language);
TSN_EXPORT uint32_t tsn_language_symbol_count(const TSLanguage *language);
TSN_EXPORT uint32_t tsn_language_field_count(const TSLanguage *language);

/* Borrowed. Out-of-range symbol ids yield NULL rather than trapping. */
TSN_EXPORT const char *tsn_language_symbol_name(const TSLanguage *language,
                                                uint16_t symbol);

/* Borrowed. Field ids are 1-based upstream; id 0 yields NULL. */
TSN_EXPORT const char *tsn_language_field_name_for_id(const TSLanguage *language,
                                                      uint16_t field_id);

/* --- Parser --------------------------------------------------------- */

TSN_EXPORT TSParser *tsn_parser_new(void);
TSN_EXPORT void tsn_parser_delete(TSParser *parser);

/* 0 if the grammar's ABI is incompatible with the runtime — the parser
 * keeps whatever language it had. */
TSN_EXPORT int tsn_parser_set_language(TSParser *parser,
                                       const TSLanguage *language);

/* Parse `len` bytes of UTF-8 at `buf`. `old_tree` may be NULL for a
 * fresh parse, or a previously-returned tree that has had
 * `tsn_tree_edit` applied for an incremental one. Returns NULL if no
 * language is set or the parse was cancelled. The returned tree is the
 * caller's and must be released with `tsn_tree_delete`.
 *
 * `buf` may be NULL only when `len` is 0 (parsing the empty document).
 * tree-sitter does not retain `buf`, but every byte offset the tree
 * reports indexes into it. */
TSN_EXPORT TSTree *tsn_parser_parse_utf8(TSParser *parser,
                                         const TSTree *old_tree,
                                         const char *buf,
                                         uint32_t len);

/* Drop any partial state from a cancelled or failed parse. */
TSN_EXPORT void tsn_parser_reset(TSParser *parser);

/* --- Tree ----------------------------------------------------------- */

TSN_EXPORT void tsn_tree_delete(TSTree *tree);
TSN_EXPORT TSTree *tsn_tree_copy(const TSTree *tree);
TSN_EXPORT void tsn_tree_root_node(const TSTree *tree, void *out_node);
TSN_EXPORT const TSLanguage *tsn_tree_language(const TSTree *tree);

/* TSInputEdit flattened into scalars, since NativeCall can't hand over
 * the struct. Byte offsets and row/column pairs describe the edit in
 * the OLD document (start, old end) and the NEW one (new end). */
TSN_EXPORT void tsn_tree_edit(TSTree *tree,
                              uint32_t start_byte,
                              uint32_t old_end_byte,
                              uint32_t new_end_byte,
                              uint32_t start_row,     uint32_t start_column,
                              uint32_t old_end_row,   uint32_t old_end_column,
                              uint32_t new_end_row,   uint32_t new_end_column);

/* --- Node: predicates ----------------------------------------------- */

TSN_EXPORT int tsn_node_is_null(const void *node);
TSN_EXPORT int tsn_node_is_named(const void *node);
TSN_EXPORT int tsn_node_is_missing(const void *node);
TSN_EXPORT int tsn_node_is_extra(const void *node);
TSN_EXPORT int tsn_node_is_error(const void *node);
TSN_EXPORT int tsn_node_has_error(const void *node);
TSN_EXPORT int tsn_node_has_changes(const void *node);
TSN_EXPORT int tsn_node_eq(const void *node, const void *other);

/* --- Node: position -------------------------------------------------- */

TSN_EXPORT uint32_t tsn_node_start_byte(const void *node);
TSN_EXPORT uint32_t tsn_node_end_byte(const void *node);
TSN_EXPORT void tsn_node_start_point(const void *node,
                                     uint32_t *out_row, uint32_t *out_column);
TSN_EXPORT void tsn_node_end_point(const void *node,
                                   uint32_t *out_row, uint32_t *out_column);

/* --- Node: identity --------------------------------------------------- */

/* Borrowed; owned by the language. NULL for the null node. */
TSN_EXPORT const char *tsn_node_type(const void *node);
TSN_EXPORT uint16_t tsn_node_symbol(const void *node);

/* Borrowed. Differs from tsn_node_type only inside a supertype: it is
 * the name the grammar itself uses, not the alias exposed to queries. */
TSN_EXPORT const char *tsn_node_grammar_type(const void *node);

/* --- Node: navigation -------------------------------------------------- */

TSN_EXPORT void tsn_node_parent(const void *node, void *out_node);
TSN_EXPORT void tsn_node_child(const void *node, uint32_t index, void *out_node);
TSN_EXPORT void tsn_node_named_child(const void *node, uint32_t index,
                                     void *out_node);
TSN_EXPORT uint32_t tsn_node_child_count(const void *node);
TSN_EXPORT uint32_t tsn_node_named_child_count(const void *node);
TSN_EXPORT void tsn_node_next_sibling(const void *node, void *out_node);
TSN_EXPORT void tsn_node_prev_sibling(const void *node, void *out_node);
TSN_EXPORT void tsn_node_next_named_sibling(const void *node, void *out_node);
TSN_EXPORT void tsn_node_prev_named_sibling(const void *node, void *out_node);

/* `name` need not be NUL-terminated; `name_len` is authoritative. */
TSN_EXPORT void tsn_node_child_by_field_name(const void *node,
                                             const char *name,
                                             uint32_t name_len,
                                             void *out_node);

/* Borrowed; NULL when the child occupies no field. */
TSN_EXPORT const char *tsn_node_field_name_for_child(const void *node,
                                                     uint32_t child_index);

TSN_EXPORT void tsn_node_descendant_for_byte_range(const void *node,
                                                   uint32_t start_byte,
                                                   uint32_t end_byte,
                                                   void *out_node);
TSN_EXPORT void tsn_node_named_descendant_for_byte_range(const void *node,
                                                         uint32_t start_byte,
                                                         uint32_t end_byte,
                                                         void *out_node);

/* OWNED. malloc'd S-expression for debugging; free with
 * tsn_free_string. NULL for the null node. */
TSN_EXPORT char *tsn_node_string(const void *node);

/* --- Tree cursor ------------------------------------------------------- */

/* Heap-boxed. NULL only on allocation failure. */
TSN_EXPORT TSTreeCursor *tsn_cursor_new(const void *node);
TSN_EXPORT void tsn_cursor_delete(TSTreeCursor *cursor);
TSN_EXPORT void tsn_cursor_reset(TSTreeCursor *cursor, const void *node);
TSN_EXPORT void tsn_cursor_current_node(const TSTreeCursor *cursor,
                                        void *out_node);

/* Borrowed; NULL when the current node occupies no field. */
TSN_EXPORT const char *tsn_cursor_current_field_name(const TSTreeCursor *cursor);

/* Each returns 1 if the cursor moved, 0 if it stayed put. */
TSN_EXPORT int tsn_cursor_goto_first_child(TSTreeCursor *cursor);
TSN_EXPORT int tsn_cursor_goto_next_sibling(TSTreeCursor *cursor);
TSN_EXPORT int tsn_cursor_goto_parent(TSTreeCursor *cursor);

/* 0 at the cursor's starting node, regardless of that node's depth in
 * the tree as a whole. */
TSN_EXPORT uint32_t tsn_cursor_current_depth(const TSTreeCursor *cursor);

/* --- Query -------------------------------------------------------------- */

/* Compile `len` bytes of query source. On failure returns NULL and, if
 * the out-params are non-NULL, writes the byte offset of the problem
 * and a TSQueryError code (1 syntax, 2 node type, 3 field, 4 capture,
 * 5 structure, 6 language). Neither out-param is touched on success.
 * A NULL language, or a NULL source with a non-zero length, is
 * reported as offset 0 / TSQueryErrorSyntax rather than through an
 * eighth code the Raku enum would have to invent. */
TSN_EXPORT TSQuery *tsn_query_new(const TSLanguage *language,
                                  const char *source,
                                  uint32_t len,
                                  uint32_t *out_error_offset,
                                  uint32_t *out_error_type);
TSN_EXPORT void tsn_query_delete(TSQuery *query);

TSN_EXPORT uint32_t tsn_query_pattern_count(const TSQuery *query);
TSN_EXPORT uint32_t tsn_query_capture_count(const TSQuery *query);
TSN_EXPORT uint32_t tsn_query_string_count(const TSQuery *query);

/* Both borrowed, both with an explicit length out-param (the bytes may
 * contain embedded NULs). `out_len` may be NULL. */
TSN_EXPORT const char *tsn_query_capture_name_for_id(const TSQuery *query,
                                                     uint32_t id,
                                                     uint32_t *out_len);
TSN_EXPORT const char *tsn_query_string_value_for_id(const TSQuery *query,
                                                     uint32_t id,
                                                     uint32_t *out_len);

/* Predicate steps for one pattern, exposed structurally so the Raku
 * layer can evaluate #eq?/#match?/#any-of? itself — tree-sitter parses
 * predicates but deliberately leaves their meaning to bindings.
 * Step types: 0 done, 1 capture, 2 string. `value_id` indexes either
 * the capture table or the string table depending on the type. */
TSN_EXPORT uint32_t tsn_query_predicate_step_count(const TSQuery *query,
                                                   uint32_t pattern_index);
/* 1 on success, 0 if the indices are out of range. */
TSN_EXPORT int tsn_query_predicate_step(const TSQuery *query,
                                        uint32_t pattern_index,
                                        uint32_t step_index,
                                        uint32_t *out_type,
                                        uint32_t *out_value_id);

TSN_EXPORT uint32_t tsn_query_start_byte_for_pattern(const TSQuery *query,
                                                     uint32_t pattern_index);

/* --- Query cursor and matches --------------------------------------------- */

TSN_EXPORT TSQueryCursor *tsn_query_cursor_new(void);
TSN_EXPORT void tsn_query_cursor_delete(TSQueryCursor *cursor);
TSN_EXPORT void tsn_query_cursor_exec(TSQueryCursor *cursor,
                                      const TSQuery *query,
                                      const void *node);
/* 1 if the range was accepted (start <= end), 0 otherwise. */
TSN_EXPORT int tsn_query_cursor_set_byte_range(TSQueryCursor *cursor,
                                               uint32_t start_byte,
                                               uint32_t end_byte);

/* Match records are heap-boxed so the caller never needs
 * sizeof(TSQueryMatch). Allocate one, reuse it across the whole
 * iteration, free it at the end. */
TSN_EXPORT TSQueryMatch *tsn_match_new(void);
TSN_EXPORT void tsn_match_delete(TSQueryMatch *match);

/* 1 and fills `match` if another match exists, 0 when the iteration is
 * exhausted. Invalidates the captures of the previous match. */
TSN_EXPORT int tsn_query_cursor_next_match(TSQueryCursor *cursor,
                                           TSQueryMatch *match);

TSN_EXPORT uint32_t tsn_match_pattern_index(const TSQueryMatch *match);
TSN_EXPORT uint32_t tsn_match_capture_count(const TSQueryMatch *match);

/* Read one capture out of a filled-in match: its capture-name id into
 * `out_capture_index` and its node into the 32-byte `out_node` buffer.
 * Returns 1 on success, 0 if `index` is past the end. */
TSN_EXPORT int tsn_match_capture(const TSQueryMatch *match,
                                 uint32_t index,
                                 uint32_t *out_capture_index,
                                 void *out_node);

/* --- Memory ---------------------------------------------------------------- */

/* free() for strings this library malloc'd (only tsn_node_string).
 * Safe with NULL. Never call it on a borrowed const char *. */
TSN_EXPORT void tsn_free_string(char *string);

#ifdef __cplusplus
}
#endif

#endif /* TS_SHIM_H */
