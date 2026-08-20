/*
 * ts_shim.c — the by-value-struct firewall between tree-sitter's C API
 * and Raku's NativeCall.
 *
 * Read src/ts_shim.h first: it carries the contract (TSNode buffers,
 * byte doctrine, string ownership, heap-boxed handles). This file is
 * the mechanical realisation of it and stays deliberately dumb — one
 * upstream call per function, no caching, no hidden allocation, no
 * policy.
 *
 * Portable C11 only: <stdint.h>, <stdlib.h>, <string.h> and
 * tree-sitter's own api.h. No feature-test macros, no POSIX, nothing
 * that needs a configure step. It compiles the same on clang, gcc and
 * MSVC.
 *
 * Two implementation conventions worth knowing before reading on:
 *
 *   1. Nodes move through memcpy, never a cast. The Raku side hands us
 *      a pointer to a CStruct's memory; casting it to TSNode* would
 *      assume an alignment we were never promised and would invite the
 *      optimiser to reason about it under strict aliasing. memcpy has
 *      neither problem and compiles to the same two loads.
 *
 *   2. Every accessor guards the null node. Upstream's node accessors
 *      dereference `self.id` without checking — ts_node_type on a null
 *      node is a segfault, not a NULL return. A segfault takes the
 *      whole Raku process down with no backtrace worth having, so the
 *      shim degrades instead: scalars return 0, borrowed strings
 *      return NULL, and navigation writes the null node into the out
 *      buffer. Callers still get the null node back and still have to
 *      test for it; they just don't get a core dump if they forget.
 */

#include <tree_sitter/api.h>

#include <stdlib.h>
#include <string.h>

#include "ts_shim.h"

/* Grammar entry points. Each is defined by one of the generated
 * parser.c translation units linked into this library. They are
 * declared here rather than pulled from a grammar header on purpose:
 * every grammar ships its own src/tree_sitter/parser.h, the ABI-14 and
 * ABI-15 copies differ, and including any of them here would drag one
 * grammar's idea of the parser ABI into the shim. The prototype is
 * stable across every ABI we support. */
extern const TSLanguage *tree_sitter_c(void);
extern const TSLanguage *tree_sitter_cpp(void);
extern const TSLanguage *tree_sitter_python(void);
extern const TSLanguage *tree_sitter_javascript(void);
extern const TSLanguage *tree_sitter_typescript(void);
extern const TSLanguage *tree_sitter_tsx(void);
extern const TSLanguage *tree_sitter_go(void);
extern const TSLanguage *tree_sitter_rust(void);
extern const TSLanguage *tree_sitter_java(void);

/* Version of the tsn_* contract. Bump on any signature change. */
#define TSN_SHIM_ABI_VERSION 1

/* --- Node buffer plumbing ------------------------------------------- */

/* Load a TSNode out of a caller-allocated 32-byte buffer. A NULL
 * buffer yields the null node, so a caller passing Nil gets the same
 * degraded behaviour as one passing a genuine null node. */
static TSNode tsn__node_load(const void *buf) {
    TSNode node;
    if (buf == NULL) {
        memset(&node, 0, sizeof(node));
        return node;
    }
    memcpy(&node, buf, sizeof(node));
    return node;
}

/* Store a TSNode into a caller-allocated 32-byte buffer. NULL out
 * buffers are tolerated and ignored — the caller asked for a node and
 * gave us nowhere to put it, which is a caller bug but not one worth
 * crashing over. */
static void tsn__node_store(void *buf, TSNode node) {
    if (buf == NULL) {
        return;
    }
    memcpy(buf, &node, sizeof(node));
}

/* Write the null node into a caller-allocated buffer. Used by every
 * navigation guard: an all-zero TSNode has id == NULL, which is
 * precisely what ts_node_is_null tests. */
static void tsn__node_store_null(void *buf) {
    TSNode node;
    memset(&node, 0, sizeof(node));
    tsn__node_store(buf, node);
}

/* True when the buffer holds a node no accessor may be called on:
 * either no buffer at all, or a node with a NULL id, or (belt and
 * braces) one with no owning tree. */
static int tsn__node_dead(const TSNode *node) {
    return node->id == NULL || node->tree == NULL;
}

/* --- Meta ------------------------------------------------------------ */

TSN_EXPORT uint32_t tsn_shim_abi_version(void) {
    return (uint32_t)TSN_SHIM_ABI_VERSION;
}

TSN_EXPORT uint32_t tsn_node_size(void) {
    return (uint32_t)sizeof(TSNode);
}

TSN_EXPORT uint32_t tsn_runtime_abi_version(void) {
    return (uint32_t)TREE_SITTER_LANGUAGE_VERSION;
}

TSN_EXPORT uint32_t tsn_min_compatible_abi(void) {
    return (uint32_t)TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION;
}

TSN_EXPORT int tsn_language_abi_supported(uint32_t abi) {
    return (abi >= (uint32_t)TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION &&
            abi <= (uint32_t)TREE_SITTER_LANGUAGE_VERSION) ? 1 : 0;
}

/* --- Bundled languages ------------------------------------------------ */

TSN_EXPORT const TSLanguage *tsn_lang_c(void)          { return tree_sitter_c(); }
TSN_EXPORT const TSLanguage *tsn_lang_cpp(void)        { return tree_sitter_cpp(); }
TSN_EXPORT const TSLanguage *tsn_lang_python(void)     { return tree_sitter_python(); }
TSN_EXPORT const TSLanguage *tsn_lang_javascript(void) { return tree_sitter_javascript(); }
TSN_EXPORT const TSLanguage *tsn_lang_typescript(void) { return tree_sitter_typescript(); }
TSN_EXPORT const TSLanguage *tsn_lang_tsx(void)        { return tree_sitter_tsx(); }
TSN_EXPORT const TSLanguage *tsn_lang_go(void)         { return tree_sitter_go(); }
TSN_EXPORT const TSLanguage *tsn_lang_rust(void)       { return tree_sitter_rust(); }
TSN_EXPORT const TSLanguage *tsn_lang_java(void)       { return tree_sitter_java(); }

/* --- Language introspection -------------------------------------------- */

TSN_EXPORT uint32_t tsn_language_abi(const TSLanguage *language) {
    if (language == NULL) {
        return 0;
    }
    /* Renamed from ts_language_version in tree-sitter 0.26; the old
     * name is gone, not deprecated. */
    return ts_language_abi_version(language);
}

TSN_EXPORT uint32_t tsn_language_symbol_count(const TSLanguage *language) {
    return language == NULL ? 0 : ts_language_symbol_count(language);
}

TSN_EXPORT uint32_t tsn_language_field_count(const TSLanguage *language) {
    return language == NULL ? 0 : ts_language_field_count(language);
}

TSN_EXPORT const char *tsn_language_symbol_name(const TSLanguage *language,
                                                uint16_t symbol) {
    if (language == NULL) {
        return NULL;
    }
    /* Upstream indexes its symbol table without a bounds check; the
     * count is public, so do the check here. */
    if ((uint32_t)symbol >= ts_language_symbol_count(language)) {
        return NULL;
    }
    return ts_language_symbol_name(language, (TSSymbol)symbol);
}

TSN_EXPORT const char *tsn_language_field_name_for_id(const TSLanguage *language,
                                                      uint16_t field_id) {
    if (language == NULL) {
        return NULL;
    }
    /* Field ids are 1-based: id 0 means "no field". ts_language_field_count
     * excludes that sentinel, so the last valid id is the count itself. */
    if (field_id == 0 || (uint32_t)field_id > ts_language_field_count(language)) {
        return NULL;
    }
    return ts_language_field_name_for_id(language, (TSFieldId)field_id);
}

/* --- Parser -------------------------------------------------------------- */

TSN_EXPORT TSParser *tsn_parser_new(void) {
    return ts_parser_new();
}

TSN_EXPORT void tsn_parser_delete(TSParser *parser) {
    if (parser != NULL) {
        ts_parser_delete(parser);
    }
}

TSN_EXPORT int tsn_parser_set_language(TSParser *parser,
                                       const TSLanguage *language) {
    if (parser == NULL || language == NULL) {
        return 0;
    }
    return ts_parser_set_language(parser, language) ? 1 : 0;
}

TSN_EXPORT TSTree *tsn_parser_parse_utf8(TSParser *parser,
                                         const TSTree *old_tree,
                                         const char *buf,
                                         uint32_t len) {
    if (parser == NULL) {
        return NULL;
    }
    /* An empty document is a legitimate parse and the only case where a
     * NULL buffer is allowed; ts_parser_parse_string would happily walk
     * a NULL pointer if len were non-zero. */
    if (buf == NULL && len != 0) {
        return NULL;
    }
    return ts_parser_parse_string(parser, old_tree, buf == NULL ? "" : buf, len);
}

TSN_EXPORT void tsn_parser_reset(TSParser *parser) {
    if (parser != NULL) {
        ts_parser_reset(parser);
    }
}

/* --- Tree ---------------------------------------------------------------- */

TSN_EXPORT void tsn_tree_delete(TSTree *tree) {
    if (tree != NULL) {
        ts_tree_delete(tree);
    }
}

TSN_EXPORT TSTree *tsn_tree_copy(const TSTree *tree) {
    return tree == NULL ? NULL : ts_tree_copy(tree);
}

TSN_EXPORT void tsn_tree_root_node(const TSTree *tree, void *out_node) {
    if (tree == NULL) {
        tsn__node_store_null(out_node);
        return;
    }
    tsn__node_store(out_node, ts_tree_root_node(tree));
}

TSN_EXPORT const TSLanguage *tsn_tree_language(const TSTree *tree) {
    return tree == NULL ? NULL : ts_tree_language(tree);
}

TSN_EXPORT void tsn_tree_edit(TSTree *tree,
                              uint32_t start_byte,
                              uint32_t old_end_byte,
                              uint32_t new_end_byte,
                              uint32_t start_row,   uint32_t start_column,
                              uint32_t old_end_row, uint32_t old_end_column,
                              uint32_t new_end_row, uint32_t new_end_column) {
    TSInputEdit edit;
    if (tree == NULL) {
        return;
    }
    edit.start_byte    = start_byte;
    edit.old_end_byte  = old_end_byte;
    edit.new_end_byte  = new_end_byte;
    edit.start_point.row      = start_row;
    edit.start_point.column   = start_column;
    edit.old_end_point.row    = old_end_row;
    edit.old_end_point.column = old_end_column;
    edit.new_end_point.row    = new_end_row;
    edit.new_end_point.column = new_end_column;
    ts_tree_edit(tree, &edit);
}

/* --- Node: predicates ------------------------------------------------------ */

TSN_EXPORT int tsn_node_is_null(const void *node) {
    TSNode n = tsn__node_load(node);
    return ts_node_is_null(n) ? 1 : 0;
}

TSN_EXPORT int tsn_node_is_named(const void *node) {
    TSNode n = tsn__node_load(node);
    return tsn__node_dead(&n) ? 0 : (ts_node_is_named(n) ? 1 : 0);
}

TSN_EXPORT int tsn_node_is_missing(const void *node) {
    TSNode n = tsn__node_load(node);
    return tsn__node_dead(&n) ? 0 : (ts_node_is_missing(n) ? 1 : 0);
}

TSN_EXPORT int tsn_node_is_extra(const void *node) {
    TSNode n = tsn__node_load(node);
    return tsn__node_dead(&n) ? 0 : (ts_node_is_extra(n) ? 1 : 0);
}

TSN_EXPORT int tsn_node_is_error(const void *node) {
    TSNode n = tsn__node_load(node);
    return tsn__node_dead(&n) ? 0 : (ts_node_is_error(n) ? 1 : 0);
}

TSN_EXPORT int tsn_node_has_error(const void *node) {
    TSNode n = tsn__node_load(node);
    return tsn__node_dead(&n) ? 0 : (ts_node_has_error(n) ? 1 : 0);
}

TSN_EXPORT int tsn_node_has_changes(const void *node) {
    TSNode n = tsn__node_load(node);
    return tsn__node_dead(&n) ? 0 : (ts_node_has_changes(n) ? 1 : 0);
}

TSN_EXPORT int tsn_node_eq(const void *node, const void *other) {
    TSNode a = tsn__node_load(node);
    TSNode b = tsn__node_load(other);
    /* ts_node_eq is pure struct comparison (id and tree), safe on null
     * nodes, so no guard here — two null nodes compare equal, which is
     * the answer callers expect. */
    return ts_node_eq(a, b) ? 1 : 0;
}

/* --- Node: position --------------------------------------------------------- */

TSN_EXPORT uint32_t tsn_node_start_byte(const void *node) {
    TSNode n = tsn__node_load(node);
    return tsn__node_dead(&n) ? 0 : ts_node_start_byte(n);
}

TSN_EXPORT uint32_t tsn_node_end_byte(const void *node) {
    TSNode n = tsn__node_load(node);
    return tsn__node_dead(&n) ? 0 : ts_node_end_byte(n);
}

TSN_EXPORT void tsn_node_start_point(const void *node,
                                     uint32_t *out_row, uint32_t *out_column) {
    TSNode n = tsn__node_load(node);
    TSPoint p;
    if (tsn__node_dead(&n)) {
        p.row = 0;
        p.column = 0;
    } else {
        p = ts_node_start_point(n);
    }
    if (out_row != NULL) {
        *out_row = p.row;
    }
    if (out_column != NULL) {
        *out_column = p.column;
    }
}

TSN_EXPORT void tsn_node_end_point(const void *node,
                                   uint32_t *out_row, uint32_t *out_column) {
    TSNode n = tsn__node_load(node);
    TSPoint p;
    if (tsn__node_dead(&n)) {
        p.row = 0;
        p.column = 0;
    } else {
        p = ts_node_end_point(n);
    }
    if (out_row != NULL) {
        *out_row = p.row;
    }
    if (out_column != NULL) {
        *out_column = p.column;
    }
}

/* --- Node: identity ---------------------------------------------------------- */

TSN_EXPORT const char *tsn_node_type(const void *node) {
    TSNode n = tsn__node_load(node);
    return tsn__node_dead(&n) ? NULL : ts_node_type(n);
}

TSN_EXPORT uint16_t tsn_node_symbol(const void *node) {
    TSNode n = tsn__node_load(node);
    return tsn__node_dead(&n) ? (uint16_t)0 : (uint16_t)ts_node_symbol(n);
}

TSN_EXPORT const char *tsn_node_grammar_type(const void *node) {
    TSNode n = tsn__node_load(node);
    return tsn__node_dead(&n) ? NULL : ts_node_grammar_type(n);
}

/* --- Node: navigation --------------------------------------------------------- */

TSN_EXPORT void tsn_node_parent(const void *node, void *out_node) {
    TSNode n = tsn__node_load(node);
    if (tsn__node_dead(&n)) {
        tsn__node_store_null(out_node);
        return;
    }
    tsn__node_store(out_node, ts_node_parent(n));
}

TSN_EXPORT void tsn_node_child(const void *node, uint32_t index, void *out_node) {
    TSNode n = tsn__node_load(node);
    if (tsn__node_dead(&n) || index >= ts_node_child_count(n)) {
        tsn__node_store_null(out_node);
        return;
    }
    tsn__node_store(out_node, ts_node_child(n, index));
}

TSN_EXPORT void tsn_node_named_child(const void *node, uint32_t index,
                                     void *out_node) {
    TSNode n = tsn__node_load(node);
    if (tsn__node_dead(&n) || index >= ts_node_named_child_count(n)) {
        tsn__node_store_null(out_node);
        return;
    }
    tsn__node_store(out_node, ts_node_named_child(n, index));
}

TSN_EXPORT uint32_t tsn_node_child_count(const void *node) {
    TSNode n = tsn__node_load(node);
    return tsn__node_dead(&n) ? 0 : ts_node_child_count(n);
}

TSN_EXPORT uint32_t tsn_node_named_child_count(const void *node) {
    TSNode n = tsn__node_load(node);
    return tsn__node_dead(&n) ? 0 : ts_node_named_child_count(n);
}

TSN_EXPORT void tsn_node_next_sibling(const void *node, void *out_node) {
    TSNode n = tsn__node_load(node);
    if (tsn__node_dead(&n)) {
        tsn__node_store_null(out_node);
        return;
    }
    tsn__node_store(out_node, ts_node_next_sibling(n));
}

TSN_EXPORT void tsn_node_prev_sibling(const void *node, void *out_node) {
    TSNode n = tsn__node_load(node);
    if (tsn__node_dead(&n)) {
        tsn__node_store_null(out_node);
        return;
    }
    tsn__node_store(out_node, ts_node_prev_sibling(n));
}

TSN_EXPORT void tsn_node_next_named_sibling(const void *node, void *out_node) {
    TSNode n = tsn__node_load(node);
    if (tsn__node_dead(&n)) {
        tsn__node_store_null(out_node);
        return;
    }
    tsn__node_store(out_node, ts_node_next_named_sibling(n));
}

TSN_EXPORT void tsn_node_prev_named_sibling(const void *node, void *out_node) {
    TSNode n = tsn__node_load(node);
    if (tsn__node_dead(&n)) {
        tsn__node_store_null(out_node);
        return;
    }
    tsn__node_store(out_node, ts_node_prev_named_sibling(n));
}

TSN_EXPORT void tsn_node_child_by_field_name(const void *node,
                                             const char *name,
                                             uint32_t name_len,
                                             void *out_node) {
    TSNode n = tsn__node_load(node);
    if (tsn__node_dead(&n) || name == NULL || name_len == 0) {
        tsn__node_store_null(out_node);
        return;
    }
    tsn__node_store(out_node, ts_node_child_by_field_name(n, name, name_len));
}

TSN_EXPORT const char *tsn_node_field_name_for_child(const void *node,
                                                     uint32_t child_index) {
    TSNode n = tsn__node_load(node);
    if (tsn__node_dead(&n) || child_index >= ts_node_child_count(n)) {
        return NULL;
    }
    return ts_node_field_name_for_child(n, child_index);
}

TSN_EXPORT void tsn_node_descendant_for_byte_range(const void *node,
                                                   uint32_t start_byte,
                                                   uint32_t end_byte,
                                                   void *out_node) {
    TSNode n = tsn__node_load(node);
    if (tsn__node_dead(&n)) {
        tsn__node_store_null(out_node);
        return;
    }
    tsn__node_store(out_node,
                    ts_node_descendant_for_byte_range(n, start_byte, end_byte));
}

TSN_EXPORT void tsn_node_named_descendant_for_byte_range(const void *node,
                                                         uint32_t start_byte,
                                                         uint32_t end_byte,
                                                         void *out_node) {
    TSNode n = tsn__node_load(node);
    if (tsn__node_dead(&n)) {
        tsn__node_store_null(out_node);
        return;
    }
    tsn__node_store(out_node,
                    ts_node_named_descendant_for_byte_range(n, start_byte, end_byte));
}

TSN_EXPORT char *tsn_node_string(const void *node) {
    TSNode n = tsn__node_load(node);
    return tsn__node_dead(&n) ? NULL : ts_node_string(n);
}

/* --- Tree cursor ----------------------------------------------------------------- */

TSN_EXPORT TSTreeCursor *tsn_cursor_new(const void *node) {
    TSNode n = tsn__node_load(node);
    TSTreeCursor *cursor;
    if (tsn__node_dead(&n)) {
        return NULL;
    }
    cursor = (TSTreeCursor *)malloc(sizeof(TSTreeCursor));
    if (cursor == NULL) {
        return NULL;
    }
    *cursor = ts_tree_cursor_new(n);
    return cursor;
}

TSN_EXPORT void tsn_cursor_delete(TSTreeCursor *cursor) {
    if (cursor != NULL) {
        ts_tree_cursor_delete(cursor);
        free(cursor);
    }
}

TSN_EXPORT void tsn_cursor_reset(TSTreeCursor *cursor, const void *node) {
    TSNode n = tsn__node_load(node);
    if (cursor == NULL || tsn__node_dead(&n)) {
        return;
    }
    ts_tree_cursor_reset(cursor, n);
}

TSN_EXPORT void tsn_cursor_current_node(const TSTreeCursor *cursor,
                                        void *out_node) {
    if (cursor == NULL) {
        tsn__node_store_null(out_node);
        return;
    }
    tsn__node_store(out_node, ts_tree_cursor_current_node(cursor));
}

TSN_EXPORT const char *tsn_cursor_current_field_name(const TSTreeCursor *cursor) {
    return cursor == NULL ? NULL : ts_tree_cursor_current_field_name(cursor);
}

TSN_EXPORT int tsn_cursor_goto_first_child(TSTreeCursor *cursor) {
    return (cursor != NULL && ts_tree_cursor_goto_first_child(cursor)) ? 1 : 0;
}

TSN_EXPORT int tsn_cursor_goto_next_sibling(TSTreeCursor *cursor) {
    return (cursor != NULL && ts_tree_cursor_goto_next_sibling(cursor)) ? 1 : 0;
}

TSN_EXPORT int tsn_cursor_goto_parent(TSTreeCursor *cursor) {
    return (cursor != NULL && ts_tree_cursor_goto_parent(cursor)) ? 1 : 0;
}

TSN_EXPORT uint32_t tsn_cursor_current_depth(const TSTreeCursor *cursor) {
    return cursor == NULL ? 0 : ts_tree_cursor_current_depth(cursor);
}

/* --- Query --------------------------------------------------------------------------- */

TSN_EXPORT TSQuery *tsn_query_new(const TSLanguage *language,
                                  const char *source,
                                  uint32_t len,
                                  uint32_t *out_error_offset,
                                  uint32_t *out_error_type) {
    uint32_t error_offset = 0;
    TSQueryError error_type = TSQueryErrorNone;
    TSQuery *query;

    if (language == NULL || (source == NULL && len != 0)) {
        /* Report it the same shape a malformed query would: offset 0,
         * TSQueryErrorSyntax. The caller has no query object either
         * way, and inventing an eighth error code would mean teaching
         * the Raku enum a value tree-sitter never produces. */
        if (out_error_offset != NULL) {
            *out_error_offset = 0;
        }
        if (out_error_type != NULL) {
            *out_error_type = (uint32_t)TSQueryErrorSyntax;
        }
        return NULL;
    }

    query = ts_query_new(language, source == NULL ? "" : source, len,
                         &error_offset, &error_type);
    if (query == NULL) {
        if (out_error_offset != NULL) {
            *out_error_offset = error_offset;
        }
        if (out_error_type != NULL) {
            *out_error_type = (uint32_t)error_type;
        }
    }
    return query;
}

TSN_EXPORT void tsn_query_delete(TSQuery *query) {
    if (query != NULL) {
        ts_query_delete(query);
    }
}

TSN_EXPORT uint32_t tsn_query_pattern_count(const TSQuery *query) {
    return query == NULL ? 0 : ts_query_pattern_count(query);
}

TSN_EXPORT uint32_t tsn_query_capture_count(const TSQuery *query) {
    return query == NULL ? 0 : ts_query_capture_count(query);
}

TSN_EXPORT uint32_t tsn_query_string_count(const TSQuery *query) {
    return query == NULL ? 0 : ts_query_string_count(query);
}

TSN_EXPORT const char *tsn_query_capture_name_for_id(const TSQuery *query,
                                                     uint32_t id,
                                                     uint32_t *out_len) {
    uint32_t length = 0;
    const char *name;
    if (query == NULL || id >= ts_query_capture_count(query)) {
        if (out_len != NULL) {
            *out_len = 0;
        }
        return NULL;
    }
    name = ts_query_capture_name_for_id(query, id, &length);
    if (out_len != NULL) {
        *out_len = length;
    }
    return name;
}

TSN_EXPORT const char *tsn_query_string_value_for_id(const TSQuery *query,
                                                     uint32_t id,
                                                     uint32_t *out_len) {
    uint32_t length = 0;
    const char *value;
    if (query == NULL || id >= ts_query_string_count(query)) {
        if (out_len != NULL) {
            *out_len = 0;
        }
        return NULL;
    }
    value = ts_query_string_value_for_id(query, id, &length);
    if (out_len != NULL) {
        *out_len = length;
    }
    return value;
}

TSN_EXPORT uint32_t tsn_query_predicate_step_count(const TSQuery *query,
                                                   uint32_t pattern_index) {
    uint32_t step_count = 0;
    if (query == NULL || pattern_index >= ts_query_pattern_count(query)) {
        return 0;
    }
    (void)ts_query_predicates_for_pattern(query, pattern_index, &step_count);
    return step_count;
}

TSN_EXPORT int tsn_query_predicate_step(const TSQuery *query,
                                        uint32_t pattern_index,
                                        uint32_t step_index,
                                        uint32_t *out_type,
                                        uint32_t *out_value_id) {
    uint32_t step_count = 0;
    const TSQueryPredicateStep *steps;

    if (query == NULL || pattern_index >= ts_query_pattern_count(query)) {
        return 0;
    }
    steps = ts_query_predicates_for_pattern(query, pattern_index, &step_count);
    if (steps == NULL || step_index >= step_count) {
        return 0;
    }
    if (out_type != NULL) {
        *out_type = (uint32_t)steps[step_index].type;
    }
    if (out_value_id != NULL) {
        *out_value_id = steps[step_index].value_id;
    }
    return 1;
}

TSN_EXPORT uint32_t tsn_query_start_byte_for_pattern(const TSQuery *query,
                                                     uint32_t pattern_index) {
    if (query == NULL || pattern_index >= ts_query_pattern_count(query)) {
        return 0;
    }
    return ts_query_start_byte_for_pattern(query, pattern_index);
}

/* --- Query cursor and matches ------------------------------------------------------------ */

TSN_EXPORT TSQueryCursor *tsn_query_cursor_new(void) {
    return ts_query_cursor_new();
}

TSN_EXPORT void tsn_query_cursor_delete(TSQueryCursor *cursor) {
    if (cursor != NULL) {
        ts_query_cursor_delete(cursor);
    }
}

TSN_EXPORT void tsn_query_cursor_exec(TSQueryCursor *cursor,
                                      const TSQuery *query,
                                      const void *node) {
    TSNode n = tsn__node_load(node);
    if (cursor == NULL || query == NULL || tsn__node_dead(&n)) {
        return;
    }
    ts_query_cursor_exec(cursor, query, n);
}

TSN_EXPORT int tsn_query_cursor_set_byte_range(TSQueryCursor *cursor,
                                               uint32_t start_byte,
                                               uint32_t end_byte) {
    if (cursor == NULL) {
        return 0;
    }
    return ts_query_cursor_set_byte_range(cursor, start_byte, end_byte) ? 1 : 0;
}

TSN_EXPORT TSQueryMatch *tsn_match_new(void) {
    /* calloc, not malloc: a match that has never been filled in reads
     * as pattern 0 with zero captures rather than as garbage, so a
     * caller that inspects one before its first next_match gets a
     * boring answer instead of a wild pointer. */
    return (TSQueryMatch *)calloc(1, sizeof(TSQueryMatch));
}

TSN_EXPORT void tsn_match_delete(TSQueryMatch *match) {
    /* The captures array belongs to the query cursor, not to us — this
     * frees the record only. */
    free(match);
}

TSN_EXPORT int tsn_query_cursor_next_match(TSQueryCursor *cursor,
                                           TSQueryMatch *match) {
    if (cursor == NULL || match == NULL) {
        return 0;
    }
    return ts_query_cursor_next_match(cursor, match) ? 1 : 0;
}

TSN_EXPORT uint32_t tsn_match_pattern_index(const TSQueryMatch *match) {
    return match == NULL ? 0 : (uint32_t)match->pattern_index;
}

TSN_EXPORT uint32_t tsn_match_capture_count(const TSQueryMatch *match) {
    return match == NULL ? 0 : (uint32_t)match->capture_count;
}

TSN_EXPORT int tsn_match_capture(const TSQueryMatch *match,
                                 uint32_t index,
                                 uint32_t *out_capture_index,
                                 void *out_node) {
    if (match == NULL || match->captures == NULL ||
        index >= (uint32_t)match->capture_count) {
        tsn__node_store_null(out_node);
        return 0;
    }
    if (out_capture_index != NULL) {
        *out_capture_index = match->captures[index].index;
    }
    tsn__node_store(out_node, match->captures[index].node);
    return 1;
}

/* --- Memory ----------------------------------------------------------------------------- */

TSN_EXPORT void tsn_free_string(char *string) {
    /* ts_node_string allocates through tree-sitter's allocator, which
     * is the C library's unless ts_set_allocator has been called. This
     * library never calls it, so plain free() is the matching
     * deallocation. */
    free(string);
}
