int add(int a, int b) {
    return a + b;
}

int main() {
    volatile int r = add(3, 4);
    while (1);
}

