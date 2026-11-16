#include <cstdio>

// Sums 1..n. The debugger breakpoint lives on the first line of this function.
int work(int n) {
    int sum = 0;
    for (int i = 1; i <= n; ++i) {
        sum += i;
    }
    return sum;
}

int main() {
    const int first = 20;
    const int total = work(first);

    std::printf("start\n");
    std::printf("result=%d\n", total);
    return total == 210 ? 0 : 1;
}
