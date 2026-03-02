
# Zero-RISCY PULP Architecture Toolchain
Zero-RISCY is the name of a small, efficient RISC-V core designed by the PULP project, optimized for minimal area and power in RV32 implementations.       
**REFER** :- [Toolchain](https://github.com/pulp-platform/pulp-riscv-gnu-toolchain)

-------------------------------------------------
### **STEP-1** : Update Ubuntu (important)    
      
    sudo apt update && sudo apt upgrade -y 
      

### **STEP-2** : Install required dependencies (VERY IMPORTANT)     
The toolchain will fail if even one dependency is missing.   
          
    sudo apt install -y \
    autoconf \
    automake \
    autotools-dev \
    curl \
    python3 \
    python3-pip \
    libmpc-dev \
    libmpfr-dev \
    libgmp-dev \
    gawk \
    build-essential \
    bison \
    flex \
    texinfo \
    gperf \
    libtool \
    patchutils \
    bc \
    zlib1g-dev \
    libexpat-dev \
    ninja-build \
    git \
    cmake

### **STEP-3** : Create a workspace directory    
        
    mkdir RISC_V      
    cd RISC_V

### **STEP-4** : Clone PULP RISC-V GNU toolchain  
            
    git clone https://github.com/pulp-platform/pulp-riscv-gnu-toolchain.git  

    cd pulp-riscv-gnu-toolchain

### **STEP-5** : Configure for Zero-RISCY      
       
    ./configure \
    --prefix=$HOME/tools/pulp-riscv \
    --with-arch=rv32imc \
    --with-abi=ilp32

***--prefix*** -> where toolchain will be installed     
***rv32imc*** -> Zero-RISCY ISA     
***ilp32*** -> 32-bit ABI (Application Binary Interface)    
***ABI*** decides how binary code behaves, not how source code looks.    
***ISA*** : Instructions CPU supports.   
***ABI*** : How software uses CPU.   

### **STEP-6** : Build the toolchain (long step)     
        
    make -j$(nproc)
        
  
-----------------------------------------------------
## Optional : If it shows Error 127
1. Check if submodule directory exists                 

       ls riscv-binutils-gdb
   
3. Check .gitmodules (sanity check)

       cat .gitmodules
   
5. FORCE submodules to download (this is the key)     

       git submodule sync
       git submodule update --init --recursive --force

6. VERIFY submodule is now populated (VERY IMPORTANT)

       ls riscv-binutils-gdb

It will show like this : 
<img width="1109" height="235" alt="image" src="https://github.com/user-attachments/assets/63b61cdd-3693-4e20-a3e9-485c35a69883" />

7. Clean previous failed build (mandatory)

       rm -rf build-* stamps

8. Re-configure (fresh)

       ./configure \
       --prefix=$HOME/tools/pulp-riscv \
       --with-arch=rv32imc \
       --with-abi=ilp32


9. Build again

       make -j$(nproc)
-------------------------------------------------------------
### **STEP-7** : Add toolchain to PATH    
          
    nano ~/.bashrc   
    export PATH=$HOME/tools/pulp-riscv/bin:$PATH  

CTRL + O -> Enter -> CTRL + X     

    source ~/.bashrc

### **STEP-8** : Verify installation    
            
    riscv32-unknown-elf-gcc --version

It will show as :
            
    riscv32-unknown-elf-gcc (GCC) 7.1.1 20170509
    Copyright (C) 2017 Free Software Foundation, Inc.
    This is free software; see the source for copying conditions.  There is NO
    warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

----------------------------------------------------------------------------------------------------------------------

# Compile your FIRST program (Zero-RISCY)

------------------------------------------------------------------------------------------------------------------------   
### **STEP-1** : Create a test file     
    mkdir tests     
    cd tests    
    nano add.c

### **STEP-2** : Simple Program     
    int main() 
    {   
    volatile int x = 10;    
    volatile int y = 20;  
    volatile int z = x + y;   
    while (1); 
    }      

### **STEP-3** : create build directory for .elf file

    mkdir -p build
    
### **STEP-4** : Compile for Zero-RISCY     
    riscv32-unknown-elf-gcc \
    -march=rv32imc \
    -mabi=ilp32 \
    -nostdlib \
    -T linker.ld \
     add.c \
    -o build/add.elf

| Flag            | Reason               |
|-----------------|----------------------|
| `rv32imc`       | Zero-RISCY ISA       |
| `ilp32`         | 32-bit ABI           |
| `-nostdlib`     | Bare-metal           |
| `-ffreestanding`| No OS                |
| `-O0`           | Readable assembly    |

***Bare-metal*** = **your program runs directly on the CPU hardware, with NO operating system.**

### **STEP-5** : Inspect ELF     
    riscv32-unknown-elf-objdump -d build/add.elf    
Results :  Assembly language  
<img width="926" height="308" alt="image" src="https://github.com/user-attachments/assets/dab874d9-755d-4757-bfe4-70b0674f7efc" />

    riscv32-unknown-elf-nm build/add.elf
Results : Address
<img width="922" height="195" alt="image" src="https://github.com/user-attachments/assets/f928672b-c4e1-4005-b16c-711ef638d3da" />

***ELF*** = **Executable and Linkable Format**     
This is the file format that quietly connects : C code  ->  compiler  ->  linker  ->  RTL  -> silicon.     
An ELF file is a container that holds:
- your compiled machine code
- Data
- Addresses
- Symbols
- debug info
  
### Verifying Zero Riscy implemantation
1. create a file

       nano fpu.c
   
write the code for floating point 

      void test_fpu() 
      {
           asm volatile ("fadd.s f0, f0, f0");
      }

Zero riscy doesn't support floating point implementation.   
It will shows error as :                                    
<img width="819" height="227" alt="image" src="https://github.com/user-attachments/assets/9fdb24e7-6bf2-496f-85db-62bbd217e4bc" />  

------------------------------------------------------------------------------------------------------------------------------------

# Setup PULPino

-----------------------------------------------------------------------------------------------------------------------------------
**REFER** :- [PULPino](https://github.com/pulp-platform/pulpino)
### 1. Update WSl
Open PowerShell

    wsl --update
    wsl --version

It should be :      
<img width="876" height="259" alt="image" src="https://github.com/user-attachments/assets/d57b71fa-6c7d-4ded-a54a-3920d6d9c268" />

### 2. Install & Compile Python2
Open Ubuntu 

**Install build dependencies**

    sudo apt update
    sudo apt install build-essential zlib1g-dev libssl-dev \
    libbz2-dev libreadline-dev libsqlite3-dev curl llvm \
    libncurses5-dev libncursesw5-dev xz-utils tk-dev \
    libffi-dev liblzma-dev

**Download Python 2.7.18**          
The PULpino setup requires python2 >= 2.6        

    wget https://www.python.org/ftp/python/2.7.18/Python-2.7.18.tgz    
    tar -xvf Python-2.7.18.tgz   
    cd Python-2.7.18    
    ./configure --prefix=$HOME/python2 --enable-optimizations   
    make -j$(nproc)      
    make install

Verify the installation :

    ~/python2.7.18/bin/python2.7 --version

<img width="725" height="65" alt="image" src="https://github.com/user-attachments/assets/904144ff-1964-4811-b795-fe0cef9279a9" /> 

### 3. Python Virtual Enviroment Setup
Install pip for Python2

    curl https://bootstrap.pypa.io/pip/2.7/get-pip.py -o get-pip.py
    ~/python2.7.18/bin/python2.7 get-pip.py
     
IF it shows error:    
`ERROR: Could not find a version that satisfies the requirement wheel (from versions: none)   
ERROR: No matching distribution found for wheel`

    ~/python2.7.18/bin/python2.7 ~/Python-2.7.18/get-pip.py "pip<21.0" "setuptools<45" --no-cache-dir  

verify 

    ~/python2.7.18/bin/python2.7 -m pip --version

<img width="1352" height="487" alt="image" src="https://github.com/user-attachments/assets/2ee71041-758c-44e5-a855-329a53f3bc2c" />
