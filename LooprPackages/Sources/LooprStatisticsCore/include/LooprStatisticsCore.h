#ifndef LOOPR_STATISTICS_CORE_H
#define LOOPR_STATISTICS_CORE_H
#include <stddef.h>

/// Accumulates X'X and X'y in row, column, column order. Outputs must be
/// zero-initialized; vectors contains row_count * column_count doubles.
void loopr_accumulate_normal(const double *vectors, const double *residuals,
                             size_t row_count, size_t column_count,
                             double *normal, double *rhs);

/// Gauss-Jordan elimination with the reference's first-largest pivot rule.
/// augmented contains count * (count + 1) doubles and is mutated in place.
/// Returns zero for a singular pivot; coefficients has space for count doubles.
int loopr_solve_normal(double *augmented, size_t count, double *coefficients);
#endif
