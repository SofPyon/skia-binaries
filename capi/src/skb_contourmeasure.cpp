#include "include/skb/skb_contourmeasure.h"

#include "include/core/SkContourMeasure.h"
#include "include/core/SkMatrix.h"
#include "include/core/SkPath.h"
#include "include/core/SkPathBuilder.h"
#include "include/core/SkRefCnt.h"
#include "src/c/sk_types_priv.h"

namespace {
SkContourMeasure* AsContourMeasure(skb_contourmeasure_t* measure) {
    return reinterpret_cast<SkContourMeasure*>(measure);
}
const SkContourMeasure* AsContourMeasure(const skb_contourmeasure_t* measure) {
    return reinterpret_cast<const SkContourMeasure*>(measure);
}
skb_contourmeasure_t* ToContourMeasure(SkContourMeasure* measure) {
    return reinterpret_cast<skb_contourmeasure_t*>(measure);
}
SkContourMeasureIter* AsContourMeasureIter(skb_contourmeasureiter_t* iter) {
    return reinterpret_cast<SkContourMeasureIter*>(iter);
}
skb_contourmeasureiter_t* ToContourMeasureIter(SkContourMeasureIter* iter) {
    return reinterpret_cast<skb_contourmeasureiter_t*>(iter);
}
}

skb_contourmeasureiter_t* skb_contourmeasureiter_new(const sk_path_t* path, bool forceClosed, float resScale) {
    return ToContourMeasureIter(new SkContourMeasureIter(*AsPath(path), forceClosed, resScale));
}

void skb_contourmeasureiter_reset(skb_contourmeasureiter_t* iter, const sk_path_t* path, bool forceClosed, float resScale) {
    AsContourMeasureIter(iter)->reset(*AsPath(path), forceClosed, resScale);
}

void skb_contourmeasureiter_delete(skb_contourmeasureiter_t* iter) {
    delete AsContourMeasureIter(iter);
}

skb_contourmeasure_t* skb_contourmeasureiter_next(skb_contourmeasureiter_t* iter) {
    return ToContourMeasure(AsContourMeasureIter(iter)->next().release());
}

void skb_contourmeasure_ref(skb_contourmeasure_t* measure) {
    AsContourMeasure(measure)->ref();
}

void skb_contourmeasure_unref(skb_contourmeasure_t* measure) {
    SkSafeUnref(AsContourMeasure(measure));
}

float skb_contourmeasure_get_length(const skb_contourmeasure_t* measure) {
    return AsContourMeasure(measure)->length();
}

bool skb_contourmeasure_is_closed(const skb_contourmeasure_t* measure) {
    return AsContourMeasure(measure)->isClosed();
}

bool skb_contourmeasure_get_pos_tan(const skb_contourmeasure_t* measure, float distance, sk_point_t* position, sk_vector_t* tangent) {
    return AsContourMeasure(measure)->getPosTan(distance, AsPoint(position), AsPoint(tangent));
}

bool skb_contourmeasure_get_matrix(const skb_contourmeasure_t* measure, float distance, sk_matrix_t* matrix, sk_pathmeasure_matrixflags_t flags) {
    SkMatrix skmatrix;
    bool result = AsContourMeasure(measure)->getMatrix(distance, &skmatrix, static_cast<SkContourMeasure::MatrixFlags>(flags));
    *matrix = ToMatrix(&skmatrix);
    return result;
}

bool skb_contourmeasure_get_segment(const skb_contourmeasure_t* measure, float start, float stop, sk_pathbuilder_t* dst, bool startWithMoveTo) {
    return AsContourMeasure(measure)->getSegment(start, stop, AsPathBuilder(dst), startWithMoveTo);
}
