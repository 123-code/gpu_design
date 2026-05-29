// THE KERNEL (test_kernel.asm)

// --- INITIALIZATION ---
MOV R1, #0      // Counter (i = 0)
MOV R2, #3      // Target loops (3)
MOV R3, #0      // Accumulator (This will hold the final answer)
MOV R4, #5      // The value to add each loop

// --- THE LOOP (Line 4) ---
ADD R3, R3, R4  // Accumulator = Accumulator + 5
ADD R1, R1, #1  // Counter = Counter + 1

// --- THE BRANCH CONDITION ---
CMP R1, R2      // Compare Counter to Target (Sets ALU flags)
BRn 4           // If Negative (Counter < Target), Branch back to Line 4

// --- FINISH ---
RET             // Halt the thread (Tells Scheduler we are DONE)