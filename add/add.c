volatile int a = 10;
volatile int b = 20;
volatile int c;

int main() {
    c = a + b;
    while (1);
}
