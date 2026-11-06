#include "LooprStatisticsCore.h"
#include <math.h>

// Preserve separate multiply/add rounding and the Swift reference's order.
#pragma STDC FP_CONTRACT OFF
void loopr_accumulate_normal(const double *vectors, const double *residuals,
                             size_t row_count, size_t column_count,
                             double *normal, double *rhs) {
    for (size_t row = 0; row < row_count; ++row) {
        const double *vector = vectors + row * column_count;
        for (size_t i = 0; i < column_count; ++i) {
            rhs[i] += vector[i] * residuals[row];
            for (size_t j = 0; j < column_count; ++j) {
                normal[i * column_count + j] += vector[i] * vector[j];
            }
        }
    }
}

int loopr_solve_normal(double *values, size_t count, double *coefficients) {
    const size_t stride = count + 1;
    for (size_t pivot = 0; pivot < count; ++pivot) {
        size_t row = pivot;
        for (size_t candidate = pivot + 1; candidate < count; ++candidate) {
            if (fabs(values[row * stride + pivot]) < fabs(values[candidate * stride + pivot])) {
                row = candidate;
            }
        }
        if (!(fabs(values[row * stride + pivot]) > 1e-12)) return 0;
        const size_t pivot_start = pivot * stride;
        if (row != pivot) {
            for (size_t column = 0; column <= count; ++column) {
                const double old = values[row * stride + column];
                values[row * stride + column] = values[pivot_start + column];
                values[pivot_start + column] = old;
            }
        }
        const double divisor = values[pivot_start + pivot];
        for (size_t column = pivot; column <= count; ++column) values[pivot_start + column] /= divisor;
        for (size_t row_index = 0; row_index < count; ++row_index) {
            if (row_index == pivot) continue;
            const size_t row_start = row_index * stride;
            const double factor = values[row_start + pivot];
            if (factor == 0) continue;
            for (size_t column = pivot; column <= count; ++column) {
                values[row_start + column] -= factor * values[pivot_start + column];
            }
        }
    }
    for (size_t row = 0; row < count; ++row) coefficients[row] = values[row * stride + count];
    return 1;
}
