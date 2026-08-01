/*
 * Glue layer between Lean and CSDP's easy_sdp interface.
 *
 * The Lean side passes problem data as flat sparse triplet arrays. This
 * file translates them into CSDP's native blockmatrix / constraintmatrix
 * representation (1-indexed, with index 0 unused), invokes easy_sdp, and
 * copies the solution back into flat output buffers.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#  include <io.h>
#  include <fcntl.h>
#  define csdp_dup       _dup
#  define csdp_dup2      _dup2
#  define csdp_close     _close
#  define csdp_open      _open
#  define CSDP_O_WRONLY  _O_WRONLY
#  define CSDP_DEVNULL   "NUL"
#else
#  include <unistd.h>
#  include <fcntl.h>
#  define csdp_dup       dup
#  define csdp_dup2      dup2
#  define csdp_close     close
#  define csdp_open      open
#  define CSDP_O_WRONLY  O_WRONLY
#  define CSDP_DEVNULL   "/dev/null"
#endif

/* declarations.h transitively includes blockmat.h. */
#include "declarations.h"
#include "lean_csdp.h"

/*
 * CSDP's `easy_sdp` (and the underlying `sdp` solver) unconditionally
 * print solver banners, iteration logs, objective values, and DIMACS
 * error measures to stdout/stderr. That noise is harmful in two ways:
 *
 *   1. It clutters consumer programs (e.g. `lake test`).
 *   2. When invoked from inside a Lean language-server elaboration step
 *      (e.g. a tactic call evaluated by VSCode's Lean extension), the
 *      stray writes corrupt the LSP JSON-RPC channel on stdout and can
 *      stall the editor.
 *
 * This helper redirects fds 1 and 2 to /dev/null around a block of
 * code, restoring them afterwards. POSIX and Windows both support the
 * dup/dup2/open primitives we use.
 */
typedef struct {
  int saved_stdout;
  int saved_stderr;
  int devnull;
} silenced_io_t;

static void silence_stdio_begin(silenced_io_t *s) {
  s->saved_stdout = -1;
  s->saved_stderr = -1;
  s->devnull = -1;
  fflush(stdout);
  fflush(stderr);
  s->devnull = csdp_open(CSDP_DEVNULL, CSDP_O_WRONLY);
  if (s->devnull < 0) return;
  s->saved_stdout = csdp_dup(1);
  s->saved_stderr = csdp_dup(2);
  csdp_dup2(s->devnull, 1);
  csdp_dup2(s->devnull, 2);
}

static void silence_stdio_end(silenced_io_t *s) {
  fflush(stdout);
  fflush(stderr);
  if (s->saved_stdout >= 0) {
    csdp_dup2(s->saved_stdout, 1);
    csdp_close(s->saved_stdout);
  }
  if (s->saved_stderr >= 0) {
    csdp_dup2(s->saved_stderr, 2);
    csdp_close(s->saved_stderr);
  }
  if (s->devnull >= 0) csdp_close(s->devnull);
}

static int abs_int(int x) { return x < 0 ? -x : x; }

long lean_csdp_blockmatrix_size(int nblocks, const int *block_sizes) {
  long total = 0;
  for (int i = 0; i < nblocks; ++i) {
    int s = block_sizes[i];
    if (s >= 0) {
      total += (long)s * (long)s;
    } else {
      total += (long)(-s);
    }
  }
  return total;
}

int lean_csdp_total_dim(int nblocks, const int *block_sizes) {
  int total = 0;
  for (int i = 0; i < nblocks; ++i) total += abs_int(block_sizes[i]);
  return total;
}

/* Allocate a CSDP blockmatrix laid out from block_sizes, zero-filled. */
static int alloc_blockmatrix(struct blockmatrix *M, int nblocks,
                             const int *block_sizes) {
  M->nblocks = nblocks;
  M->blocks = (struct blockrec *)calloc(nblocks + 1, sizeof(struct blockrec));
  if (M->blocks == NULL) return 1;
  for (int b = 1; b <= nblocks; ++b) {
    int s = block_sizes[b - 1];
    if (s >= 0) {
      M->blocks[b].blockcategory = MATRIX;
      M->blocks[b].blocksize = s;
      M->blocks[b].data.mat = (double *)calloc((size_t)s * s, sizeof(double));
      if (s > 0 && M->blocks[b].data.mat == NULL) return 1;
    } else {
      int as = -s;
      M->blocks[b].blockcategory = DIAG;
      M->blocks[b].blocksize = as;
      /* DIAG blocks use 1-indexed vec, so allocate as+1 entries. */
      M->blocks[b].data.vec = (double *)calloc((size_t)as + 1, sizeof(double));
      if (M->blocks[b].data.vec == NULL) return 1;
    }
  }
  return 0;
}

static void free_blockmatrix(struct blockmatrix *M) {
  if (M->blocks == NULL) return;
  for (int b = 1; b <= M->nblocks; ++b) {
    if (M->blocks[b].blockcategory == MATRIX) {
      free(M->blocks[b].data.mat);
    } else if (M->blocks[b].blockcategory == DIAG) {
      free(M->blocks[b].data.vec);
    }
  }
  free(M->blocks);
  M->blocks = NULL;
}

/* Write `value` into block `bnum` (1-indexed) of M at (i,j) (1-indexed).
 * For MATRIX blocks, we set both (i,j) and (j,i) for symmetry. */
static void blockmatrix_set(struct blockmatrix *M, int bnum, int i, int j,
                            double value) {
  struct blockrec *blk = &M->blocks[bnum];
  if (blk->blockcategory == MATRIX) {
    int n = blk->blocksize;
    blk->data.mat[(j - 1) * n + (i - 1)] = value;
    if (i != j) blk->data.mat[(i - 1) * n + (j - 1)] = value;
  } else { /* DIAG */
    /* CSDP diagonal blocks: i==j must hold; data.vec is 1-indexed. */
    blk->data.vec[i] = value;
  }
}

/* Count nonzeros per (constraint, block) pair. constraints are 1..k,
 * blocks are 1..nblocks. Output `counts` is row-major: counts[(c-1)*nblocks + (b-1)]. */
static void count_per_block(int a_nnz, const int *a_constraints,
                            const int *a_blocks, int nblocks,
                            size_t pair_count, int *counts) {
  memset(counts, 0, sizeof(int) * pair_count);
  for (int t = 0; t < a_nnz; ++t) {
    int c = a_constraints[t];
    int b = a_blocks[t];
    counts[(c - 1) * nblocks + (b - 1)]++;
  }
}

static void free_constraints(struct constraintmatrix *constraints, int k) {
  if (constraints == NULL) return;
  for (int c = 1; c <= k; ++c) {
    struct sparseblock *p = constraints[c].blocks;
    while (p != NULL) {
      struct sparseblock *next = p->next;
      free(p->entries);
      free(p->iindices);
      free(p->jindices);
      free(p);
      p = next;
    }
  }
  free(constraints);
}

static int build_constraints(struct constraintmatrix **out,
                             int num_constraints, int nblocks,
                             const int *block_sizes, int a_nnz,
                             const int *a_constraints, const int *a_blocks,
                             const int *a_i, const int *a_j,
                             const double *a_vals) {
  size_t pair_count = 0;
  if (num_constraints < 0 || nblocks < 0 || a_nnz < 0) return 1;
  if (num_constraints > 0 && nblocks > 0) {
    size_t constraints_size = (size_t)num_constraints;
    size_t blocks_size = (size_t)nblocks;
    size_t max_element_size =
        sizeof(struct sparseblock *) > sizeof(int)
            ? sizeof(struct sparseblock *)
            : sizeof(int);
    if (constraints_size > SIZE_MAX / blocks_size) return 1;
    pair_count = constraints_size * blocks_size;
    if (pair_count > (size_t)PTRDIFF_MAX / max_element_size) return 1;
  }

  struct constraintmatrix *cs = (struct constraintmatrix *)calloc(
      (size_t)num_constraints + 1, sizeof(struct constraintmatrix));
  if (cs == NULL) return 1;

  /* Per-(constraint, block) nnz counts to size each sparseblock. */
  int *counts = NULL;
  if (pair_count > 0) {
    counts = (int *)calloc(pair_count, sizeof(int));
    if (counts == NULL) {
      free(cs);
      return 1;
    }
    count_per_block(a_nnz, a_constraints, a_blocks, nblocks, pair_count,
                    counts);
  }

  /* Allocate one sparseblock per nonempty (c, b) pair, link into list. */
  /* We index per-constraint block pointers so we can append in O(1). */
  struct sparseblock **block_ptrs = pair_count == 0 ? NULL :
      (struct sparseblock **)calloc(pair_count, sizeof(struct sparseblock *));
  if (pair_count > 0 && block_ptrs == NULL) {
    free(counts);
    free_constraints(cs, num_constraints);
    return 1;
  }
  int *fill = pair_count == 0 ? NULL : (int *)calloc(pair_count, sizeof(int));
  if (pair_count > 0 && fill == NULL) {
    free(counts);
    free(block_ptrs);
    free_constraints(cs, num_constraints);
    return 1;
  }

  for (int c = 1; c <= num_constraints; ++c) {
    for (int b = 1; b <= nblocks; ++b) {
      int n = counts[(c - 1) * nblocks + (b - 1)];
      if (n == 0) continue;
      struct sparseblock *blk =
          (struct sparseblock *)calloc(1, sizeof(struct sparseblock));
      if (blk == NULL) goto oom;
      blk->blocknum = b;
      blk->blocksize = abs_int(block_sizes[b - 1]);
      blk->constraintnum = c;
      blk->numentries = n;
      /* CSDP uses 1-indexed entries/iindices/jindices arrays. */
      blk->entries = (double *)calloc((size_t)n + 1, sizeof(double));
      blk->iindices = (int *)calloc((size_t)n + 1, sizeof(int));
      blk->jindices = (int *)calloc((size_t)n + 1, sizeof(int));
      if (blk->entries == NULL || blk->iindices == NULL ||
          blk->jindices == NULL) {
        free(blk->entries);
        free(blk->iindices);
        free(blk->jindices);
        free(blk);
        goto oom;
      }
      blk->next = cs[c].blocks;
      cs[c].blocks = blk;
      block_ptrs[(c - 1) * nblocks + (b - 1)] = blk;
    }
  }

  /* Now scatter the triplet entries into the appropriate sparseblock. */
  for (int t = 0; t < a_nnz; ++t) {
    int c = a_constraints[t];
    int b = a_blocks[t];
    struct sparseblock *blk = block_ptrs[(c - 1) * nblocks + (b - 1)];
    int idx = ++fill[(c - 1) * nblocks + (b - 1)];
    blk->iindices[idx] = a_i[t];
    blk->jindices[idx] = a_j[t];
    blk->entries[idx] = a_vals[t];
  }

  free(counts);
  free(block_ptrs);
  free(fill);
  *out = cs;
  return 0;

oom:
  free(counts);
  free(block_ptrs);
  free(fill);
  free_constraints(cs, num_constraints);
  return 1;
}

/* Copy a CSDP blockmatrix into a flat output buffer. SDP blocks are written
 * column-major as size*size doubles; diagonal blocks as size doubles. */
static void blockmatrix_to_flat(const struct blockmatrix *M, double *out) {
  long off = 0;
  for (int b = 1; b <= M->nblocks; ++b) {
    const struct blockrec *blk = &M->blocks[b];
    int s = blk->blocksize;
    if (blk->blockcategory == MATRIX) {
      memcpy(out + off, blk->data.mat, (size_t)s * (size_t)s * sizeof(double));
      off += (long)s * (long)s;
    } else {
      /* CSDP DIAG vec is 1-indexed: entries 1..s. */
      for (int i = 1; i <= s; ++i) out[off + i - 1] = blk->data.vec[i];
      off += s;
    }
  }
}

int lean_csdp_solve(int nblocks, const int *block_sizes, int num_constraints,
                    const double *b, int c_nnz, const int *c_blocks,
                    const int *c_i, const int *c_j, const double *c_vals,
                    int a_nnz, const int *a_constraints, const int *a_blocks,
                    const int *a_i, const int *a_j, const double *a_vals,
                    double constant_offset, double *pobj_out, double *dobj_out,
                    double *X_out, double *y_out, double *Z_out) {
  struct blockmatrix C, X, Z;
  struct constraintmatrix *constraints = NULL;
  double *a_csdp = NULL;
  double *y_csdp = NULL;
  int n = lean_csdp_total_dim(nblocks, block_sizes);
  int ret;

  memset(&C, 0, sizeof(C));
  memset(&X, 0, sizeof(X));
  memset(&Z, 0, sizeof(Z));

  if (alloc_blockmatrix(&C, nblocks, block_sizes) != 0) {
    ret = -1;
    goto cleanup;
  }
  for (int t = 0; t < c_nnz; ++t) {
    blockmatrix_set(&C, c_blocks[t], c_i[t], c_j[t], c_vals[t]);
  }

  /* CSDP wants a 1-indexed RHS array. */
  a_csdp = (double *)malloc(((size_t)num_constraints + 1) * sizeof(double));
  if (a_csdp == NULL) {
    ret = -1;
    goto cleanup;
  }
  for (int i = 0; i < num_constraints; ++i) a_csdp[i + 1] = b[i];

  if (build_constraints(&constraints, num_constraints, nblocks, block_sizes,
                        a_nnz, a_constraints, a_blocks, a_i, a_j, a_vals) != 0) {
    ret = -1;
    goto cleanup;
  }

  /* Allocate an initial X, Z, y. CSDP provides initsoln() for this. */
  initsoln(n, num_constraints, C, a_csdp, constraints, &X, &y_csdp, &Z);

  {
    silenced_io_t s;
    silence_stdio_begin(&s);
    ret = easy_sdp(n, num_constraints, C, a_csdp, constraints, constant_offset,
                   &X, &y_csdp, &Z, pobj_out, dobj_out);
    silence_stdio_end(&s);
  }

  blockmatrix_to_flat(&X, X_out);
  blockmatrix_to_flat(&Z, Z_out);
  for (int i = 0; i < num_constraints; ++i) y_out[i] = y_csdp[i + 1];

  free_blockmatrix(&X);
  free_blockmatrix(&Z);
  free(y_csdp);
  y_csdp = NULL;

cleanup:
  free_blockmatrix(&C);
  free(a_csdp);
  free_constraints(constraints, num_constraints);
  return ret;
}
