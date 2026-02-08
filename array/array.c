int main() {
    volatile int arr[3] = {1, 2, 3};
    volatile int x = arr[1];
    while (1);
}

