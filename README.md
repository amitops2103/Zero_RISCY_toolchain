
# Zero-RISCY PULP Architecture Toolchain
Zero-RISCY is the name of a small, efficient RISC-V core designed by the PULP project, optimized for minimal area and power in RV32 implementations.   

To build code or software for such a core, you generally need a RISC-V cross-compiler toolchain (e.g., GCC targeting riscv32-unknown-elf). The repo guides how to build exactly that with the ISA extensions used by Zero-RISCY.    

## **STEP-1** : Update Ubuntu (important)    
      
        sudo apt update && sudo apt upgrade -y 
      

## **STEP-2** : Install required dependencies (VERY IMPORTANT)     
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

## **STEP-3** : Create a workspace directory    
        
        /home/amitvlsi01/RISC_V

## **STEP-4** : Clone PULP RISC-V GNU toolchain  
            
        git clone https://github.com/pulp-platform/pulp-riscv-gnu-toolchain.git  

        cd pulp-riscv-gnu-toolchain

## **STEP-5** : Configure for Zero-RISCY      
       
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

## **STEP-6** : Build the toolchain (long step)     
        
        make -j$(nproc)
        
20–45 minutes (depends on PC). Laptop should have good cooling system (any cooling pad can be used).     

## **STEP-7** : Add toolchain to PATH    
          
           nano ~/.bashrc   
           export PATH=$HOME/tools/pulp-riscv/bin:$PATH  
CTRL + O -> Enter -> CTRL + X     

          source ~/.bashrc

## **STEP-8** : Verify installation    
            
            riscv32-unknown-elf-gcc --version

            
``Result : -> riscv32-unknown-elf-gcc (GCC) 10.x.x``

----------------------------------------------------------------------------------------------------------------------
