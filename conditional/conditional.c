int main()
{
	volatile int a = 5;
	volatile int b = 10;
	if(a<b)
		a = b;
while(1);
}
