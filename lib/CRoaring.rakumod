use NativeCall;
use CRoaring::FFI;

unit class CRoaring;

has RoaringBitmap $!handle;

submethod BUILD(:$!handle) {}

method new(--> CRoaring:D) {
	my RoaringBitmap $handle = roaring_bitmap_create_with_capacity(0);
	die "CRoaring: failed to create bitmap" unless $handle.defined;
	self.bless(:$handle);
}

method !from-handle(RoaringBitmap:D $handle --> CRoaring:D) {
	self.bless(:$handle);
}

method handle(--> RoaringBitmap) { $!handle }

method from-array(@values --> CRoaring:D) {
	my CRoaring:D $bm = self.new;
	$bm.add-many(@values);
	$bm;
}

method from-range(Int:D $min, Int:D $max --> CRoaring:D) {
	# roaring_bitmap_from_range(min, max, step) — max is exclusive
	my RoaringBitmap $handle = roaring_bitmap_from_range($min, $max + 1, 1);
	die "CRoaring: failed to create bitmap from range" unless $handle.defined;
	CRoaring!from-handle($handle);
}

# --- Modification ---

method add(Int:D $value --> Nil) {
	roaring_bitmap_add($!handle, $value);
}

method remove(Int:D $value --> Nil) {
	roaring_bitmap_remove($!handle, $value);
}

method contains(Int:D $value --> Bool:D) {
	so roaring_bitmap_contains($!handle, $value);
}

method add-many(@values --> Nil) {
	my Int:D $n = @values.elems;
	return unless $n > 0;
	my Buf[uint32] $buf .= new(@values);
	roaring_bitmap_add_many($!handle, $n, nativecast(CArray[uint32], $buf));
}

method add-many-buf(Buf $buf, Int:D $count --> Nil) {
	roaring_bitmap_add_many($!handle, $count, nativecast(CArray[uint32], $buf));
}

# --- Properties ---

method cardinality(--> Int:D) {
	roaring_bitmap_get_cardinality($!handle).Int;
}

method elems(--> Int:D) {
	self.cardinality;
}

method is-empty(--> Bool:D) {
	so roaring_bitmap_is_empty($!handle);
}

# --- Set operations ---

method and(CRoaring:D $other --> CRoaring:D) {
	my RoaringBitmap $result = roaring_bitmap_and($!handle, $other.handle);
	die "CRoaring: and operation failed" unless $result.defined;
	CRoaring!from-handle($result);
}

method or(CRoaring:D $other --> CRoaring:D) {
	my RoaringBitmap $result = roaring_bitmap_or($!handle, $other.handle);
	die "CRoaring: or operation failed" unless $result.defined;
	CRoaring!from-handle($result);
}

method xor(CRoaring:D $other --> CRoaring:D) {
	my RoaringBitmap $result = roaring_bitmap_xor($!handle, $other.handle);
	die "CRoaring: xor operation failed" unless $result.defined;
	CRoaring!from-handle($result);
}

method andnot(CRoaring:D $other --> CRoaring:D) {
	my RoaringBitmap $result = roaring_bitmap_andnot($!handle, $other.handle);
	die "CRoaring: andnot operation failed" unless $result.defined;
	CRoaring!from-handle($result);
}

# --- Clone ---

method clone(--> CRoaring:D) {
	my RoaringBitmap $copy = roaring_bitmap_copy($!handle);
	die "CRoaring: failed to clone bitmap" unless $copy.defined;
	CRoaring!from-handle($copy);
}

# --- Smartmatch ---

multi method ACCEPTS(CRoaring:D: Int:D $val --> Bool:D) {
	self.contains($val);
}

# --- Comparison ---

method equals(CRoaring:D $other --> Bool:D) {
	so roaring_bitmap_equals($!handle, $other.handle);
}

method is-subset-of(CRoaring:D $other --> Bool:D) {
	so roaring_bitmap_is_subset($!handle, $other.handle);
}

# --- Conversion ---

method to-array(--> List) {
	my Int:D $n = self.cardinality;
	return () if $n == 0;
	my CArray[uint32] $arr .= new;
	$arr[$n - 1] = 0; # pre-allocate
	roaring_bitmap_to_uint32_array($!handle, nativecast(Pointer[uint32], $arr));
	(^$n).map({ $arr[$_].Int }).list;
}

method list(--> List) {
	self.to-array;
}

method select(Int:D $rank --> Int) {
	my CArray[uint32] $out .= new;
	$out[0] = 0;
	my Bool $ok = so roaring_bitmap_select($!handle, $rank, $out);
	$ok ?? $out[0].Int !! Int;
}

method slice(Int:D $offset, Int:D $count --> List) {
	return () if $count <= 0;
	my Int:D $card = self.cardinality;
	return () if $offset >= $card;
	my Int:D $actual = ($card - $offset) min $count;
	my CArray[uint32] $arr .= new;
	$arr[$actual - 1] = 0;
	roaring_bitmap_range_uint32_array($!handle, $offset, $actual,
		nativecast(Pointer[uint32], $arr));
	(^$actual).map({ $arr[$_].Int }).list;
}

method slice-reverse(Int:D $offset, Int:D $count --> List) {
	my Int:D $card = self.cardinality;
	return () if $card == 0 || $count <= 0;
	# offset 0 = last element, offset 1 = second-to-last, etc.
	my Int:D $start = ($card - $offset - $count) max 0;
	my Int:D $actual = ($card - $offset) - $start;
	return () if $actual <= 0;
	self.slice($start, $actual).reverse.list;
}

# --- Serialization ---

method serialize(--> Buf:D) {
	my size_t $size = roaring_bitmap_portable_size_in_bytes($!handle);
	my Buf $buf .= allocate($size);
	my Pointer[uint8] $ptr = nativecast(Pointer[uint8], $buf);
	roaring_bitmap_portable_serialize($!handle, $ptr);
	$buf;
}

method deserialize(Buf:D $data --> CRoaring:D) {
	my Pointer[uint8] $ptr = nativecast(Pointer[uint8], $data);
	my RoaringBitmap $handle = roaring_bitmap_portable_deserialize_safe($ptr, $data.bytes);
	die "CRoaring: failed to deserialize bitmap" unless $handle.defined;
	CRoaring!from-handle($handle);
}

# --- Optimization ---

method optimize(--> Bool:D) {
	so roaring_bitmap_run_optimize($!handle);
}

# --- Cleanup ---

method dispose(--> Nil) {
	if $!handle.defined {
		roaring_bitmap_free($!handle);
		$!handle = Nil;
	}
}

method DESTROY() {
	self.dispose;
}
