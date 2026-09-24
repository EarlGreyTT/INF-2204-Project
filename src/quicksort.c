// Sorts a large array of random ints with quicksort.
//
// usage: quicksort [length]    (default 100000000)
//
// Lengths and indices are size_t, so arrays longer than INT_MAX work.
// Recursing into the smaller partition and looping on the larger one keeps
// the stack depth below log2(n). A median-of-three pivot keeps sorted and
// reverse-sorted input O(n log n), and Hoare partitioning splits runs of
// equal keys evenly.

#include <ctype.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static void swap(int *a, int *b) {
	int t = *a;
	*a = *b;
	*b = t;
}

// Partitions a[0..n), n >= 2, around the median of its first, middle and
// last elements. Returns p, 0 < p < n, such that no element of a[0..p) is
// greater than any element of a[p..n).
static size_t partition(int *a, size_t n) {
	size_t mid = (n - 1) / 2;
	if (a[mid] < a[0])
		swap(&a[mid], &a[0]);
	if (a[n - 1] < a[0])
		swap(&a[n - 1], &a[0]);
	if (a[n - 1] < a[mid])
		swap(&a[n - 1], &a[mid]);
	int pivot = a[mid];

	size_t i = 0;
	size_t j = n - 1;
	for (;;) {
		while (a[i] < pivot)
			i++;
		while (a[j] > pivot)
			j--;
		if (i >= j)
			return j + 1;
		swap(&a[i], &a[j]);
		i++;
		j--;
	}
}

static void quicksort(int *a, size_t n) {
	while (n > 1) {
		size_t p = partition(a, n);
		if (p < n - p) {
			quicksort(a, p);
			a += p;
			n -= p;
		} else {
			quicksort(a + p, n - p);
			n = p;
		}
	}
}

static bool is_sorted(const int *a, size_t n) {
	for (size_t i = 1; i < n; i++)
		if (a[i - 1] > a[i])
			return false;
	return true;
}

// Parses a non-negative decimal integer that fits in size_t.
static bool parse_size(const char *s, size_t *n) {
	if (!isdigit((unsigned char)s[0]))
		return false;
	char *end;
	errno = 0;
	unsigned long long v = strtoull(s, &end, 10);
	if (errno != 0 || *end != '\0' || v > SIZE_MAX)
		return false;
	*n = (size_t)v;
	return true;
}

int main(int argc, char *argv[]) {
	size_t n = 100000000;
	if (argc > 2 || (argc == 2 && !parse_size(argv[1], &n))) {
		fprintf(stderr, "usage: %s [length]\n", argv[0]);
		return EXIT_FAILURE;
	}

	int *a = calloc(n, sizeof *a);
	if (a == NULL) {
		perror("calloc");
		return EXIT_FAILURE;
	}
	for (size_t i = 0; i < n; i++)
		a[i] = rand();

	clock_t start = clock();
	quicksort(a, n);
	double seconds = (double)(clock() - start) / CLOCKS_PER_SEC;

	if (!is_sorted(a, n)) {
		fputs("not sorted\n", stderr);
		free(a);
		return EXIT_FAILURE;
	}
	printf("sorted %zu elements in %.2f s\n", n, seconds);
	free(a);
	return EXIT_SUCCESS;
}
