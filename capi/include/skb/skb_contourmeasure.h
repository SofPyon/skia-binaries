#ifndef skb_contourmeasure_DEFINED
#define skb_contourmeasure_DEFINED

#include "include/c/sk_types.h"

SK_C_PLUS_PLUS_BEGIN_GUARD

typedef struct skb_contourmeasure_t skb_contourmeasure_t;
typedef struct skb_contourmeasureiter_t skb_contourmeasureiter_t;

SK_C_API skb_contourmeasureiter_t* skb_contourmeasureiter_new(const sk_path_t* path, bool forceClosed, float resScale);
SK_C_API void skb_contourmeasureiter_reset(skb_contourmeasureiter_t*, const sk_path_t* path, bool forceClosed, float resScale);
SK_C_API void skb_contourmeasureiter_delete(skb_contourmeasureiter_t*);
/* Returns an owned reference, or NULL at the end. Zero-length contours are skipped. */
SK_C_API skb_contourmeasure_t* skb_contourmeasureiter_next(skb_contourmeasureiter_t*);

SK_C_API void skb_contourmeasure_ref(skb_contourmeasure_t*);
SK_C_API void skb_contourmeasure_unref(skb_contourmeasure_t*);
SK_C_API float skb_contourmeasure_get_length(const skb_contourmeasure_t*);
SK_C_API bool skb_contourmeasure_is_closed(const skb_contourmeasure_t*);
/* Distances are pinned to [0, length]. */
SK_C_API bool skb_contourmeasure_get_pos_tan(const skb_contourmeasure_t*, float distance, sk_point_t* position, sk_vector_t* tangent);
SK_C_API bool skb_contourmeasure_get_matrix(const skb_contourmeasure_t*, float distance, sk_matrix_t* matrix, sk_pathmeasure_matrixflags_t flags);
SK_C_API bool skb_contourmeasure_get_segment(const skb_contourmeasure_t*, float start, float stop, sk_pathbuilder_t* dst, bool startWithMoveTo);

SK_C_PLUS_PLUS_END_GUARD

#endif
