#include <ruby.h>
#include "carray.h"

/*
 * Address bases for JIT kernels.
 *
 * A generated kernel addresses cells itself -- it reads a[i-1] and writes
 * a[i] -- so what it needs from CArray is not element delivery but an
 * addressing basis: a pointer, a byte offset, and one byte stride per axis.
 * That is why this does not sit on the kernel iterator (per-cell/per-slab
 * delivery, and no N-ary form) or on the sweep ELEMENT family (which
 * flattens the array and cannot recover the axis structure a stencil needs).
 *
 * Arrays are classified in the order the public predicates suggest:
 *
 *   1. ca_is_entity          -> the buffer is already the basis
 *   2. ca_is_stride_family   -> ca_stride_compose_to_root folds the whole
 *                               view chain into root + base + strides, so a
 *                               transpose or a column slice is addressed in
 *                               place, with no gather and no scatter
 *   3. otherwise             -> ca_xfer_stride moves only the box the kernel
 *                               actually touches -- the loop range grown by
 *                               how far the kernel reaches, per array and per
 *                               axis -- into a packed buffer, and writes that
 *                               box back
 *
 * Tier 3 deliberately never calls ca_attach on the view.  A whole-view
 * materialise costs the same whether the kernel touches ten cells or ten
 * million: measured on a four-million-element gather view, ca_attach was
 * 2.7 ms regardless, while the region transfer was 0.001 ms for a hundred
 * cells and 2.3 ms for a million.  A cost that does not scale with the work
 * is a cost the caller cannot reason about, and hiding one behind a JIT
 * would make its promise meaningless.  What tier 3 does cost is proportional
 * to what the kernel asked to touch.
 */

#define TIER_ENTITY 1
#define TIER_STRIDE 2
#define TIER_ATTACH 3

/* Slot layout: slot i is array i, slot count + i is that array's mask.
   A mask is a CArray of the same shape as its parent and, for a view, the
   same kind of view -- a CABlock's mask is a CABlockMask -- so it is opened
   by exactly the same tier logic as the data. */
typedef struct {
  int        count;
  int        slots;
  VALUE      arrays;
  CArray   **carrays;
  CArray   **roots;
  int       *tier;
  int       *writable;
  int       *attached_root;
  char     **region;          /* tier 3 packed buffer, NULL otherwise */
  ca_size_t *region_start;    /* count * CA_RANK_MAX */
  ca_size_t *region_count;
  VALUE      bases;
  VALUE      box_starts;      /* per array, per axis; nil for "all of it" */
  VALUE      box_counts;
} open_state;

/* The view's own row-major byte layout, which is the address space
   ca_xfer_stride describes a region in. */
static void
native_steps (CArray *ca, ca_size_t *steps)
{
  ca_size_t step = ca->bytes;
  int8_t k;
  for ( k = ca->ndim - 1; k >= 0; k-- ) {
    steps[k] = step;
    step *= ca->dim[k];
  }
}

/* Checks one array's box description.  Run for every array, whatever tier it
   lands in, so that the same call is refused the same way regardless of what
   the array turns out to be -- and because this is a C extension, where a
   wrong type has to be a message and not a crash. */
static void
verify_box (VALUE box_starts, VALUE box_counts, int index, CArray *ca)
{
  VALUE starts, counts;
  if ( NIL_P(box_starts) ) return;
  starts = rb_ary_entry(box_starts, index);
  counts = rb_ary_entry(box_counts, index);
  if ( NIL_P(starts) && NIL_P(counts) ) return;
  Check_Type(starts, T_ARRAY);
  Check_Type(counts, T_ARRAY);
  if ( RARRAY_LEN(starts) != ca->ndim || RARRAY_LEN(counts) != ca->ndim ) {
    rb_raise(rb_eArgError,
             "a region is described by one start and one count per axis; "
             "this array has %d", (int) ca->ndim);
  }
}

/* Reads one array's box out of the Ruby-side description, defaulting to the
   whole array.  Its shape was checked by verify_box. */
static void
read_box (open_state *state, int index, CArray *ca,
          ca_size_t *starts, ca_size_t *counts)
{
  VALUE per_array_start = Qnil, per_array_count = Qnil;
  int8_t k;

  if ( ! NIL_P(state->box_starts) ) {
    per_array_start = rb_ary_entry(state->box_starts, index);
    per_array_count = rb_ary_entry(state->box_counts, index);
  }

  for ( k = 0; k < ca->ndim; k++ ) {
    if ( NIL_P(per_array_start) ) {
      starts[k] = 0;
      counts[k] = ca->dim[k];
    } else {
      starts[k] = NUM2LL(rb_ary_entry(per_array_start, k));
      counts[k] = NUM2LL(rb_ary_entry(per_array_count, k));
    }
    if ( starts[k] < 0 || counts[k] < 0 || starts[k] + counts[k] > ca->dim[k] ) {
      rb_raise(rb_eArgError,
               "the requested region falls outside the array on axis %d", (int) k);
    }
  }
}

static void
row_major_strides (CArray *ca, ca_size_t *strides)
{
  ca_size_t step = ca->bytes;
  int8_t k;
  for ( k = ca->ndim - 1; k >= 0; k-- ) {
    strides[k] = step;
    step *= ca->dim[k];
  }
}

static VALUE
size_array (ca_size_t *values, int8_t count)
{
  VALUE list = rb_ary_new_capa(count);
  int8_t k;
  for ( k = 0; k < count; k++ ) {
    rb_ary_push(list, LL2NUM((long long) values[k]));
  }
  return list;
}

/* Refuses what a generated kernel cannot express, rather than letting it
   produce quietly wrong numbers. */
static void
verify_usable (VALUE object, CArray *ca, int writable)
{
  if ( ca->data_type == CA_OBJECT ) {
    rb_raise(rb_eArgError, "object arrays hold Ruby values, not numbers");
  }
  if ( writable && ca_is_readonly(ca) ) {
    rb_raise(rb_eRuntimeError, "%"PRIsVALUE" is read-only",
             rb_obj_class(object));
  }
}

/* The stride tier addresses the fold's root directly, which is only sound
   when that root owns its memory.  ca_stride_compose_to_root stops at the
   first thing it cannot fold through, and that need not be an entity: a
   CARefer over a gather view (`whole[whole >= 0].reshape(4, 4)`) folds one
   step and lands on the CASelect.  Attaching a root like that materialises a
   temporary, and detaching it throws the kernel's writes away -- silently.
   So a fold that does not reach an entity is not the stride tier; the box
   transfer handles it, and moves only the cells the kernel asked for. */
static int
folds_to_an_entity (CArray *ca)
{
  CArray   *root;
  ca_size_t strides[CA_RANK_MAX];
  ca_size_t base = 0;
  ca_stride_compose_to_root((CAStride *) ca, &root, strides, &base);
  return ca_is_entity(root);
}

static int
tier_for (CArray *ca)
{
  if ( ca_is_entity(ca) ) return TIER_ENTITY;
  if ( ca_is_stride_family(ca) && folds_to_an_entity(ca) ) return TIER_STRIDE;
  return TIER_ATTACH;
}

static VALUE
basis_for (open_state *state, int index)
{
  CArray   *ca = state->carrays[index];
  ca_size_t strides[CA_RANK_MAX];
  ca_size_t base = 0;
  char     *pointer;
  VALUE     result;

  switch ( state->tier[index] ) {
  case TIER_ENTITY: {
    CArray *root = ca;
    ca_attach(root);
    state->roots[index] = root;
    state->attached_root[index] = 1;
    row_major_strides(ca, strides);
    pointer = ca->ptr;
    break;
  }

  case TIER_STRIDE: {
    CArray *root;
    ca_stride_compose_to_root((CAStride *) ca, &root, strides, &base);
    /* A view that reinterprets the element size -- refer(CA_INT32, ...) over
       a float64 array -- gets a mask of its own shape, but one mask cell of
       it covers a fraction of a parent cell, so writing cell i's mask also
       marks its neighbour.  A per-cell kernel writes cells independently and
       cannot express that. */
    if ( ca->mask && ca->bytes != root->bytes ) {
      rb_raise(rb_eArgError,
               "%"PRIsVALUE" reinterprets the element size and carries a mask; "
               "its mask cells do not map one to one onto the parent's",
               rb_obj_class(rb_ary_entry(state->arrays, index)));
    }
    ca_attach(root);
    state->roots[index] = root;
    state->attached_root[index] = 1;
    pointer = root->ptr + base;
    break;
  }

  default: {
    /* Only the requested box crosses, never the whole view. */
    ca_size_t starts[CA_RANK_MAX], counts[CA_RANK_MAX], steps[CA_RANK_MAX];
    ca_size_t elements = 1, shift = 0, step;
    int8_t    k;
    char     *buffer;

    native_steps(ca, steps);
    read_box(state, index, ca, starts, counts);
    for ( k = 0; k < ca->ndim; k++ ) elements *= counts[k];

    /* ca_xfer_stride packs the box row-major, so the buffer's strides come
       from the box's own extents, not the view's. */
    step = ca->bytes;
    for ( k = ca->ndim - 1; k >= 0; k-- ) {
      strides[k] = step;
      step *= counts[k];
    }

    buffer = ALLOC_N(char, (elements > 0 ? elements : 1) * ca->bytes);
    if ( elements > 0 ) {
      ca_xfer_stride(ca, starts, counts, steps, buffer, CA_XFER_GET);
    }

    state->region[index] = buffer;
    for ( k = 0; k < ca->ndim; k++ ) {
      state->region_start[index * CA_RANK_MAX + k] = starts[k];
      state->region_count[index * CA_RANK_MAX + k] = counts[k];
      shift += starts[k] * strides[k];
    }
    /* Shifted so that the box's first cell lands on buffer[0], the way a
       view's base_offset shifts its parent's pointer. */
    pointer = buffer - shift;
    break;
  }
  }

  result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(rb_intern("tier")), INT2NUM(state->tier[index]));
  rb_hash_aset(result, ID2SYM(rb_intern("pointer")),
               ULL2NUM((unsigned long long)(uintptr_t) pointer));
  rb_hash_aset(result, ID2SYM(rb_intern("strides")), size_array(strides, ca->ndim));
  rb_hash_aset(result, ID2SYM(rb_intern("dim")), size_array(ca->dim, ca->ndim));
  rb_hash_aset(result, ID2SYM(rb_intern("bytes")), LL2NUM((long long) ca->bytes));
  rb_hash_aset(result, ID2SYM(rb_intern("data_type")), INT2NUM(ca->data_type));
  rb_hash_aset(result, ID2SYM(rb_intern("writable")),
               state->writable[index] ? Qtrue : Qfalse);
  return result;
}

/* Each array's basis, with its mask's basis folded in under :mask_pointer
   and :mask_strides (nil when the array carries no mask). */
static VALUE
open_body (VALUE argument);

static VALUE
open_body (VALUE argument)
{
  open_state *state = (open_state *) argument;
  int i;
  for ( i = 0; i < state->count; i++ ) {
    VALUE basis = basis_for(state, i);
    if ( state->carrays[state->count + i] ) {
      VALUE mask = basis_for(state, state->count + i);
      rb_hash_aset(basis, ID2SYM(rb_intern("mask_pointer")),
                   rb_hash_aref(mask, ID2SYM(rb_intern("pointer"))));
      rb_hash_aset(basis, ID2SYM(rb_intern("mask_strides")),
                   rb_hash_aref(mask, ID2SYM(rb_intern("strides"))));
    } else {
      rb_hash_aset(basis, ID2SYM(rb_intern("mask_pointer")), Qnil);
      rb_hash_aset(basis, ID2SYM(rb_intern("mask_strides")), Qnil);
    }
    rb_ary_push(state->bases, basis);
  }
  return rb_yield(state->bases);
}

/* Closes in reverse order, and runs whether or not the kernel raised. */
static VALUE
open_ensure (VALUE argument)
{
  open_state *state = (open_state *) argument;
  int i;
  for ( i = state->slots - 1; i >= 0; i-- ) {
    CArray *ca = state->carrays[i];
    if ( ca == NULL ) continue;
    /* A tier-1 or tier-2 basis addresses the root's own memory, so a write is
       already where it belongs.  Only a region buffer has to be sent back. */
    if ( state->region[i] ) {
      ca_size_t elements = 1;
      int8_t k;
      for ( k = 0; k < ca->ndim; k++ ) {
        elements *= state->region_count[i * CA_RANK_MAX + k];
      }
      if ( state->writable[i] && elements > 0 ) {
        ca_size_t steps[CA_RANK_MAX];
        native_steps(ca, steps);
        ca_xfer_stride(ca, &state->region_start[i * CA_RANK_MAX],
                       &state->region_count[i * CA_RANK_MAX],
                       steps, state->region[i], CA_XFER_PUT);
      }
      xfree(state->region[i]);
    }
    if ( state->attached_root[i] ) {
      ca_detach(state->roots[i]);
    }
  }
  xfree(state->carrays);
  xfree(state->roots);
  xfree(state->tier);
  xfree(state->writable);
  xfree(state->attached_root);
  xfree(state->region);
  xfree(state->region_start);
  xfree(state->region_count);
  return Qnil;
}

/*
 * Opens every array, yields one basis hash per array, and closes them all
 * on the way out -- including when the block raises.
 */
static VALUE
access_open (int argc, VALUE *argv, VALUE module)
{
  VALUE arrays, writable_flags, box_start, box_count;
  open_state state;
  int i;

  rb_scan_args(argc, argv, "22", &arrays, &writable_flags, &box_start, &box_count);
  Check_Type(arrays, T_ARRAY);
  Check_Type(writable_flags, T_ARRAY);
  if ( NIL_P(box_start) != NIL_P(box_count) ) {
    rb_raise(rb_eArgError, "a region needs both starts and counts");
  }
  if ( ! NIL_P(box_start) ) {
    Check_Type(box_start, T_ARRAY);
    Check_Type(box_count, T_ARRAY);
    if ( RARRAY_LEN(box_start) != RARRAY_LEN(arrays) ||
         RARRAY_LEN(box_count) != RARRAY_LEN(arrays) ) {
      rb_raise(rb_eArgError, "one region per array is required");
    }
  }
  if ( RARRAY_LEN(arrays) != RARRAY_LEN(writable_flags) ) {
    rb_raise(rb_eArgError, "one writable flag per array is required");
  }

  state.count         = (int) RARRAY_LEN(arrays);
  state.slots         = state.count * 2;
  state.arrays        = arrays;
  state.bases         = rb_ary_new_capa(state.count);
  state.carrays       = ALLOC_N(CArray *, state.slots + 1);
  state.roots         = ALLOC_N(CArray *, state.slots + 1);
  state.tier          = ALLOC_N(int, state.slots + 1);
  state.writable      = ALLOC_N(int, state.slots + 1);
  state.attached_root = ALLOC_N(int, state.slots + 1);
  state.region        = ALLOC_N(char *, state.slots + 1);
  state.region_start  = ALLOC_N(ca_size_t, (state.slots + 1) * CA_RANK_MAX);
  state.region_count  = ALLOC_N(ca_size_t, (state.slots + 1) * CA_RANK_MAX);
  state.box_starts    = box_start;
  state.box_counts    = box_count;

  for ( i = 0; i < state.slots; i++ ) {
    state.carrays[i]       = NULL;
    state.roots[i]         = NULL;
    state.writable[i]      = 0;
    state.attached_root[i] = 0;
    state.region[i]        = NULL;
    memset(&state.region_start[i * CA_RANK_MAX], 0,
           sizeof(ca_size_t) * CA_RANK_MAX);
    memset(&state.region_count[i * CA_RANK_MAX], 0,
           sizeof(ca_size_t) * CA_RANK_MAX);
  }

  for ( i = 0; i < state.count; i++ ) {
    VALUE   object = rb_ary_entry(arrays, i);
    CArray *ca;
    GetCArray(object, ca);
    state.carrays[i]  = ca;
    state.writable[i] = RTEST(rb_ary_entry(writable_flags, i));
    verify_usable(object, ca, state.writable[i]);
    verify_box(box_start, box_count, i, ca);
    state.tier[i] = tier_for(ca);

    if ( ca->mask ) {
      CArray *mask = ca->mask;
      state.carrays[state.count + i]  = mask;
      state.writable[state.count + i] = state.writable[i];
      state.tier[state.count + i] = tier_for(mask);
    }
  }

  return rb_ensure(open_body, (VALUE) &state, open_ensure, (VALUE) &state);
}

/* Reports how an array would be opened, without opening it. */
static VALUE
access_classify (VALUE module, VALUE object)
{
  CArray *ca;
  VALUE   result;
  int     tier;

  GetCArray(object, ca);
  tier = tier_for(ca);

  result = rb_hash_new();
  rb_hash_aset(result, ID2SYM(rb_intern("tier")), INT2NUM(tier));
  rb_hash_aset(result, ID2SYM(rb_intern("entity")), ca_is_entity(ca) ? Qtrue : Qfalse);
  rb_hash_aset(result, ID2SYM(rb_intern("stride_family")),
               ca_is_stride_family(ca) ? Qtrue : Qfalse);
  rb_hash_aset(result, ID2SYM(rb_intern("read_only")), ca_is_readonly(ca) ? Qtrue : Qfalse);
  rb_hash_aset(result, ID2SYM(rb_intern("masked")), ca_has_mask(ca) ? Qtrue : Qfalse);
  rb_hash_aset(result, ID2SYM(rb_intern("dim")), size_array(ca->dim, ca->ndim));
  rb_hash_aset(result, ID2SYM(rb_intern("bytes")), LL2NUM((long long) ca->bytes));
  rb_hash_aset(result, ID2SYM(rb_intern("data_type")), INT2NUM(ca->data_type));
  return result;
}

void
Init_access (void)
{
  VALUE cCArray = rb_const_get(rb_cObject, rb_intern("CArray"));
  VALUE mJIT    = rb_define_module_under(cCArray, "JIT");
  VALUE mAccess = rb_define_module_under(mJIT, "Access");

  rb_define_singleton_method(mAccess, "open", access_open, -1);
  rb_define_singleton_method(mAccess, "classify", access_classify, 1);

  rb_define_const(mAccess, "TIER_ENTITY", INT2NUM(TIER_ENTITY));
  rb_define_const(mAccess, "TIER_STRIDE", INT2NUM(TIER_STRIDE));
  rb_define_const(mAccess, "TIER_ATTACH", INT2NUM(TIER_ATTACH));
}
