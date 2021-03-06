;;  Copyright (c) 2019, Intel Corporation
;;  All rights reserved.
;;
;;  Redistribution and use in source and binary forms, with or without
;;  modification, are permitted provided that the following conditions are
;;  met:
;;
;;    * Redistributions of source code must retain the above copyright
;;      notice, this list of conditions and the following disclaimer.
;;
;;    * Redistributions in binary form must reproduce the above copyright
;;      notice, this list of conditions and the following disclaimer in the
;;      documentation and/or other materials provided with the distribution.
;;
;;    * Neither the name of Intel Corporation nor the names of its
;;      contributors may be used to endorse or promote products derived from
;;      this software without specific prior written permission.
;;
;;
;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
;;   IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
;;   TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
;;   PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
;;   OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
;;   EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
;;   PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
;;   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
;;   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.  

define(`MASK',`i8')
define(`HAVE_GATHER',`1')
define(`HAVE_SCATTER',`1')

include(`util.m4')

stdlib_core()
scans()
reduce_equal(WIDTH)
rdrand_definition()

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; broadcast/rotate/shuffle

define_shuffles()

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; aos/soa

aossoa()

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Stub for mask conversion. LLVM's intrinsics want i1 mask, but we use i8

define <WIDTH x i1> @__cast_mask_to_i1 (<WIDTH x MASK> %mask) alwaysinline {
  %mask_vec_i1 = icmp ne <WIDTH x MASK> %mask, const_vector(MASK, 0)
  ret <WIDTH x i1> %mask_vec_i1
}

define i8 @__cast_mask_to_i8 (<WIDTH x MASK> %mask) alwaysinline {
  %mask_i1 = call <WIDTH x i1> @__cast_mask_to_i1 (<WIDTH x MASK> %mask)
  %mask_i8 = bitcast <WIDTH x i1> %mask_i1 to i8
  ret i8 %mask_i8
}


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; half conversion routines

declare <8 x float> @llvm.x86.vcvtph2ps.256(<8 x i16>) nounwind readnone
declare <8 x i16> @llvm.x86.vcvtps2ph.256(<8 x float>, i32) nounwind readnone

define <8 x float> @__half_to_float_varying(<8 x i16> %v) nounwind readnone {
  %r = call <8 x float> @llvm.x86.vcvtph2ps.256(<8 x i16> %v)
  ret <8 x float> %r
}

define <8 x i16> @__float_to_half_varying(<8 x float> %v) nounwind readnone {
  %r = call <8 x i16> @llvm.x86.vcvtps2ph.256(<8 x float> %v, i32 0)
  ret <8 x i16> %r
}

define float @__half_to_float_uniform(i16 %v) nounwind readnone {
  %v1 = bitcast i16 %v to <1 x i16>
  %vv = shufflevector <1 x i16> %v1, <1 x i16> undef,
           <8 x i32> <i32 0, i32 undef, i32 undef, i32 undef,
                      i32 undef, i32 undef, i32 undef, i32 undef>
  %rv = call <8 x float> @llvm.x86.vcvtph2ps.256(<8 x i16> %vv)
  %r = extractelement <8 x float> %rv, i32 0
  ret float %r
}

define i16 @__float_to_half_uniform(float %v) nounwind readnone {
  %v1 = bitcast float %v to <1 x float>
  %vv = shufflevector <1 x float> %v1, <1 x float> undef,
           <8 x i32> <i32 0, i32 undef, i32 undef, i32 undef,
                      i32 undef, i32 undef, i32 undef, i32 undef>
  ; round to nearest even
  %rv = call <8 x i16> @llvm.x86.vcvtps2ph.256(<8 x float> %vv, i32 0)
  %r = extractelement <8 x i16> %rv, i32 0
  ret i16 %r
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; fast math mode

declare void @llvm.x86.sse.stmxcsr(i8 *) nounwind
declare void @llvm.x86.sse.ldmxcsr(i8 *) nounwind

define void @__fastmath() nounwind alwaysinline {
  %ptr = alloca i32
  %ptr8 = bitcast i32 * %ptr to i8 *
  call void @llvm.x86.sse.stmxcsr(i8 * %ptr8)
  %oldval = load PTR_OP_ARGS(`i32 ') %ptr

  ; turn on DAZ (64)/FTZ (32768) -> 32832
  %update = or i32 %oldval, 32832
  store i32 %update, i32 *%ptr
  call void @llvm.x86.sse.ldmxcsr(i8 * %ptr8)
  ret void
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; round/floor/ceil

declare <4 x float> @llvm.x86.sse41.round.ss(<4 x float>, <4 x float>, i32) nounwind readnone

define float @__round_uniform_float(float) nounwind readonly alwaysinline {
  ; roundss, round mode nearest 0b00 | don't signal precision exceptions 0b1000 = 8
  ; the roundss intrinsic is a total mess--docs say:
  ;
  ;  __m128 _mm_round_ss (__m128 a, __m128 b, const int c)
  ;       
  ;  b is a 128-bit parameter. The lowest 32 bits are the result of the rounding function
  ;  on b0. The higher order 96 bits are copied directly from input parameter a. The
  ;  return value is described by the following equations:
  ;
  ;  r0 = RND(b0)
  ;  r1 = a1
  ;  r2 = a2
  ;  r3 = a3
  ;
  ;  It doesn't matter what we pass as a, since we only need the r0 value
  ;  here.  So we pass the same register for both.  Further, only the 0th
  ;  element of the b parameter matters
  %xi = insertelement <4 x float> undef, float %0, i32 0
  %xr = call <4 x float> @llvm.x86.sse41.round.ss(<4 x float> %xi, <4 x float> %xi, i32 8)
  %rs = extractelement <4 x float> %xr, i32 0
  ret float %rs
}

define float @__floor_uniform_float(float) nounwind readonly alwaysinline {
  ; see above for round_ss instrinsic discussion...
  %xi = insertelement <4 x float> undef, float %0, i32 0
  ; roundps, round down 0b01 | don't signal precision exceptions 0b1001 = 9
  %xr = call <4 x float> @llvm.x86.sse41.round.ss(<4 x float> %xi, <4 x float> %xi, i32 9)
  %rs = extractelement <4 x float> %xr, i32 0
  ret float %rs
}

define float @__ceil_uniform_float(float) nounwind readonly alwaysinline {
  ; see above for round_ss instrinsic discussion...
  %xi = insertelement <4 x float> undef, float %0, i32 0
  ; roundps, round up 0b10 | don't signal precision exceptions 0b1010 = 10
  %xr = call <4 x float> @llvm.x86.sse41.round.ss(<4 x float> %xi, <4 x float> %xi, i32 10)
  %rs = extractelement <4 x float> %xr, i32 0
  ret float %rs
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; rounding doubles

declare <2 x double> @llvm.x86.sse41.round.sd(<2 x double>, <2 x double>, i32) nounwind readnone

define double @__round_uniform_double(double) nounwind readonly alwaysinline {
  %xi = insertelement <2 x double> undef, double %0, i32 0
  %xr = call <2 x double> @llvm.x86.sse41.round.sd(<2 x double> %xi, <2 x double> %xi, i32 8)
  %rs = extractelement <2 x double> %xr, i32 0
  ret double %rs
}

define double @__floor_uniform_double(double) nounwind readonly alwaysinline {
  ; see above for round_ss instrinsic discussion...
  %xi = insertelement <2 x double> undef, double %0, i32 0
  ; roundsd, round down 0b01 | don't signal precision exceptions 0b1001 = 9
  %xr = call <2 x double> @llvm.x86.sse41.round.sd(<2 x double> %xi, <2 x double> %xi, i32 9)
  %rs = extractelement <2 x double> %xr, i32 0
  ret double %rs
}

define double @__ceil_uniform_double(double) nounwind readonly alwaysinline {
  ; see above for round_ss instrinsic discussion...
  %xi = insertelement <2 x double> undef, double %0, i32 0
  ; roundsd, round up 0b10 | don't signal precision exceptions 0b1010 = 10
  %xr = call <2 x double> @llvm.x86.sse41.round.sd(<2 x double> %xi, <2 x double> %xi, i32 10)
  %rs = extractelement <2 x double> %xr, i32 0
  ret double %rs
}


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; rounding floats

declare <8 x float> @llvm.nearbyint.v8f32(<8 x float> %p)
declare <8 x float> @llvm.floor.v8f32(<8 x float> %p)
declare <8 x float> @llvm.ceil.v8f32(<8 x float> %p)

define <8 x float> @__round_varying_float(<8 x float>) nounwind readonly alwaysinline {
  %res = call <8 x float> @llvm.nearbyint.v8f32(<8 x float> %0)
  ret <8 x float> %res
}

define <8 x float> @__floor_varying_float(<8 x float>) nounwind readonly alwaysinline {
  %res = call <8 x float> @llvm.floor.v8f32(<8 x float> %0)
  ret <8 x float> %res
}

define <8 x float> @__ceil_varying_float(<8 x float>) nounwind readonly alwaysinline {
  %res = call <8 x float> @llvm.ceil.v8f32(<8 x float> %0)
  ret <8 x float> %res
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; rounding doubles

declare <4 x double> @llvm.nearbyint.v4f64(<4 x double> %p)
declare <4 x double> @llvm.floor.v4f64(<4 x double> %p)
declare <4 x double> @llvm.ceil.v4f64(<4 x double> %p)

define <8 x double> @__round_varying_double(<8 x double>) nounwind readonly alwaysinline {
  %v0 = shufflevector <8 x double> %0, <8 x double> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %v1 = shufflevector <8 x double> %0, <8 x double> undef, <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  %r0 = call <4 x double> @llvm.nearbyint.v4f64(<4 x double> %v0)
  %r1 = call <4 x double> @llvm.nearbyint.v4f64(<4 x double> %v1)
  %res = shufflevector <4 x double> %r0, <4 x double> %r1, <8 x i32> <i32 0, i32 1, i32 2, i32 3, i32 4, i32 5, i32 6, i32 7>
  ret <8 x double> %res
}

define <8 x double> @__floor_varying_double(<8 x double>) nounwind readonly alwaysinline {
  %v0 = shufflevector <8 x double> %0, <8 x double> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %v1 = shufflevector <8 x double> %0, <8 x double> undef, <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  %r0 = call <4 x double> @llvm.floor.v4f64(<4 x double> %v0)
  %r1 = call <4 x double> @llvm.floor.v4f64(<4 x double> %v1)
  %res = shufflevector <4 x double> %r0, <4 x double> %r1, <8 x i32> <i32 0, i32 1, i32 2, i32 3, i32 4, i32 5, i32 6, i32 7>
  ret <8 x double> %res
}

define <8 x double> @__ceil_varying_double(<8 x double>) nounwind readonly alwaysinline {
  %v0 = shufflevector <8 x double> %0, <8 x double> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %v1 = shufflevector <8 x double> %0, <8 x double> undef, <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  %r0 = call <4 x double> @llvm.ceil.v4f64(<4 x double> %v0)
  %r1 = call <4 x double> @llvm.ceil.v4f64(<4 x double> %v1)
  %res = shufflevector <4 x double> %r0, <4 x double> %r1, <8 x i32> <i32 0, i32 1, i32 2, i32 3, i32 4, i32 5, i32 6, i32 7>
  ret <8 x double> %res
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; min/max

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; int64/uint64 min/max
define i64 @__max_uniform_int64(i64, i64) nounwind readonly alwaysinline {
  %c = icmp sgt i64 %0, %1
  %r = select i1 %c, i64 %0, i64 %1
  ret i64 %r
}

define i64 @__max_uniform_uint64(i64, i64) nounwind readonly alwaysinline {
  %c = icmp ugt i64 %0, %1
  %r = select i1 %c, i64 %0, i64 %1
  ret i64 %r
}

define i64 @__min_uniform_int64(i64, i64) nounwind readonly alwaysinline {
  %c = icmp slt i64 %0, %1
  %r = select i1 %c, i64 %0, i64 %1
  ret i64 %r
}

define i64 @__min_uniform_uint64(i64, i64) nounwind readonly alwaysinline {
  %c = icmp ult i64 %0, %1
  %r = select i1 %c, i64 %0, i64 %1
  ret i64 %r
}

declare <4 x i64> @llvm.x86.avx512.mask.pmaxs.q.256(<4 x i64>, <4 x i64>, <4 x i64>, i8)
declare <4 x i64> @llvm.x86.avx512.mask.pmaxu.q.256(<4 x i64>, <4 x i64>, <4 x i64>, i8)
declare <4 x i64> @llvm.x86.avx512.mask.pmins.q.256(<4 x i64>, <4 x i64>, <4 x i64>, i8)
declare <4 x i64> @llvm.x86.avx512.mask.pminu.q.256(<4 x i64>, <4 x i64>, <4 x i64>, i8)

define <8 x i64> @__max_varying_int64(<8 x i64>, <8 x i64>) nounwind readonly alwaysinline {
  %v0_lo = shufflevector <8 x i64> %0, <8 x i64> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %v0_hi = shufflevector <8 x i64> %0, <8 x i64> undef, <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  %v1_lo = shufflevector <8 x i64> %1, <8 x i64> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %v1_hi = shufflevector <8 x i64> %1, <8 x i64> undef, <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  %r0 = call <4 x i64> @llvm.x86.avx512.mask.pmaxs.q.256(<4 x i64> %v0_lo, <4 x i64> %v1_lo, <4 x i64>zeroinitializer, i8 -1)
  %r1 = call <4 x i64> @llvm.x86.avx512.mask.pmaxs.q.256(<4 x i64> %v0_hi, <4 x i64> %v1_hi, <4 x i64>zeroinitializer, i8 -1)
  %res = shufflevector <4 x i64> %r0, <4 x i64> %r1, <8 x i32> <i32 0, i32 1, i32 2, i32 3, i32 4, i32 5, i32 6, i32 7>
  ret <8 x i64> %res
}

define <8 x i64> @__max_varying_uint64(<8 x i64>, <8 x i64>) nounwind readonly alwaysinline {
  %v0_lo = shufflevector <8 x i64> %0, <8 x i64> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %v0_hi = shufflevector <8 x i64> %0, <8 x i64> undef, <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  %v1_lo = shufflevector <8 x i64> %1, <8 x i64> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %v1_hi = shufflevector <8 x i64> %1, <8 x i64> undef, <4 x i32> <i32 4, i32 5, i32 6, i32 7>

  %r0 = call <4 x i64> @llvm.x86.avx512.mask.pmaxu.q.256(<4 x i64> %v0_lo, <4 x i64> %v1_lo, <4 x i64>zeroinitializer, i8 -1)
  %r1 = call <4 x i64> @llvm.x86.avx512.mask.pmaxu.q.256(<4 x i64> %v0_hi, <4 x i64> %v1_hi, <4 x i64>zeroinitializer, i8 -1)
  %res = shufflevector <4 x i64> %r0, <4 x i64> %r1, <8 x i32> <i32 0, i32 1, i32 2, i32 3, i32 4, i32 5, i32 6, i32 7>
  ret <8 x i64> %res
}

define <8 x i64> @__min_varying_int64(<8 x i64>, <8 x i64>) nounwind readonly alwaysinline {
  %v0_lo = shufflevector <8 x i64> %0, <8 x i64> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %v0_hi = shufflevector <8 x i64> %0, <8 x i64> undef, <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  %v1_lo = shufflevector <8 x i64> %1, <8 x i64> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %v1_hi = shufflevector <8 x i64> %1, <8 x i64> undef, <4 x i32> <i32 4, i32 5, i32 6, i32 7>

  %r0 = call <4 x i64> @llvm.x86.avx512.mask.pmins.q.256(<4 x i64> %v0_lo, <4 x i64> %v1_lo, <4 x i64>zeroinitializer, i8 -1)
  %r1 = call <4 x i64> @llvm.x86.avx512.mask.pmins.q.256(<4 x i64> %v0_hi, <4 x i64> %v1_hi, <4 x i64>zeroinitializer, i8 -1)
  %res = shufflevector <4 x i64> %r0, <4 x i64> %r1, <8 x i32> <i32 0, i32 1, i32 2, i32 3, i32 4, i32 5, i32 6, i32 7>
  ret <8 x i64> %res
}

define <8 x i64> @__min_varying_uint64(<8 x i64>, <8 x i64>) nounwind readonly alwaysinline {
  %v0_lo = shufflevector <8 x i64> %0, <8 x i64> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %v0_hi = shufflevector <8 x i64> %0, <8 x i64> undef, <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  %v1_lo = shufflevector <8 x i64> %1, <8 x i64> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %v1_hi = shufflevector <8 x i64> %1, <8 x i64> undef, <4 x i32> <i32 4, i32 5, i32 6, i32 7>

  %r0 = call <4 x i64> @llvm.x86.avx512.mask.pminu.q.256(<4 x i64> %v0_lo, <4 x i64> %v1_lo, <4 x i64>zeroinitializer, i8 -1)
  %r1 = call <4 x i64> @llvm.x86.avx512.mask.pminu.q.256(<4 x i64> %v0_hi, <4 x i64> %v1_hi, <4 x i64>zeroinitializer, i8 -1)
  %res = shufflevector <4 x i64> %r0, <4 x i64> %r1, <8 x i32> <i32 0, i32 1, i32 2, i32 3, i32 4, i32 5, i32 6, i32 7>
  ret <8 x i64> %res
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; float min/max

define float @__max_uniform_float(float, float) nounwind readonly alwaysinline {
  %cmp = fcmp ogt float %1, %0
  %ret = select i1 %cmp, float %1, float %0
  ret float %ret
}

define float @__min_uniform_float(float, float) nounwind readonly alwaysinline {
  %cmp = fcmp ogt float %1, %0
  %ret = select i1 %cmp, float %0, float %1
  ret float %ret
}

declare <8 x float> @llvm.x86.avx512.mask.max.ps.256(<8 x float>, <8 x float>, <8 x float>, i8)
declare <8 x float> @llvm.x86.avx512.mask.min.ps.256(<8 x float>, <8 x float>, <8 x float>, i8)

define <8 x float> @__max_varying_float(<8 x float>, <8 x float>) nounwind readonly alwaysinline {
  %res = call <8 x float> @llvm.x86.avx512.mask.max.ps.256(<8 x float> %0, <8 x float> %1, <8 x float>zeroinitializer, i8 -1)
  ret <8 x float> %res
}

define <8 x float> @__min_varying_float(<8 x float>, <8 x float>) nounwind readonly alwaysinline {
  %res = call <8 x float> @llvm.x86.avx512.mask.min.ps.256(<8 x float> %0, <8 x float> %1, <8 x float>zeroinitializer, i8 -1)
  ret <8 x float> %res
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; int min/max

define i32 @__min_uniform_int32(i32, i32) nounwind readonly alwaysinline {
  %cmp = icmp sgt i32 %1, %0
  %ret = select i1 %cmp, i32 %0, i32 %1
  ret i32 %ret
}

define i32 @__max_uniform_int32(i32, i32) nounwind readonly alwaysinline {
  %cmp = icmp sgt i32 %1, %0
  %ret = select i1 %cmp, i32 %1, i32 %0
  ret i32 %ret
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; unsigned int min/max

define i32 @__min_uniform_uint32(i32, i32) nounwind readonly alwaysinline {
  %cmp = icmp ugt i32 %1, %0
  %ret = select i1 %cmp, i32 %0, i32 %1
  ret i32 %ret
}

define i32 @__max_uniform_uint32(i32, i32) nounwind readonly alwaysinline {
  %cmp = icmp ugt i32 %1, %0
  %ret = select i1 %cmp, i32 %1, i32 %0
  ret i32 %ret
}

declare <8 x i32> @llvm.x86.avx512.mask.pmins.d.256(<8 x i32>, <8 x i32>, <8 x i32>, i8)
declare <8 x i32> @llvm.x86.avx512.mask.pmaxs.d.256(<8 x i32>, <8 x i32>, <8 x i32>, i8)

define <8 x i32> @__min_varying_int32(<8 x i32>, <8 x i32>) nounwind readonly alwaysinline {
  %ret = call <8 x i32> @llvm.x86.avx512.mask.pmins.d.256(<8 x i32> %0, <8 x i32> %1, 
                                                           <8 x i32> zeroinitializer, i8 -1)
  ret <8 x i32> %ret
}

define <8 x i32> @__max_varying_int32(<8 x i32>, <8 x i32>) nounwind readonly alwaysinline {
  %ret = call <8 x i32> @llvm.x86.avx512.mask.pmaxs.d.256(<8 x i32> %0, <8 x i32> %1,
                                                           <8 x i32> zeroinitializer, i8 -1)
  ret <8 x i32> %ret
}

declare <8 x i32> @llvm.x86.avx512.mask.pminu.d.256(<8 x i32>, <8 x i32>, <8 x i32>, i8)
declare <8 x i32> @llvm.x86.avx512.mask.pmaxu.d.256(<8 x i32>, <8 x i32>, <8 x i32>, i8)

define <8 x i32> @__min_varying_uint32(<8 x i32>, <8 x i32>) nounwind readonly alwaysinline {
  %ret = call <8 x i32> @llvm.x86.avx512.mask.pminu.d.256(<8 x i32> %0, <8 x i32> %1,
                                                           <8 x i32> zeroinitializer, i8 -1)
  ret <8 x i32> %ret
}

define <8 x i32> @__max_varying_uint32(<8 x i32>, <8 x i32>) nounwind readonly alwaysinline {
  %ret = call <8 x i32> @llvm.x86.avx512.mask.pmaxu.d.256(<8 x i32> %0, <8 x i32> %1,
                                                           <8 x i32> zeroinitializer, i8 -1)
  ret <8 x i32> %ret
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; double precision min/max

define double @__min_uniform_double(double, double) nounwind readnone alwaysinline {
  %cmp = fcmp ogt double %1, %0
  %ret = select i1 %cmp, double %0, double %1
  ret double %ret
}

define double @__max_uniform_double(double, double) nounwind readnone alwaysinline {
  %cmp = fcmp ogt double %1, %0
  %ret = select i1 %cmp, double %1, double %0
  ret double %ret
}

declare <4 x double> @llvm.x86.avx512.mask.min.pd.256(<4 x double>, <4 x double>,
                    <4 x double>, i8)
declare <4 x double> @llvm.x86.avx512.mask.max.pd.256(<4 x double>, <4 x double>,
                    <4 x double>, i8)

define <8 x double> @__min_varying_double(<8 x double>, <8 x double>) nounwind readnone alwaysinline {
  %a_0 = shufflevector <8 x double> %0, <8 x double> undef,
                       <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %a_1 = shufflevector <8 x double> %1, <8 x double> undef,
                       <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %res_a = call <4 x double> @llvm.x86.avx512.mask.min.pd.256(<4 x double> %a_0, <4 x double> %a_1,
                <4 x double> zeroinitializer, i8 -1)
  %b_0 = shufflevector <8 x double> %0, <8 x double> undef,
                       <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  %b_1 = shufflevector <8 x double> %1, <8 x double> undef,
                       <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  %res_b = call <4 x double> @llvm.x86.avx512.mask.min.pd.256(<4 x double> %b_0, <4 x double> %b_1,
                <4 x double> zeroinitializer, i8 -1)
  %res = shufflevector <4 x double> %res_a, <4 x double> %res_b,
                       <8 x i32> <i32 0, i32 1, i32 2, i32 3, i32 4, i32 5, i32 6, i32 7>
  ret <8 x double> %res                       
}

define <8 x double> @__max_varying_double(<8 x double>, <8 x double>) nounwind readnone alwaysinline {
  %a_0 = shufflevector <8 x double> %0, <8 x double> undef,
                       <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %a_1 = shufflevector <8 x double> %1, <8 x double> undef,
                       <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %res_a = call <4 x double> @llvm.x86.avx512.mask.max.pd.256(<4 x double> %a_0, <4 x double> %a_1,
                <4 x double> zeroinitializer, i8 -1)
  %b_0 = shufflevector <8 x double> %0, <8 x double> undef,
                       <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  %b_1 = shufflevector <8 x double> %1, <8 x double> undef,
                       <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  %res_b = call <4 x double> @llvm.x86.avx512.mask.max.pd.256(<4 x double> %b_0, <4 x double> %b_1,
                <4 x double> zeroinitializer, i8 -1)
  %res = shufflevector <4 x double> %res_a, <4 x double> %res_b,
                       <8 x i32> <i32 0, i32 1, i32 2, i32 3, i32 4, i32 5, i32 6, i32 7>
  ret <8 x double> %res 
}


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; rsqrt

declare <4 x float> @llvm.x86.sse.rsqrt.ss(<4 x float>) nounwind readnone

define float @__rsqrt_uniform_float(float) nounwind readonly alwaysinline {
  ;  uniform float is = extract(__rsqrt_u(v), 0);
  %v = insertelement <4 x float> undef, float %0, i32 0
  %vis = call <4 x float> @llvm.x86.sse.rsqrt.ss(<4 x float> %v)
  %is = extractelement <4 x float> %vis, i32 0

  ; Newton-Raphson iteration to improve precision
  ;  return 0.5 * is * (3. - (v * is) * is);
  %v_is = fmul float %0, %is
  %v_is_is = fmul float %v_is, %is
  %three_sub = fsub float 3., %v_is_is
  %is_mul = fmul float %is, %three_sub
  %half_scale = fmul float 0.5, %is_mul
  ret float %half_scale
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; rcp

declare <4 x float> @llvm.x86.sse.rcp.ss(<4 x float>) nounwind readnone

define float @__rcp_uniform_float(float) nounwind readonly alwaysinline {
  ; do the rcpss call
  ;    uniform float iv = extract(__rcp_u(v), 0);
  ;    return iv * (2. - v * iv);
  %vecval = insertelement <4 x float> undef, float %0, i32 0
  %call = call <4 x float> @llvm.x86.sse.rcp.ss(<4 x float> %vecval)
  %scall = extractelement <4 x float> %call, i32 0

  ; do one N-R iteration to improve precision, as above
  %v_iv = fmul float %0, %scall
  %two_minus = fsub float 2., %v_iv
  %iv_mul = fmul float %scall, %two_minus
  ret float %iv_mul
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; sqrt

declare <4 x float> @llvm.x86.sse.sqrt.ss(<4 x float>) nounwind readnone

define float @__sqrt_uniform_float(float) nounwind readonly alwaysinline {
  sse_unary_scalar(ret, 4, float, @llvm.x86.sse.sqrt.ss, %0)
  ret float %ret
}

declare <8 x float> @llvm.x86.avx512.mask.sqrt.ps.256(<8 x float>, <8 x float>, i8) nounwind readnone

define <8 x float> @__sqrt_varying_float(<8 x float>) nounwind readonly alwaysinline {
  %res = call <8 x float> @llvm.x86.avx512.mask.sqrt.ps.256(<8 x float> %0, <8 x float> zeroinitializer, i8 -1)
  ret <8 x float> %res
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; double precision sqrt

declare <2 x double> @llvm.x86.sse2.sqrt.sd(<2 x double>) nounwind readnone

define double @__sqrt_uniform_double(double) nounwind alwaysinline {
  sse_unary_scalar(ret, 2, double, @llvm.x86.sse2.sqrt.sd, %0)
  ret double %ret
}

declare <4 x double> @llvm.x86.avx512.mask.sqrt.pd.256(<4 x double>, <4 x double>, i8) nounwind readnone

define <8 x double> @__sqrt_varying_double(<8 x double>) nounwind alwaysinline {
  %v0 = shufflevector <8 x double> %0, <8 x double> undef, 
                      <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %v1 = shufflevector <8 x double> %0, <8 x double> undef, 
                      <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  %r0 = call <4 x double> @llvm.x86.avx512.mask.sqrt.pd.256(<4 x double> %v0,  <4 x double> zeroinitializer, i8 -1)
  %r1 = call <4 x double> @llvm.x86.avx512.mask.sqrt.pd.256(<4 x double> %v1,  <4 x double> zeroinitializer, i8 -1)
  %res = shufflevector <4 x double> %r0, <4 x double> %r1, 
                       <8 x i32> <i32 0, i32 1, i32 2, i32 3, i32 4, i32 5, i32 6, i32 7>
  ret <8 x double> %res
}
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; bit ops

declare i32 @llvm.ctpop.i32(i32) nounwind readnone

define i32 @__popcnt_int32(i32) nounwind readonly alwaysinline {
  %call = call i32 @llvm.ctpop.i32(i32 %0)
  ret i32 %call
}

declare i64 @llvm.ctpop.i64(i64) nounwind readnone

define i64 @__popcnt_int64(i64) nounwind readonly alwaysinline {
  %call = call i64 @llvm.ctpop.i64(i64 %0)
  ret i64 %call
}
ctlztz()

;; TODO: should we use masked versions of SVML functions?
;; svml

include(`svml.m4')
svml_declare(float,f16,8)
svml_define(float,f16,8,f)

;; double precision
svml_declare(double,8,4)
svml_define_x(double,8,4,d,8)



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; reductions

define i64 @__movmsk(<WIDTH x MASK> %mask) nounwind readnone alwaysinline {
  %intmask = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %mask)
  %res = zext i8 %intmask to i64
  ret i64 %res
}

define i1 @__any(<WIDTH x MASK> %mask) nounwind readnone alwaysinline {
  %intmask = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %mask)
  %res = icmp ne i8 %intmask, 0
  ret i1 %res
}

define i1 @__all(<WIDTH x MASK> %mask) nounwind readnone alwaysinline {
  %intmask = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %mask)
  %res = icmp eq i8 %intmask, 255
  ret i1 %res
}

define i1 @__none(<WIDTH x MASK> %mask) nounwind readnone alwaysinline {
  %intmask = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %mask)
  %res = icmp eq i8 %intmask, 0
  ret i1 %res
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; horizontal int8/16 ops

declare <2 x i64> @llvm.x86.sse2.psad.bw(<16 x i8>, <16 x i8>) nounwind readnone

define i16 @__reduce_add_int8(<8 x i8>) nounwind readnone alwaysinline {
  %ri = shufflevector <8 x i8> %0, <8 x i8> zeroinitializer,
                         <16 x i32> <i32 0, i32 1, i32 2, i32 3, i32 4, i32 5, i32 6, i32 7,
                         i32 8, i32 9, i32 10, i32 11, i32 12, i32 13, i32 14, i32 15>
  %rv = call <2 x i64> @llvm.x86.sse2.psad.bw(<16 x i8> %ri,
                                              <16 x i8> zeroinitializer)
  %r = extractelement <2 x i64> %rv, i32 0
  %r16 = trunc i64 %r to i16
  ret i16 %r16
}

define internal <8 x i16> @__add_varying_i16(<8 x i16>,
                                  <8 x i16>) nounwind readnone alwaysinline {
  %r = add <8 x i16> %0, %1
  ret <8 x i16> %r
}

define internal i16 @__add_uniform_i16(i16, i16) nounwind readnone alwaysinline {
  %r = add i16 %0, %1
  ret i16 %r
}

define i16 @__reduce_add_int16(<8 x i16>) nounwind readnone alwaysinline {
  reduce8(i16, @__add_varying_i16, @__add_uniform_i16)
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; horizontal float ops

declare <8 x float> @llvm.x86.avx.hadd.ps.256(<8 x float>, <8 x float>) nounwind readnone

define float @__reduce_add_float(<8 x float>) nounwind readonly alwaysinline {
  %v1 = call <8 x float> @llvm.x86.avx.hadd.ps.256(<8 x float> %0, <8 x float> %0)
  %v2 = call <8 x float> @llvm.x86.avx.hadd.ps.256(<8 x float> %v1, <8 x float> %v1)
  %scalar1 = extractelement <8 x float> %v2, i32 0
  %scalar2 = extractelement <8 x float> %v2, i32 4
  %sum = fadd float %scalar1, %scalar2
  ret float %sum
}

define float @__reduce_min_float(<8 x float>) nounwind readnone alwaysinline {
  reduce8(float, @__min_varying_float, @__min_uniform_float)
}

define float @__reduce_max_float(<8 x float>) nounwind readnone alwaysinline {
  reduce8(float, @__max_varying_float, @__max_uniform_float)
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; horizontal int32 ops

define internal <8 x i32> @__add_varying_int32(<8 x i32>,
                                       <8 x i32>) nounwind readnone alwaysinline {
  %s = add <8 x i32> %0, %1
  ret <8 x i32> %s
}

define internal i32 @__add_uniform_int32(i32, i32) nounwind readnone alwaysinline {
  %s = add i32 %0, %1
  ret i32 %s
}

define i32 @__reduce_add_int32(<8 x i32>) nounwind readnone alwaysinline {
  reduce8(i32, @__add_varying_int32, @__add_uniform_int32)
}

define i32 @__reduce_min_int32(<8 x i32>) nounwind readnone alwaysinline {
  reduce8(i32, @__min_varying_int32, @__min_uniform_int32)
}

define i32 @__reduce_max_int32(<8 x i32>) nounwind readnone alwaysinline {
  reduce8(i32, @__max_varying_int32, @__max_uniform_int32)
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; horizontal uint32 ops

define i32 @__reduce_min_uint32(<8 x i32>) nounwind readnone alwaysinline {
  reduce8(i32, @__min_varying_uint32, @__min_uniform_uint32)
}

define i32 @__reduce_max_uint32(<8 x i32>) nounwind readnone alwaysinline {
  reduce8(i32, @__max_varying_uint32, @__max_uniform_uint32)
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; horizontal double ops

declare <4 x double> @llvm.x86.avx.hadd.pd.256(<4 x double>, <4 x double>) nounwind readnone

define double @__reduce_add_double(<8 x double>) nounwind readonly alwaysinline {
  %va = shufflevector <8 x double> %0, <8 x double> undef,
         <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %vb = shufflevector <8 x double> %0, <8 x double> undef,
         <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  %vab = fadd <4 x double> %va, %vb
  %sum0 = call <4 x double> @llvm.x86.avx.hadd.pd.256(<4 x double> %vab, <4 x double> %vab)
  %final0 = extractelement <4 x double> %sum0, i32 0
  %final1 = extractelement <4 x double> %sum0, i32 2
  %sum = fadd double %final0, %final1
  ret double %sum
}

define double @__reduce_min_double(<8 x double>) nounwind readnone alwaysinline {
  reduce8(double, @__min_varying_double, @__min_uniform_double)
}

define double @__reduce_max_double(<8 x double>) nounwind readnone alwaysinline {
  reduce8(double, @__max_varying_double, @__max_uniform_double)
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; horizontal int64 ops

define internal <8 x i64> @__add_varying_int64(<8 x i64>,
                                                <8 x i64>) nounwind readnone alwaysinline {
  %s = add <8 x i64> %0, %1
  ret <8 x i64> %s
}

define internal i64 @__add_uniform_int64(i64, i64) nounwind readnone alwaysinline {
  %s = add i64 %0, %1
  ret i64 %s
}

define i64 @__reduce_add_int64(<8 x i64>) nounwind readnone alwaysinline {
  reduce8(i64, @__add_varying_int64, @__add_uniform_int64)
}

define i64 @__reduce_min_int64(<8 x i64>) nounwind readnone alwaysinline {
  reduce8(i64, @__min_varying_int64, @__min_uniform_int64)
}

define i64 @__reduce_max_int64(<8 x i64>) nounwind readnone alwaysinline {
  reduce8(i64, @__max_varying_int64, @__max_uniform_int64)
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; horizontal uint64 ops

define i64 @__reduce_min_uint64(<8 x i64>) nounwind readnone alwaysinline {
  reduce8(i64, @__min_varying_uint64, @__min_uniform_uint64)
}

define i64 @__reduce_max_uint64(<8 x i64>) nounwind readnone alwaysinline {
  reduce8(i64, @__max_varying_uint64, @__max_uniform_uint64)
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; unaligned loads/loads+broadcasts

masked_load(i8,  1)
masked_load(i16, 2)

declare <8 x i32> @llvm.x86.avx512.mask.loadu.d.256(i8*, <8 x i32>, i8)
define <8 x i32> @__masked_load_i32(i8 * %ptr, <WIDTH x MASK> %mask) nounwind alwaysinline {
  %mask_i8 = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %mask)
  %res = call <8 x i32> @llvm.x86.avx512.mask.loadu.d.256(i8* %ptr, <8 x i32> zeroinitializer, i8 %mask_i8)
  ret <8 x i32> %res
}

declare <4 x i64> @llvm.x86.avx512.mask.loadu.q.256(i8*, <4 x i64>, i8)
define <8 x i64> @__masked_load_i64(i8 * %ptr, <WIDTH x MASK> %mask) nounwind alwaysinline {
  %mask_i8 = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %mask)
  %mask_shifted = lshr i8 %mask_i8, 4

  %ptr_d = bitcast i8* %ptr to <8 x i64>*
  %ptr_hi = getelementptr PTR_OP_ARGS(`<8 x i64>') %ptr_d, i32 0, i32 4
  %ptr_hi_i8 = bitcast i64* %ptr_hi to i8*

  %r0 = call <4 x i64> @llvm.x86.avx512.mask.loadu.q.256(i8* %ptr, <4 x i64> zeroinitializer, i8 %mask_i8)
  %r1 = call <4 x i64> @llvm.x86.avx512.mask.loadu.q.256(i8* %ptr_hi_i8, <4 x i64> zeroinitializer, i8 %mask_shifted)

  %res = shufflevector <4 x i64> %r0, <4 x i64> %r1,
                       <8 x i32> <i32 0, i32 1, i32 2, i32 3, i32 4, i32 5, i32 6, i32 7>
  ret <8 x i64> %res
}

declare <8 x float> @llvm.x86.avx512.mask.loadu.ps.256(i8*, <8 x float>, i8)
define <8 x float> @__masked_load_float(i8 * %ptr, <WIDTH x MASK> %mask) readonly alwaysinline {
  %mask_i8 = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %mask)
  %res = call <8 x float> @llvm.x86.avx512.mask.loadu.ps.256(i8* %ptr, <8 x float> zeroinitializer, i8 %mask_i8)
  ret <8 x float> %res
}

declare <4 x double> @llvm.x86.avx512.mask.loadu.pd.256(i8*, <4 x double>, i8)
define <8 x double> @__masked_load_double(i8 * %ptr, <WIDTH x MASK> %mask) readonly alwaysinline {
  %mask_i8 = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %mask)
  %mask_shifted = lshr i8 %mask_i8, 4

  %ptr_d = bitcast i8* %ptr to <8 x double>*
  %ptr_hi = getelementptr PTR_OP_ARGS(`<8 x double>') %ptr_d, i32 0, i32 4
  %ptr_hi_i8 = bitcast double* %ptr_hi to i8*

  %r0 = call <4 x double> @llvm.x86.avx512.mask.loadu.pd.256(i8* %ptr, <4 x double> zeroinitializer, i8 %mask_i8)
  %r1 = call <4 x double> @llvm.x86.avx512.mask.loadu.pd.256(i8* %ptr_hi_i8, <4 x double> zeroinitializer, i8 %mask_shifted)

  %res = shufflevector <4 x double> %r0, <4 x double> %r1, 
                       <8 x i32> <i32 0, i32 1, i32 2, i32 3, i32 4, i32 5, i32 6, i32 7>
  ret <8 x double> %res
}


gen_masked_store(i8) ; llvm.x86.sse2.storeu.dq
gen_masked_store(i16)

declare void @llvm.x86.avx512.mask.storeu.d.256(i8*, <8 x i32>, i8)
define void @__masked_store_i32(<8 x i32>* nocapture, <8 x i32> %v, <WIDTH x MASK> %mask) nounwind alwaysinline {
  %mask_i8 = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %mask)
  %ptr_i8 = bitcast <8 x i32>* %0 to i8*
  call void @llvm.x86.avx512.mask.storeu.d.256(i8* %ptr_i8, <8 x i32> %v, i8 %mask_i8)
  ret void
}

declare void @llvm.x86.avx512.mask.storeu.q.256(i8*, <4 x i64>, i8)
define void @__masked_store_i64(<8 x i64>* nocapture, <8 x i64> %v, <WIDTH x MASK> %mask) nounwind alwaysinline {
  %mask_i8 = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %mask)
  %mask_shifted = lshr i8 %mask_i8, 4

  %ptr_i8 = bitcast <8 x i64>* %0 to i8*
  %ptr_lo = getelementptr PTR_OP_ARGS(`<8 x i64>') %0, i32 0, i32 4
  %ptr_lo_i8 = bitcast i64* %ptr_lo to i8*

  %v_lo = shufflevector <8 x i64> %v, <8 x i64> undef,
                        <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %v_hi = shufflevector <8 x i64> %v, <8 x i64> undef,
                        <4 x i32> <i32 4, i32 5, i32 6, i32 7>

  call void @llvm.x86.avx512.mask.storeu.q.256(i8* %ptr_i8, <4 x i64> %v_lo, i8 %mask_i8)
  call void @llvm.x86.avx512.mask.storeu.q.256(i8* %ptr_lo_i8, <4 x i64> %v_hi, i8 %mask_shifted)
  ret void
}

declare void @llvm.x86.avx512.mask.storeu.ps.256(i8*, <8 x float>, i8)
define void @__masked_store_float(<8 x float>* nocapture, <8 x float> %v, <WIDTH x MASK> %mask) nounwind alwaysinline {
  %mask_i8 = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %mask)

  %ptr_i8 = bitcast <8 x float>* %0 to i8*
  call void @llvm.x86.avx512.mask.storeu.ps.256(i8* %ptr_i8, <8 x float> %v, i8 %mask_i8)
  ret void
}

declare void @llvm.x86.avx512.mask.storeu.pd.256(i8*, <4 x double>, i8)
define void @__masked_store_double(<8 x double>* nocapture, <8 x double> %v, <WIDTH x MASK> %mask) nounwind alwaysinline {
  %mask_i8 = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %mask)
  %mask_shifted = lshr i8 %mask_i8, 4

  %ptr_i8 = bitcast <8 x double>* %0 to i8*
  %ptr_lo = getelementptr PTR_OP_ARGS(`<8 x double>') %0, i32 0, i32 4
  %ptr_lo_i8 = bitcast double* %ptr_lo to i8*

  %v_lo = shufflevector <8 x double> %v, <8 x double> undef,
                        <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %v_hi = shufflevector <8 x double> %v, <8 x double> undef,
                        <4 x i32> <i32 4, i32 5, i32 6, i32 7>

  call void @llvm.x86.avx512.mask.storeu.pd.256(i8* %ptr_i8, <4 x double> %v_lo, i8 %mask_i8)
  call void @llvm.x86.avx512.mask.storeu.pd.256(i8* %ptr_lo_i8, <4 x double> %v_hi, i8 %mask_shifted)
  ret void
}

define void @__masked_store_blend_i8(<8 x i8>* nocapture, <8 x i8>,
                                     <WIDTH x MASK>) nounwind alwaysinline {
  %v = load PTR_OP_ARGS(`<8 x i8> ')  %0
  %mask_vec_i1 = call <WIDTH x i1> @__cast_mask_to_i1 (<WIDTH x MASK> %2)
  %v1 = select <WIDTH x i1> %mask_vec_i1, <8 x i8> %1, <8 x i8> %v
  store <8 x i8> %v1, <8 x i8> * %0
  ret void
}

define void @__masked_store_blend_i16(<8 x i16>* nocapture, <8 x i16>,
                                      <WIDTH x MASK>) nounwind alwaysinline {
  %v = load PTR_OP_ARGS(`<8 x i16> ')  %0
  %mask_vec_i1 = call <WIDTH x i1> @__cast_mask_to_i1 (<WIDTH x MASK> %2)
  %v1 = select <WIDTH x i1> %mask_vec_i1, <8 x i16> %1, <8 x i16> %v
  store <8 x i16> %v1, <8 x i16> * %0
  ret void
}

define void @__masked_store_blend_i32(<8 x i32>* nocapture, <8 x i32>,
                                      <WIDTH x MASK>) nounwind alwaysinline {
  %v = load PTR_OP_ARGS(`<8 x i32> ')  %0
  %mask_vec_i1 = call <WIDTH x i1> @__cast_mask_to_i1 (<WIDTH x MASK> %2)
  %v1 = select <WIDTH x i1> %mask_vec_i1, <8 x i32> %1, <8 x i32> %v
  store <8 x i32> %v1, <8 x i32> * %0
  ret void
}

define void @__masked_store_blend_float(<8 x float>* nocapture, <8 x float>, 
                                        <WIDTH x MASK>) nounwind alwaysinline {
  %v = load PTR_OP_ARGS(`<8 x float> ')  %0
  %mask_vec_i1 = call <WIDTH x i1> @__cast_mask_to_i1 (<WIDTH x MASK> %2)
  %v1 = select <WIDTH x i1> %mask_vec_i1, <8 x float> %1, <8 x float> %v
  store <8 x float> %v1, <8 x float> * %0
  ret void
}

define void @__masked_store_blend_i64(<8 x i64>* nocapture,
                            <8 x i64>, <WIDTH x MASK>) nounwind alwaysinline {
  %v = load PTR_OP_ARGS(`<8 x i64> ')  %0
  %mask_vec_i1 = call <WIDTH x i1> @__cast_mask_to_i1 (<WIDTH x MASK> %2)
  %v1 = select <WIDTH x i1> %mask_vec_i1, <8 x i64> %1, <8 x i64> %v
  store <8 x i64> %v1, <8 x i64> * %0
  ret void
}

define void @__masked_store_blend_double(<8 x double>* nocapture,
                            <8 x double>, <WIDTH x MASK>) nounwind alwaysinline {
  %v = load PTR_OP_ARGS(`<8 x double> ')  %0
  %mask_vec_i1 = call <WIDTH x i1> @__cast_mask_to_i1 (<WIDTH x MASK> %2)
  %v1 = select <WIDTH x i1> %mask_vec_i1, <8 x double> %1, <8 x double> %v
  store <8 x double> %v1, <8 x double> * %0
  ret void
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; gather/scatter

;; gather - i8
gen_gather(i8)

;; gather - i16
gen_gather(i16)

;; gather - i32
declare <8 x i32> @llvm.x86.avx512.gather3siv8.si(<8 x i32>, i8*, <8 x i32>, i8, i32)
define <8 x i32>
@__gather_base_offsets32_i32(i8 * %ptr, i32 %offset_scale, <8 x i32> %offsets, <WIDTH x MASK> %vecmask) nounwind readonly alwaysinline {
  %mask = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %vecmask)
  %res =  call <8 x i32> @llvm.x86.avx512.gather3siv8.si (<8 x i32> undef, i8* %ptr, <8 x i32> %offsets, i8 %mask, i32 %offset_scale)
  ret <8 x i32> %res
}

declare <4 x i32> @llvm.x86.avx512.gather3div8.si(<4 x i32>, i8*, <4 x i64>, i8, i32)
define <8 x i32>
@__gather_base_offsets64_i32(i8 * %ptr, i32 %offset_scale, <8 x i64> %offsets, <WIDTH x MASK> %vecmask) nounwind readonly alwaysinline {
  %scalarMask = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %vecmask)
  %scalarMask2 = lshr i8 %scalarMask, 4
  %offsets_lo = shufflevector <8 x i64> %offsets, <8 x i64> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %offsets_hi = shufflevector <8 x i64> %offsets, <8 x i64> undef, <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  %res1 = call <4 x i32> @llvm.x86.avx512.gather3div8.si (<4 x i32> undef, i8* %ptr, <4 x i64> %offsets_lo, i8 %scalarMask, i32 %offset_scale)
  %res2 = call <4 x i32> @llvm.x86.avx512.gather3div8.si (<4 x i32> undef, i8* %ptr, <4 x i64> %offsets_hi, i8 %scalarMask2, i32 %offset_scale)
  %res = shufflevector <4 x i32> %res1, <4 x i32> %res2 , <8 x i32> <i32 0, i32 1, i32 2, i32 3, i32 4, i32 5, i32 6, i32 7>
  ret <8 x i32> %res
}

define <8 x i32>
@__gather32_i32(<8 x i32> %ptrs, <WIDTH x MASK> %vecmask) nounwind readonly alwaysinline {
  %res = call <8 x i32> @__gather_base_offsets32_i32(i8 * zeroinitializer, i32 1, <8 x i32> %ptrs, <WIDTH x MASK> %vecmask)
  ret <8 x i32> %res
}

define <8 x i32>
@__gather64_i32(<8 x i64> %ptrs, <WIDTH x MASK> %vecmask) nounwind readonly alwaysinline {
  %res = call <8 x i32> @__gather_base_offsets64_i32(i8 * zeroinitializer, i32 1, <8 x i64> %ptrs, <WIDTH x MASK> %vecmask)
  ret <8 x i32> %res
}

;; gather - i64
gen_gather(i64)

;; gather - float
declare <8 x float> @llvm.x86.avx512.gather3siv8.sf(<8 x float>, i8*, <8 x i32>, i8, i32)
define <8 x float>
@__gather_base_offsets32_float(i8 * %ptr, i32 %offset_scale, <8 x i32> %offsets, <WIDTH x MASK> %vecmask) nounwind readonly alwaysinline {
  %mask = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %vecmask)
  %res = call <8 x float> @llvm.x86.avx512.gather3siv8.sf(<8 x float> undef, i8* %ptr, <8 x i32>%offsets, i8 %mask, i32 %offset_scale)
  ret <8 x float> %res
}

declare <4 x float> @llvm.x86.avx512.gather3div8.sf(<4 x float>, i8*, <4 x i64>, i8, i32)
define <8 x float>
@__gather_base_offsets64_float(i8 * %ptr, i32 %offset_scale, <8 x i64> %offsets, <WIDTH x MASK> %vecmask) nounwind readonly alwaysinline {
  %mask = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %vecmask)
  %mask_shifted = lshr i8 %mask, 4
  %offsets_lo = shufflevector <8 x i64> %offsets, <8 x i64> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %offsets_hi = shufflevector <8 x i64> %offsets, <8 x i64> undef, <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  %res_lo = call <4 x float> @llvm.x86.avx512.gather3div8.sf (<4 x float> undef, i8* %ptr, <4 x i64> %offsets_lo, i8 %mask, i32 %offset_scale)
  %res_hi = call <4 x float> @llvm.x86.avx512.gather3div8.sf (<4 x float> undef, i8* %ptr, <4 x i64> %offsets_hi, i8 %mask_shifted, i32 %offset_scale)
  %res = shufflevector <4 x float> %res_lo, <4 x float> %res_hi, <8 x i32> <i32 0, i32 1, i32 2, i32 3, i32 4, i32 5, i32 6, i32 7>
  ret <8 x float> %res
}

define <8 x float>
@__gather32_float(<8 x i32> %ptrs, <WIDTH x MASK> %vecmask) nounwind readonly alwaysinline {
  %res = call <8 x float> @__gather_base_offsets32_float(i8 * zeroinitializer, i32 1, <8 x i32> %ptrs, <WIDTH x MASK> %vecmask)
  ret <8 x float> %res
}

define <8 x float>
@__gather64_float(<8 x i64> %ptrs,  <WIDTH x MASK> %vecmask) nounwind readonly alwaysinline {
  %res = call <8 x float> @__gather_base_offsets64_float(i8 * zeroinitializer, i32 1, <8 x i64> %ptrs, <WIDTH x MASK> %vecmask)
  ret <8 x float> %res
}

;; gather - double
gen_gather(double)


define(`scatterbo32_64', `
define void @__scatter_base_offsets32_$1(i8* %ptr, i32 %scale, <WIDTH x i32> %offsets,
                                         <WIDTH x $1> %vals, <WIDTH x MASK> %mask) nounwind {
  call void @__scatter_factored_base_offsets32_$1(i8* %ptr, <8 x i32> %offsets,
      i32 %scale, <8 x i32> zeroinitializer, <8 x $1> %vals, <WIDTH x MASK> %mask)
  ret void
}

define void @__scatter_base_offsets64_$1(i8* %ptr, i32 %scale, <WIDTH x i64> %offsets,
                                         <WIDTH x $1> %vals, <WIDTH x MASK> %mask) nounwind {
  call void @__scatter_factored_base_offsets64_$1(i8* %ptr, <8 x i64> %offsets,
      i32 %scale, <8 x i64> zeroinitializer, <8 x $1> %vals, <WIDTH x MASK> %mask)
  ret void
}
')

;; scatter - i8
scatterbo32_64(i8)
gen_scatter(i8)

;; scatter - i16
scatterbo32_64(i16)
gen_scatter(i16)

;; scatter - i32
declare void @llvm.x86.avx512.scattersiv8.si(i8*, i8, <8 x i32>, <8 x i32>, i32)
define void
@__scatter_base_offsets32_i32(i8* %ptr, i32 %offset_scale, <8 x i32> %offsets, <8 x i32> %vals, <WIDTH x MASK> %vecmask) nounwind {
  %mask = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %vecmask)
  call void @llvm.x86.avx512.scattersiv8.si (i8* %ptr, i8 %mask, <8 x i32> %offsets, <8 x i32> %vals, i32 %offset_scale)
  ret void
}

declare void @llvm.x86.avx512.scatterdiv8.si(i8*, i8, <4 x i64>, <4 x i32>, i32)
define void
@__scatter_base_offsets64_i32(i8* %ptr, i32 %offset_scale, <8 x i64> %offsets, <8 x i32> %vals, <WIDTH x MASK> %vecmask) nounwind {
  %mask = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %vecmask)
  %mask_shifted = lshr i8 %mask, 4
  %offsets_lo = shufflevector <8 x i64> %offsets, <8 x i64> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %offsets_hi = shufflevector <8 x i64> %offsets, <8 x i64> undef, <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  %res_lo = shufflevector <8 x i32> %vals, <8 x i32> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %res_hi = shufflevector <8 x i32> %vals, <8 x i32> undef, <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  call void @llvm.x86.avx512.scatterdiv8.si (i8* %ptr, i8 %mask, <4 x i64> %offsets_lo, <4 x i32> %res_lo, i32 %offset_scale)
  call void @llvm.x86.avx512.scatterdiv8.si (i8* %ptr, i8 %mask_shifted, <4 x i64> %offsets_hi, <4 x i32> %res_hi, i32 %offset_scale)
  ret void
} 

define void
@__scatter32_i32(<8 x i32> %ptrs, <8 x i32> %values, <WIDTH x MASK> %vecmask) nounwind alwaysinline {
  call void @__scatter_base_offsets32_i32(i8 * zeroinitializer, i32 1, <8 x i32> %ptrs, <8 x i32> %values, <WIDTH x MASK> %vecmask)
  ret void
}

define void
@__scatter64_i32(<8 x i64> %ptrs, <8 x i32> %values, <WIDTH x MASK> %vecmask) nounwind alwaysinline {
  call void @__scatter_base_offsets64_i32(i8 * zeroinitializer, i32 1, <8 x i64> %ptrs, <8 x i32> %values, <WIDTH x MASK> %vecmask)
  ret void
}

;; scatter - i64
scatterbo32_64(i64)
gen_scatter(i64)

;; scatter - float
declare void @llvm.x86.avx512.scattersiv8.sf(i8*, i8, <8 x i32>, <8 x float>, i32)
define void
@__scatter_base_offsets32_float(i8* %ptr, i32 %offset_scale, <8 x i32> %offsets, <8 x float> %vals, <WIDTH x MASK> %vecmask) nounwind {
  %mask = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %vecmask)
  call void @llvm.x86.avx512.scattersiv8.sf (i8* %ptr, i8 %mask, <8 x i32> %offsets, <8 x float> %vals, i32 %offset_scale)
  ret void
}

declare void @llvm.x86.avx512.scatterdiv8.sf(i8*, i8, <4 x i64>, <4 x float>, i32)
define void
@__scatter_base_offsets64_float(i8* %ptr, i32 %offset_scale, <8 x i64> %offsets, <8 x float> %vals, <WIDTH x MASK> %vecmask) nounwind {
  %mask = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %vecmask)
  %mask_shifted = lshr i8 %mask, 4
  %offsets_lo = shufflevector <8 x i64> %offsets, <8 x i64> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %offsets_hi = shufflevector <8 x i64> %offsets, <8 x i64> undef, <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  %res_lo = shufflevector <8 x float> %vals, <8 x float> undef, <4 x i32> <i32 0, i32 1, i32 2, i32 3>
  %res_hi = shufflevector <8 x float> %vals, <8 x float> undef, <4 x i32> <i32 4, i32 5, i32 6, i32 7>
  call void @llvm.x86.avx512.scatterdiv8.sf (i8* %ptr, i8 %mask, <4 x i64> %offsets_lo, <4 x float> %res_lo, i32 %offset_scale)
  call void @llvm.x86.avx512.scatterdiv8.sf (i8* %ptr, i8 %mask_shifted, <4 x i64> %offsets_hi, <4 x float> %res_hi, i32 %offset_scale)
  ret void
} 

define void 
@__scatter32_float(<8 x i32> %ptrs, <8 x float> %values, <WIDTH x MASK> %vecmask) nounwind alwaysinline {
  call void @__scatter_base_offsets32_float(i8 * zeroinitializer, i32 1, <8 x i32> %ptrs, <8 x float> %values, <WIDTH x MASK> %vecmask)
  ret void
}

define void 
@__scatter64_float(<8 x i64> %ptrs, <8 x float> %values, <WIDTH x MASK> %vecmask) nounwind alwaysinline {
  call void @__scatter_base_offsets64_float(i8 * zeroinitializer, i32 1, <8 x i64> %ptrs, <8 x float> %values, <WIDTH x MASK> %vecmask)
  ret void
}

;; scatter - double
scatterbo32_64(double)
gen_scatter(double)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; packed_load/store

declare <8 x i32> @llvm.x86.avx512.mask.expand.load.d.256(i8* %addr, <8 x i32> %data, i8 %mask)

define i32 @__packed_load_active(i32 * %startptr, <8 x i32> * %val_ptr,
                                 <WIDTH x MASK> %full_mask) nounwind alwaysinline {
  %addr = bitcast i32* %startptr to i8*
  %data = load PTR_OP_ARGS(`<8 x i32> ') %val_ptr
  %mask = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %full_mask)
  %store_val = call <8 x i32> @llvm.x86.avx512.mask.expand.load.d.256(i8* %addr, <8 x i32> %data, i8 %mask)
  store <8 x i32> %store_val, <8 x i32> * %val_ptr
  %mask_i32 = zext i8 %mask to i32
  %res = call i32 @llvm.ctpop.i32(i32 %mask_i32)
  ret i32 %res
}

declare void @llvm.x86.avx512.mask.compress.store.d.256(i8* %addr, <8 x i32> %data, i8 %mask)

define i32 @__packed_store_active(i32 * %startptr, <8 x i32> %vals,
                                   <WIDTH x MASK> %full_mask) nounwind alwaysinline {
  %addr = bitcast i32* %startptr to i8*
  %mask = call i8 @__cast_mask_to_i8 (<WIDTH x MASK> %full_mask)
  call void @llvm.x86.avx512.mask.compress.store.d.256(i8* %addr, <8 x i32> %vals, i8 %mask)
  %mask_i32 = zext i8 %mask to i32
  %res = call i32 @llvm.ctpop.i32(i32 %mask_i32)
  ret i32 %res
}

define i32 @__packed_store_active2(i32 * %startptr, <8 x i32> %vals,
                                   <WIDTH x MASK> %full_mask) nounwind alwaysinline {
  %res = call i32 @__packed_store_active(i32 * %startptr, <8 x i32> %vals,
                                   <WIDTH x MASK> %full_mask)
  ret i32 %res
}

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; prefetch

define_prefetches()

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; int8/int16 builtins

define_avgs()
declare_nvptx()

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; reciprocals in double precision, if supported

rsqrtd_decl()
rcpd_decl()

transcendetals_decl()
;; Trigonometry
trigonometry_decl()
