unit module CRoaring::FFI;

use NativeCall;

constant $os = $*KERNEL.name.lc;
constant $libname = $os ~~ /darwin/ ?? 'libcroaring.dylib' !!
                    $os ~~ /win/    ?? 'libcroaring.dll'   !!
                                       'libcroaring.so';

#| Resolve the CRoaring native library path. Precedence:
#|
#|     1. $CROARING_LIB — explicit override; full path to a .dylib / .so / .dll.
#|        Power-user escape hatch for custom builds, system copies, or
#|        air-gapped setups. Undocumented "take responsibility for ABI" path.
#|     2. %?RESOURCES — staged at install time by Build.rakumod, either
#|        from a prebuilt GitHub release or a local compile. This is the
#|        normal path for every install.
sub _libpath() {
    with %*ENV<CROARING_LIB> -> $override {
        return $override if $override.chars && $override.IO.e;
    }
    %?RESOURCES{"lib/$libname"}.IO.Str;
}

class RoaringBitmap is repr('CPointer') is export {}

# Lifecycle
sub roaring_bitmap_create_with_capacity(uint32 --> RoaringBitmap)
	is native(&_libpath) is export { * }
sub roaring_bitmap_free(RoaringBitmap)
	is native(&_libpath) is export { * }
sub roaring_bitmap_copy(RoaringBitmap --> RoaringBitmap)
	is native(&_libpath) is export { * }
sub roaring_bitmap_from_range(uint64, uint64, uint32 --> RoaringBitmap)
	is native(&_libpath) is export { * }

# Add / Remove / Contains
sub roaring_bitmap_add(RoaringBitmap, uint32)
	is native(&_libpath) is export { * }
sub roaring_bitmap_remove(RoaringBitmap, uint32)
	is native(&_libpath) is export { * }
sub roaring_bitmap_contains(RoaringBitmap, uint32 --> bool)
	is native(&_libpath) is export { * }
sub roaring_bitmap_add_many(RoaringBitmap, size_t, CArray[uint32])
	is native(&_libpath) is export { * }

# Cardinality / Empty
sub roaring_bitmap_get_cardinality(RoaringBitmap --> uint64)
	is native(&_libpath) is export { * }
sub roaring_bitmap_is_empty(RoaringBitmap --> bool)
	is native(&_libpath) is export { * }

# Set operations (return new bitmaps — caller must free)
sub roaring_bitmap_and(RoaringBitmap, RoaringBitmap --> RoaringBitmap)
	is native(&_libpath) is export { * }
sub roaring_bitmap_or(RoaringBitmap, RoaringBitmap --> RoaringBitmap)
	is native(&_libpath) is export { * }
sub roaring_bitmap_xor(RoaringBitmap, RoaringBitmap --> RoaringBitmap)
	is native(&_libpath) is export { * }
sub roaring_bitmap_andnot(RoaringBitmap, RoaringBitmap --> RoaringBitmap)
	is native(&_libpath) is export { * }

# Equality / Subset
sub roaring_bitmap_equals(RoaringBitmap, RoaringBitmap --> bool)
	is native(&_libpath) is export { * }
sub roaring_bitmap_is_subset(RoaringBitmap, RoaringBitmap --> bool)
	is native(&_libpath) is export { * }

# Serialization (portable format)
sub roaring_bitmap_portable_size_in_bytes(RoaringBitmap --> size_t)
	is native(&_libpath) is export { * }
sub roaring_bitmap_portable_serialize(RoaringBitmap, Pointer[uint8] --> size_t)
	is native(&_libpath) is export { * }
sub roaring_bitmap_portable_deserialize_safe(Pointer[uint8], size_t --> RoaringBitmap)
	is native(&_libpath) is export { * }

# Bulk export
sub roaring_bitmap_to_uint32_array(RoaringBitmap, Pointer[uint32])
	is native(&_libpath) is export { * }
sub roaring_bitmap_range_uint32_array(RoaringBitmap, size_t, size_t, Pointer[uint32] --> bool)
	is native(&_libpath) is export { * }

# Rank / Select
sub roaring_bitmap_select(RoaringBitmap, uint32, CArray[uint32] --> bool)
	is native(&_libpath) is export { * }

# Optimize
sub roaring_bitmap_run_optimize(RoaringBitmap --> bool)
	is native(&_libpath) is export { * }

# Helpers: parallel sort, merge, dedupe, remove for index building
sub croaring_sort_pairs(Pointer[uint32], Pointer[uint32], size_t)
	is native(&_libpath) is export { * }
sub croaring_merge_sorted_pairs(
	Pointer[uint32], Pointer[uint32], size_t,
	Pointer[uint32], Pointer[uint32], size_t,
	Pointer[uint32], Pointer[uint32] --> size_t)
	is native(&_libpath) is export { * }
sub croaring_build_index(
	Pointer[uint32], Pointer[uint32], size_t,
	Pointer[uint32], Pointer[uint32])
	is native(&_libpath) is export { * }
sub croaring_sort_u32(Pointer[uint32], size_t)
	is native(&_libpath) is export { * }
sub croaring_remove_docs_from_index(
	Pointer[uint32], Pointer[uint32], size_t,
	Pointer[uint32], size_t --> size_t)
	is native(&_libpath) is export { * }
sub croaring_dedupe_pairs(
	Pointer[uint32], Pointer[uint32], size_t --> size_t)
	is native(&_libpath) is export { * }
