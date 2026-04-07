#include "helpers.h"
#include <stdlib.h>
#include <string.h>

/* ========== Radix Sort on packed uint64 keys ========== */

/*
 * 8-bit radix sort on uint64 keys, 8 passes.
 * Sorts keys[] and permutes vals_a[] and vals_b[] in parallel.
 * This is used internally: pack (value << 32 | doc_id) as the key,
 * then unpack after sorting.
 */
static void radix_sort_u64(uint64_t *keys, uint64_t *temp, size_t count) {
    if (count <= 1) return;

    uint64_t *src = keys;
    uint64_t *dst = temp;

    for (int pass = 0; pass < 8; pass++) {
        int shift = pass * 8;
        size_t histogram[256] = {0};

        /* Build histogram */
        for (size_t i = 0; i < count; i++) {
            uint8_t byte = (src[i] >> shift) & 0xFF;
            histogram[byte]++;
        }

        /* Prefix sum */
        size_t total = 0;
        for (int i = 0; i < 256; i++) {
            size_t c = histogram[i];
            histogram[i] = total;
            total += c;
        }

        /* Scatter */
        for (size_t i = 0; i < count; i++) {
            uint8_t byte = (src[i] >> shift) & 0xFF;
            dst[histogram[byte]++] = src[i];
        }

        /* Swap src/dst */
        uint64_t *tmp = src;
        src = dst;
        dst = tmp;
    }

    /* After 8 passes (even), result is back in keys if src == keys.
     * If src != keys, copy back. */
    if (src != keys) {
        memcpy(keys, src, count * sizeof(uint64_t));
    }
}

/* Pack (value, doc_id) into a uint64 for sorting: value in high 32, doc_id in low 32 */
static inline uint64_t pack_pair(uint32_t value, uint32_t doc_id) {
    return ((uint64_t)value << 32) | (uint64_t)doc_id;
}

static inline uint32_t unpack_value(uint64_t packed) {
    return (uint32_t)(packed >> 32);
}

static inline uint32_t unpack_doc_id(uint64_t packed) {
    return (uint32_t)(packed & 0xFFFFFFFF);
}

/* ========== Public API ========== */

void croaring_sort_pairs(uint32_t *values, uint32_t *doc_ids, size_t count) {
    if (count <= 1) return;

    uint64_t *packed = (uint64_t *)malloc(count * sizeof(uint64_t));
    uint64_t *temp   = (uint64_t *)malloc(count * sizeof(uint64_t));
    if (!packed || !temp) { free(packed); free(temp); return; }

    /* Pack */
    for (size_t i = 0; i < count; i++) {
        packed[i] = pack_pair(values[i], doc_ids[i]);
    }

    /* Sort */
    radix_sort_u64(packed, temp, count);

    /* Unpack */
    for (size_t i = 0; i < count; i++) {
        values[i]  = unpack_value(packed[i]);
        doc_ids[i] = unpack_doc_id(packed[i]);
    }

    free(packed);
    free(temp);
}

void croaring_build_index(
    const uint32_t *doc_ids, const uint32_t *values, size_t count,
    uint32_t *out_values, uint32_t *out_doc_ids
) {
    if (count == 0) return;

    memcpy(out_values, values, count * sizeof(uint32_t));
    memcpy(out_doc_ids, doc_ids, count * sizeof(uint32_t));

    croaring_sort_pairs(out_values, out_doc_ids, count);
}

size_t croaring_merge_sorted_pairs(
    const uint32_t *values_a, const uint32_t *doc_ids_a, size_t count_a,
    const uint32_t *values_b, const uint32_t *doc_ids_b, size_t count_b,
    uint32_t *out_values, uint32_t *out_doc_ids
) {
    size_t i = 0, j = 0, k = 0;

    while (i < count_a && j < count_b) {
        uint64_t a = pack_pair(values_a[i], doc_ids_a[i]);
        uint64_t b = pack_pair(values_b[j], doc_ids_b[j]);

        if (a <= b) {
            out_values[k] = values_a[i];
            out_doc_ids[k] = doc_ids_a[i];
            i++;
        } else {
            out_values[k] = values_b[j];
            out_doc_ids[k] = doc_ids_b[j];
            j++;
        }
        k++;
    }

    if (i < count_a) {
        size_t remaining = count_a - i;
        memcpy(out_values + k, values_a + i, remaining * sizeof(uint32_t));
        memcpy(out_doc_ids + k, doc_ids_a + i, remaining * sizeof(uint32_t));
        k += remaining;
    }

    if (j < count_b) {
        size_t remaining = count_b - j;
        memcpy(out_values + k, values_b + j, remaining * sizeof(uint32_t));
        memcpy(out_doc_ids + k, doc_ids_b + j, remaining * sizeof(uint32_t));
        k += remaining;
    }

    return k;
}

/*
 * Sort a single uint32 array in-place ascending.
 * Uses radix sort for large arrays, insertion sort for small.
 */
static int cmp_u32(const void *a, const void *b) {
    uint32_t va = *(const uint32_t *)a;
    uint32_t vb = *(const uint32_t *)b;
    return (va > vb) - (va < vb);
}

void croaring_sort_u32(uint32_t *arr, size_t count) {
    if (count <= 1) return;
    qsort(arr, count, sizeof(uint32_t), cmp_u32);
}

/*
 * Remove entries from sorted (value, doc_id) parallel arrays where doc_id
 * appears in the remove set. Uses bitmap lookup so doc_id ordering in the
 * index does not matter.
 */
size_t croaring_remove_docs_from_index(
    uint32_t *values, uint32_t *doc_ids, size_t count,
    const uint32_t *remove_doc_ids, size_t remove_count
) {
    if (remove_count == 0) return count;

    /* Find max doc_id in remove set to size the bitmap */
    uint32_t max_id = 0;
    for (size_t i = 0; i < remove_count; i++) {
        if (remove_doc_ids[i] > max_id) max_id = remove_doc_ids[i];
    }

    size_t bitmap_bytes = (max_id / 8) + 1;
    uint8_t *remove_set = (uint8_t *)calloc(bitmap_bytes, 1);
    if (!remove_set) return count; /* alloc failure: keep all */

    /* Build bitmap of doc_ids to remove */
    for (size_t i = 0; i < remove_count; i++) {
        uint32_t id = remove_doc_ids[i];
        remove_set[id / 8] |= (1 << (id % 8));
    }

    /* Compact: keep entries whose doc_id is NOT in the remove bitmap */
    size_t w = 0;
    for (size_t i = 0; i < count; i++) {
        uint32_t id = doc_ids[i];
        int in_remove = (id <= max_id) && (remove_set[id / 8] & (1 << (id % 8)));
        if (!in_remove) {
            values[w] = values[i];
            doc_ids[w] = doc_ids[i];
            w++;
        }
    }

    free(remove_set);
    return w;
}

size_t croaring_dedupe_pairs(
    uint32_t *doc_ids, uint32_t *values, size_t count
) {
    if (count <= 1) return count;

    /*
     * Keep the LAST occurrence of each doc_id.
     * Walk backwards, track seen doc_ids with a simple hash set.
     * For large counts this uses a bitmap; for small counts, linear scan.
     */

    /* Find max doc_id to size our bitmap */
    uint32_t max_id = 0;
    for (size_t i = 0; i < count; i++) {
        if (doc_ids[i] > max_id) max_id = doc_ids[i];
    }

    /* Use a bitmap if max_id is reasonable (< 128MB), else hash-based */
    size_t bitmap_bytes = (max_id / 8) + 1;
    if (bitmap_bytes > 128 * 1024 * 1024) {
        /* Fallback: just keep last occurrence naively */
        /* Walk backward, mark first-seen (from end) */
        /* This is still O(n^2) worst case but only for pathological inputs */
        size_t w = count;
        for (size_t ri = count; ri > 0; ri--) {
            size_t idx = ri - 1;
            int found = 0;
            for (size_t j = idx + 1; j < count; j++) {
                if (doc_ids[j] == doc_ids[idx]) { found = 1; break; }
            }
            if (!found) {
                w--;
                doc_ids[w] = doc_ids[idx];
                values[w] = values[idx];
            }
        }
        /* Shift to front */
        size_t new_count = count - w;
        memmove(doc_ids, doc_ids + w, new_count * sizeof(uint32_t));
        memmove(values, values + w, new_count * sizeof(uint32_t));
        return new_count;
    }

    uint8_t *seen = (uint8_t *)calloc(bitmap_bytes, 1);
    if (!seen) return count;

    /* Walk backward, collect unique entries (last wins) */
    uint32_t *tmp_ids = (uint32_t *)malloc(count * sizeof(uint32_t));
    uint32_t *tmp_vals = (uint32_t *)malloc(count * sizeof(uint32_t));
    if (!tmp_ids || !tmp_vals) {
        free(seen); free(tmp_ids); free(tmp_vals);
        return count;
    }

    size_t w = 0;
    for (size_t ri = count; ri > 0; ri--) {
        size_t idx = ri - 1;
        uint32_t id = doc_ids[idx];
        size_t byte_idx = id / 8;
        uint8_t bit = 1 << (id % 8);
        if (!(seen[byte_idx] & bit)) {
            seen[byte_idx] |= bit;
            tmp_ids[w] = id;
            tmp_vals[w] = values[idx];
            w++;
        }
    }

    /* Copy back in original order (reverse the collected entries) */
    for (size_t i = 0; i < w; i++) {
        doc_ids[i] = tmp_ids[w - 1 - i];
        values[i] = tmp_vals[w - 1 - i];
    }

    free(seen);
    free(tmp_ids);
    free(tmp_vals);

    return w;
}
