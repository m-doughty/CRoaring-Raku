#ifndef CROARING_HELPERS_H
#define CROARING_HELPERS_H

#include <stdint.h>
#include <stddef.h>

/*
 * Build a sorted index from parallel doc_id and value arrays.
 * Uses radix sort on packed (value << 32 | doc_id) keys for O(n) performance.
 *
 * Input:  doc_ids[count], values[count] — unsorted parallel arrays
 * Output: out_values[count], out_doc_ids[count] — sorted by (value, doc_id) ascending
 */
void croaring_build_index(
    const uint32_t *doc_ids, const uint32_t *values, size_t count,
    uint32_t *out_values, uint32_t *out_doc_ids
);

/*
 * Sort parallel arrays of (values, doc_ids) in-place by (value, doc_id) ascending.
 * Uses radix sort on packed uint64 keys.
 */
void croaring_sort_pairs(uint32_t *values, uint32_t *doc_ids, size_t count);

/*
 * Sort a single uint32 array in-place ascending.
 */
void croaring_sort_u32(uint32_t *arr, size_t count);

/*
 * Merge two sorted (value, doc_id) parallel arrays into output buffers.
 * Both inputs must be sorted by (value, doc_id) ascending.
 * Output buffers must have space for (count_a + count_b) elements.
 * Returns the number of elements written.
 */
size_t croaring_merge_sorted_pairs(
    const uint32_t *values_a, const uint32_t *doc_ids_a, size_t count_a,
    const uint32_t *values_b, const uint32_t *doc_ids_b, size_t count_b,
    uint32_t *out_values, uint32_t *out_doc_ids
);

/*
 * Remove entries from sorted (value, doc_id) parallel arrays where doc_id
 * appears in the remove set. Uses bitmap lookup — correct regardless of
 * doc_id ordering in the index.
 *
 * Operates in-place. Returns the new count.
 */
size_t croaring_remove_docs_from_index(
    uint32_t *values, uint32_t *doc_ids, size_t count,
    const uint32_t *remove_doc_ids, size_t remove_count
);

/*
 * Deduplicate parallel arrays by doc_id, keeping the LAST occurrence
 * of each doc_id (so later values overwrite earlier ones for the same doc).
 * Input is in raw insertion order (not sorted).
 * Output: deduped parallel arrays. Returns new count.
 */
size_t croaring_dedupe_pairs(
    uint32_t *doc_ids, uint32_t *values, size_t count
);

#endif
