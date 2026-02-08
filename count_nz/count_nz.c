int main() {
    volatile int matrix[3][3];
    volatile int count = 0;

    matrix[0][0] = 0; matrix[0][1] = 0; matrix[0][2] = 5;
    matrix[1][0] = 0; matrix[1][1] = 0; matrix[1][2] = 0;
    matrix[2][0] = 3; matrix[2][1] = 0; matrix[2][2] = 0;

    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
            if (matrix[i][j] != 0) {
                count++;
            }
        }
    }

    while (1);
}


