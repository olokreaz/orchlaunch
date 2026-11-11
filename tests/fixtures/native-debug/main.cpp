#include <cstdio>

int main() {
    const int first = 20;
    const int second = 22;
    const int total = first + second;

    std::printf("native-debug fixture: %d\n", total);
    return total == 42 ? 0 : 1;
}
