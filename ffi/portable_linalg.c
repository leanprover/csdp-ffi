/*
 * Portable fallback for the BLAS/LAPACK entry points used by CSDP.
 *
 * This is intentionally a small reference implementation, not a general
 * replacement for BLAS or LAPACK.  It lets csdp-ffi build in restricted
 * environments without native linear-algebra packages.  Normal installations
 * continue to use their tuned system libraries.
 */

#include <ctype.h>
#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

static int option_is(const char *option, char expected)
{
  return option != NULL && toupper((unsigned char)*option) == expected;
}

static ptrdiff_t vector_start(int n, int increment)
{
  return increment < 0 ? (ptrdiff_t)(1 - n) * increment : 0;
}

double dnrm2_(const int *n, const double *x, const int *incx)
{
  int i;
  ptrdiff_t ix;
  double scale = 0.0;
  double squares = 1.0;

  if (*n <= 0 || *incx == 0)
    return 0.0;
  ix = vector_start(*n, *incx);
  for (i = 0; i < *n; ++i, ix += *incx) {
    double value = fabs(x[ix]);
    if (value != 0.0) {
      if (scale < value) {
        double ratio = scale / value;
        squares = 1.0 + squares * ratio * ratio;
        scale = value;
      } else {
        double ratio = value / scale;
        squares += ratio * ratio;
      }
    }
  }
  return scale == 0.0 ? 0.0 : scale * sqrt(squares);
}

double dasum_(const int *n, const double *x, const int *incx)
{
  int i;
  ptrdiff_t ix;
  double sum = 0.0;

  if (*n <= 0 || *incx <= 0)
    return 0.0;
  ix = vector_start(*n, *incx);
  for (i = 0; i < *n; ++i, ix += *incx)
    sum += fabs(x[ix]);
  return sum;
}

double ddot_(const int *n, const double *x, const int *incx,
             const double *y, const int *incy)
{
  int i;
  ptrdiff_t ix;
  ptrdiff_t iy;
  double sum = 0.0;

  if (*n <= 0 || *incx == 0 || *incy == 0)
    return 0.0;
  ix = vector_start(*n, *incx);
  iy = vector_start(*n, *incy);
  for (i = 0; i < *n; ++i, ix += *incx, iy += *incy)
    sum += x[ix] * y[iy];
  return sum;
}

int idamax_(const int *n, const double *x, const int *incx)
{
  int i;
  int best = 1;
  ptrdiff_t ix;
  double largest;

  if (*n < 1 || *incx <= 0)
    return 0;
  ix = vector_start(*n, *incx);
  largest = fabs(x[ix]);
  for (i = 1, ix += *incx; i < *n; ++i, ix += *incx) {
    double value = fabs(x[ix]);
    if (value > largest) {
      largest = value;
      best = i + 1;
    }
  }
  return best;
}

void dgemv_(const char *trans, const int *m, const int *n,
            const double *alpha, const double *a, const int *lda,
            const double *x, const int *incx, const double *beta,
            double *y, const int *incy)
{
  int i;
  int j;
  int transposed = !option_is(trans, 'N');
  int x_length = transposed ? *m : *n;
  int y_length = transposed ? *n : *m;
  ptrdiff_t x_start = vector_start(x_length, *incx);
  ptrdiff_t y_start = vector_start(y_length, *incy);

  for (i = 0; i < y_length; ++i)
    y[y_start + (ptrdiff_t)i * *incy] *= *beta;
  if (*alpha == 0.0)
    return;

  if (!transposed) {
    for (j = 0; j < *n; ++j) {
      double scaled = *alpha * x[x_start + (ptrdiff_t)j * *incx];
      for (i = 0; i < *m; ++i)
        y[y_start + (ptrdiff_t)i * *incy] += scaled * a[i + (ptrdiff_t)j * *lda];
    }
  } else {
    for (j = 0; j < *n; ++j) {
      double sum = 0.0;
      for (i = 0; i < *m; ++i)
        sum += a[i + (ptrdiff_t)j * *lda] *
          x[x_start + (ptrdiff_t)i * *incx];
      y[y_start + (ptrdiff_t)j * *incy] += *alpha * sum;
    }
  }
}

void dgemm_(const char *transa, const char *transb,
            const int *m, const int *n, const int *k,
            const double *alpha, const double *a, const int *lda,
            const double *b, const int *ldb, const double *beta,
            double *c, const int *ldc)
{
  int i;
  int j;
  int l;
  int transpose_a = !option_is(transa, 'N');
  int transpose_b = !option_is(transb, 'N');

  for (j = 0; j < *n; ++j) {
    for (i = 0; i < *m; ++i) {
      double sum = 0.0;
      for (l = 0; l < *k; ++l) {
        double av = transpose_a ? a[l + (ptrdiff_t)i * *lda]
                                : a[i + (ptrdiff_t)l * *lda];
        double bv = transpose_b ? b[j + (ptrdiff_t)l * *ldb]
                                : b[l + (ptrdiff_t)j * *ldb];
        sum += av * bv;
      }
      c[i + (ptrdiff_t)j * *ldc] =
        *alpha * sum + *beta * c[i + (ptrdiff_t)j * *ldc];
    }
  }
}

void dpotrf_(const char *uplo, const int *n, double *a,
             const int *lda, int *info)
{
  int i;
  int j;
  int k;
  int upper = option_is(uplo, 'U');

  *info = 0;
  if (!upper && !option_is(uplo, 'L')) { *info = -1; return; }
  if (*n < 0) { *info = -2; return; }
  if (*lda < (*n > 1 ? *n : 1)) { *info = -4; return; }

  if (upper) {
    for (j = 0; j < *n; ++j) {
      for (k = 0; k < j; ++k) {
        double value = a[k + (ptrdiff_t)j * *lda];
        for (i = 0; i < k; ++i)
          value -= a[i + (ptrdiff_t)k * *lda] *
                   a[i + (ptrdiff_t)j * *lda];
        a[k + (ptrdiff_t)j * *lda] = value / a[k + (ptrdiff_t)k * *lda];
      }
      {
        double diagonal = a[j + (ptrdiff_t)j * *lda];
        for (k = 0; k < j; ++k) {
          double value = a[k + (ptrdiff_t)j * *lda];
          diagonal -= value * value;
        }
        if (!(diagonal > 0.0)) { *info = j + 1; return; }
        a[j + (ptrdiff_t)j * *lda] = sqrt(diagonal);
      }
    }
  } else {
    for (j = 0; j < *n; ++j) {
      for (i = j; i < *n; ++i) {
        double value = a[i + (ptrdiff_t)j * *lda];
        for (k = 0; k < j; ++k)
          value -= a[i + (ptrdiff_t)k * *lda] *
                   a[j + (ptrdiff_t)k * *lda];
        if (i == j) {
          if (!(value > 0.0)) { *info = j + 1; return; }
          a[j + (ptrdiff_t)j * *lda] = sqrt(value);
        } else {
          a[i + (ptrdiff_t)j * *lda] = value / a[j + (ptrdiff_t)j * *lda];
        }
      }
    }
  }
}

void dpotrs_(const char *uplo, const int *n, const int *nrhs,
             const double *a, const int *lda, double *b,
             const int *ldb, int *info)
{
  int i;
  int j;
  int rhs;
  int upper = option_is(uplo, 'U');

  *info = 0;
  if (!upper && !option_is(uplo, 'L')) { *info = -1; return; }
  if (*n < 0) { *info = -2; return; }
  if (*nrhs < 0) { *info = -3; return; }
  if (*lda < (*n > 1 ? *n : 1)) { *info = -5; return; }
  if (*ldb < (*n > 1 ? *n : 1)) { *info = -7; return; }

  for (rhs = 0; rhs < *nrhs; ++rhs) {
    double *column = b + (ptrdiff_t)rhs * *ldb;
    if (upper) {
      for (i = 0; i < *n; ++i) {
        double value = column[i];
        for (j = 0; j < i; ++j)
          value -= a[j + (ptrdiff_t)i * *lda] * column[j];
        column[i] = value / a[i + (ptrdiff_t)i * *lda];
      }
      for (i = *n - 1; i >= 0; --i) {
        double value = column[i];
        for (j = i + 1; j < *n; ++j)
          value -= a[i + (ptrdiff_t)j * *lda] * column[j];
        column[i] = value / a[i + (ptrdiff_t)i * *lda];
      }
    } else {
      for (i = 0; i < *n; ++i) {
        double value = column[i];
        for (j = 0; j < i; ++j)
          value -= a[i + (ptrdiff_t)j * *lda] * column[j];
        column[i] = value / a[i + (ptrdiff_t)i * *lda];
      }
      for (i = *n - 1; i >= 0; --i) {
        double value = column[i];
        for (j = i + 1; j < *n; ++j)
          value -= a[j + (ptrdiff_t)i * *lda] * column[j];
        column[i] = value / a[i + (ptrdiff_t)i * *lda];
      }
    }
  }
}

void dtrtri_(const char *uplo, const char *diag, const int *n,
             double *a, const int *lda, int *info)
{
  int i;
  int j;
  int k;
  int upper = option_is(uplo, 'U');
  int unit = option_is(diag, 'U');
  double *original;
  double *solution;

  *info = 0;
  if (!upper && !option_is(uplo, 'L')) { *info = -1; return; }
  if (!unit && !option_is(diag, 'N')) { *info = -2; return; }
  if (*n < 0) { *info = -3; return; }
  if (*lda < (*n > 1 ? *n : 1)) { *info = -5; return; }
  if (!unit) {
    for (i = 0; i < *n; ++i) {
      if (a[i + (ptrdiff_t)i * *lda] == 0.0) {
        *info = i + 1;
        return;
      }
    }
  }

  original = (double *)malloc((size_t)*lda * (size_t)*n * sizeof(double));
  solution = (double *)malloc((size_t)*n * sizeof(double));
  if (original == NULL || solution == NULL) {
    free(original);
    free(solution);
    *info = -1000;
    return;
  }
  memcpy(original, a, (size_t)*lda * (size_t)*n * sizeof(double));

  for (j = 0; j < *n; ++j) {
    for (i = 0; i < *n; ++i)
      solution[i] = i == j ? 1.0 : 0.0;
    if (upper) {
      for (i = *n - 1; i >= 0; --i) {
        double value = solution[i];
        for (k = i + 1; k < *n; ++k)
          value -= original[i + (ptrdiff_t)k * *lda] * solution[k];
        solution[i] = unit ? value :
          value / original[i + (ptrdiff_t)i * *lda];
      }
      for (i = 0; i <= j; ++i)
        a[i + (ptrdiff_t)j * *lda] = solution[i];
    } else {
      for (i = 0; i < *n; ++i) {
        double value = solution[i];
        for (k = 0; k < i; ++k)
          value -= original[i + (ptrdiff_t)k * *lda] * solution[k];
        solution[i] = unit ? value :
          value / original[i + (ptrdiff_t)i * *lda];
      }
      for (i = j; i < *n; ++i)
        a[i + (ptrdiff_t)j * *lda] = solution[i];
    }
  }

  free(original);
  free(solution);
}
