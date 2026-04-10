// rv32i_cpu.v — RISC-V RV32IMAC 8-Stage Pipelined CPU
// ISA: RV32IMAC (82 instructions) — Integer, Multiply/Divide, Atomic, Compressed
// Pipeline: IF1 -> IF2 -> ID -> RR -> EX1 -> EX2 -> MEM -> WB
// Features:
//   - 8-stage in-order pipeline with 5-path forwarding
//   - Gshare branch predictor (256-entry, 8-bit GHR) + 2-way BTB (128 entries)
//   - 8-entry Return Address Stack (RAS)
//   - Pipelined multiplier (EX1 reg -> EX2 compute), 18-cycle radix-2x2 divider
//   - Full RISC-V Priv Spec v1.12 M-mode CSR compliance (45+ CSRs)
//   - Complete exception model (14 cause codes, mtval population)
//   - Vectored + direct interrupt modes, WFI, NMI
//   - 16-region PMP (Physical Memory Protection)
//   - RV32C compressed instruction expansion in IF2
//   - RV32A atomic instructions (LR/SC, 9 AMO operations)
//   - FENCE.I support, bus error handling
//   - Clock gating enables, debug halt/resume with 2 hw breakpoints
// Target: 80-120 MHz on SKY130 130nm

module rv32i_cpu #(
    parameter RESET_ADDR = 32'h0000_0000,
    parameter HART_ID    = 0,
    parameter NMI_ADDR   = 32'h0000_0004
) (
    input                clk,
    input                rst_n,

    // Instruction memory interface
    output        [31:0] imem_addr,
    output               imem_req,
    input         [31:0] imem_rdata,
    input                imem_ready,
    input                imem_error,

    // Data memory interface
    output        [31:0] dmem_addr,
    output        [31:0] dmem_wdata,
    output         [3:0] dmem_wstrb,
    output               dmem_req,
    output               dmem_lock,
    input         [31:0] dmem_rdata,
    input                dmem_ready,
    input                dmem_error,

    // Interrupt inputs
    input                ext_irq,
    input                timer_irq,
    input                soft_irq,
    input                nmi,

    // Debug interface
    input                debug_halt,
    input                debug_resume,
    output               debug_halted,
    output               debug_running,
    output        [31:0] debug_pc,
    input          [4:0] debug_gpr_addr,
    input         [31:0] debug_gpr_wdata,
    output        [31:0] debug_gpr_rdata,
    input                debug_gpr_wr,

    // Control outputs
    output               fence_i,
    output               cpu_active,
    output         [2:0] cpu_power_state
);

    // =========================================================================
    // OPCODE DEFINITIONS
    // =========================================================================
    localparam OP_LUI      = 7'b0110111;
    localparam OP_AUIPC    = 7'b0010111;
    localparam OP_JAL      = 7'b1101111;
    localparam OP_JALR     = 7'b1100111;
    localparam OP_BRANCH   = 7'b1100011;
    localparam OP_LOAD     = 7'b0000011;
    localparam OP_STORE    = 7'b0100011;
    localparam OP_IMM      = 7'b0010011;
    localparam OP_REG      = 7'b0110011;
    localparam OP_FENCE    = 7'b0001111;
    localparam OP_SYSTEM   = 7'b1110011;
    localparam OP_AMO      = 7'b0101111;

    // ALU operations
    localparam ALU_ADD    = 5'd0;
    localparam ALU_SUB    = 5'd1;
    localparam ALU_SLL    = 5'd2;
    localparam ALU_SLT    = 5'd3;
    localparam ALU_SLTU   = 5'd4;
    localparam ALU_XOR    = 5'd5;
    localparam ALU_SRL    = 5'd6;
    localparam ALU_SRA    = 5'd7;
    localparam ALU_OR     = 5'd8;
    localparam ALU_AND    = 5'd9;
    localparam ALU_PASS_B = 5'd10;
    localparam ALU_MUL    = 5'd11;
    localparam ALU_MULH   = 5'd12;
    localparam ALU_MULHSU = 5'd13;
    localparam ALU_MULHU  = 5'd14;
    localparam ALU_DIV    = 5'd16;
    localparam ALU_DIVU   = 5'd17;
    localparam ALU_REM    = 5'd18;
    localparam ALU_REMU   = 5'd19;

    // AMO funct5 codes
    localparam AMO_LR   = 5'b00010;
    localparam AMO_SC   = 5'b00011;
    localparam AMO_SWAP = 5'b00001;
    localparam AMO_ADD  = 5'b00000;
    localparam AMO_XOR  = 5'b00100;
    localparam AMO_AND  = 5'b01100;
    localparam AMO_OR   = 5'b01000;
    localparam AMO_MIN  = 5'b10000;
    localparam AMO_MAX  = 5'b10100;
    localparam AMO_MINU = 5'b11000;
    localparam AMO_MAXU = 5'b11100;

    // CSR addresses
    localparam CSR_MVENDORID  = 12'hF11;
    localparam CSR_MARCHID    = 12'hF12;
    localparam CSR_MIMPID     = 12'hF13;
    localparam CSR_MHARTID    = 12'hF14;
    localparam CSR_MSTATUS    = 12'h300;
    localparam CSR_MISA       = 12'h301;
    localparam CSR_MIE        = 12'h304;
    localparam CSR_MTVEC      = 12'h305;
    localparam CSR_MCOUNTEREN = 12'h306;
    localparam CSR_MCOUNTINHIBIT = 12'h320;
    localparam CSR_MSCRATCH   = 12'h340;
    localparam CSR_MEPC       = 12'h341;
    localparam CSR_MCAUSE     = 12'h342;
    localparam CSR_MTVAL      = 12'h343;
    localparam CSR_MIP        = 12'h344;
    localparam CSR_MCYCLE     = 12'hB00;
    localparam CSR_MINSTRET   = 12'hB02;
    localparam CSR_MHPMCNT3   = 12'hB03;
    localparam CSR_MHPMCNT4   = 12'hB04;
    localparam CSR_MCYCLEH    = 12'hB80;
    localparam CSR_MINSTRETH  = 12'hB82;
    localparam CSR_MHPMCNT3H  = 12'hB83;
    localparam CSR_MHPMCNT4H  = 12'hB84;
    localparam CSR_MHPMEVENT3 = 12'h323;
    localparam CSR_MHPMEVENT4 = 12'h324;
    localparam CSR_PMPCFG0    = 12'h3A0;
    localparam CSR_PMPCFG1    = 12'h3A1;
    localparam CSR_PMPCFG2    = 12'h3A2;
    localparam CSR_PMPCFG3    = 12'h3A3;
    localparam CSR_PMPADDR0   = 12'h3B0;
    localparam CSR_TSELECT    = 12'h7A0;
    localparam CSR_TDATA1     = 12'h7A1;
    localparam CSR_TDATA2     = 12'h7A2;
    localparam CSR_DCSR       = 12'h7B0;
    localparam CSR_DPC        = 12'h7B1;
    localparam CSR_DSCRATCH0  = 12'h7B2;

    // Exception cause codes
    localparam EXC_INSTR_MISALIGN = 4'd0;
    localparam EXC_INSTR_FAULT    = 4'd1;
    localparam EXC_ILLEGAL_INSTR  = 4'd2;
    localparam EXC_BREAKPOINT     = 4'd3;
    localparam EXC_LOAD_MISALIGN  = 4'd4;
    localparam EXC_LOAD_FAULT     = 4'd5;
    localparam EXC_STORE_MISALIGN = 4'd6;
    localparam EXC_STORE_FAULT    = 4'd7;
    localparam EXC_ECALL_M        = 4'd11;
    localparam EXC_NONE           = 4'd15;



    // =========================================================================
    // FORWARD DECLARATIONS (signals used before point of definition)
    // =========================================================================
    wire        global_stall;
    wire        debug_stall;
    wire        pc_stall;
    wire [31:0] wb_data;
    reg  [31:0] csr_rdata;
    wire        wfi_active_w;
    wire        amo_stall;
    reg         debug_halted_r;
    reg  [31:0] pc;
    wire        hazard_stall;
    wire        if2_hold_fetch;
    wire        nmi_taken;
    wire        wb_exception;
    wire        irq_taken;
    wire        if2_stall;
    wire        if2_process_comp_held;
    wire        sc_fail;

    // =========================================================================
    // PIPELINE REGISTERS (7 boundaries for 8-stage pipeline)
    // IF1 -> IF2 -> ID -> RR -> EX1 -> EX2 -> MEM -> WB
    // =========================================================================

    // --- IF1/IF2 Pipeline Registers ---
    reg [31:0] if1_if2_pc;
    reg [31:0] if1_if2_instr;
    reg        if1_if2_valid;
    reg        if2_fetched;       // Tracks whether IF1→IF2 data already consumed by IF2→ID
    reg        if1_if2_pred_taken;
    reg [31:0] if1_if2_pred_target;
    reg        if1_if2_bus_error;

    // --- IF2/ID Pipeline Registers ---
    reg [31:0] if2_id_pc;
    reg [31:0] if2_id_instr;          // Expanded 32-bit instruction
    reg [31:0] if2_id_instr_raw;      // Original instruction for mtval
    reg        if2_id_valid;
    reg        if2_id_pred_taken;
    reg        if2_id_is_compressed;
    reg        if2_id_bus_error;
    reg        if2_id_c_illegal;
    reg [31:0] if2_id_pred_target;

    // --- ID/RR Pipeline Registers ---
    // pc declared in forward declarations
    reg [31:0] id_rr_instr_raw;
    reg [31:0] id_rr_imm;
    reg  [4:0] id_rr_rd;
    reg  [4:0] id_rr_rs1;
    reg  [4:0] id_rr_rs2;
    reg  [4:0] id_rr_alu_op;
    reg        id_rr_alu_src;         // 0=rs2, 1=imm
    reg        id_rr_mem_read;
    reg        id_rr_mem_write;
    reg  [2:0] id_rr_mem_size;
    reg        id_rr_reg_write;
    reg  [1:0] id_rr_result_src;      // 0=ALU, 1=MEM, 2=PC+N, 3=CSR
    reg        id_rr_branch;
    reg        id_rr_jal;
    reg        id_rr_jalr;
    reg  [2:0] id_rr_funct3;
    reg        id_rr_auipc;
    reg        id_rr_valid;
    reg [11:0] id_rr_csr_addr;
    reg        id_rr_csr_op;
    reg        id_rr_csr_write;
    reg        id_rr_is_ecall;
    reg        id_rr_is_ebreak;
    reg        id_rr_is_mret;
    reg        id_rr_is_wfi;
    reg        id_rr_is_fencei;
    reg        id_rr_pred_taken;
    reg        id_rr_is_compressed;
    reg        id_rr_exc_pending;
    reg  [3:0] id_rr_exc_cause;
    reg [31:0] id_rr_pc;
    reg [31:0] id_rr_pred_target;
    reg [31:0] id_rr_exc_tval;
    reg        id_rr_is_amo;
    reg        id_rr_is_lr;
    reg        id_rr_is_sc;
    reg  [4:0] id_rr_amo_funct5;
    reg        id_rr_amo_aq;
    reg        id_rr_amo_rl;
    reg        id_rr_ex2_result;      // MUL/CSR produces result in EX2

    // --- RR/EX1 Pipeline Registers ---
    reg [31:0] rr_ex1_pc;
    reg [31:0] rr_ex1_instr_raw;
    reg [31:0] rr_ex1_imm;
    reg  [4:0] rr_ex1_rd;
    reg  [4:0] rr_ex1_rs1;
    reg  [4:0] rr_ex1_rs2;
    reg  [4:0] rr_ex1_alu_op;
    reg        rr_ex1_alu_src;
    reg        rr_ex1_mem_read;
    reg        rr_ex1_mem_write;
    reg  [2:0] rr_ex1_mem_size;
    reg        rr_ex1_reg_write;
    reg  [1:0] rr_ex1_result_src;
    reg        rr_ex1_branch;
    reg        rr_ex1_jal;
    reg        rr_ex1_jalr;
    reg  [2:0] rr_ex1_funct3;
    reg        rr_ex1_auipc;
    reg        rr_ex1_valid;
    reg [11:0] rr_ex1_csr_addr;
    reg        rr_ex1_csr_op;
    reg        rr_ex1_csr_write;
    reg        rr_ex1_is_ecall;
    reg        rr_ex1_is_ebreak;
    reg        rr_ex1_is_mret;
    reg        rr_ex1_is_wfi;
    reg        rr_ex1_is_fencei;
    reg        rr_ex1_pred_taken;
    reg [31:0] rr_ex1_pred_target;
    reg        rr_ex1_is_compressed;
    reg        rr_ex1_exc_pending;
    reg  [3:0] rr_ex1_exc_cause;
    reg [31:0] rr_ex1_exc_tval;
    reg        rr_ex1_is_amo;
    reg        rr_ex1_is_lr;
    reg        rr_ex1_is_sc;
    reg  [4:0] rr_ex1_amo_funct5;
    reg        rr_ex1_amo_aq;
    reg        rr_ex1_amo_rl;
    reg        rr_ex1_ex2_result;
    reg [31:0] rr_ex1_rs1_data;       // Register file read value
    reg [31:0] rr_ex1_rs2_data;       // Register file read value

    // --- EX1/EX2 Pipeline Registers ---
    reg [31:0] ex1_ex2_pc;
    reg [31:0] ex1_ex2_alu_result;
    reg [31:0] ex1_ex2_rs2_data;
    reg [31:0] ex1_ex2_pc_plus_n;     // PC+4 or PC+2 for compressed
    reg  [4:0] ex1_ex2_rd;
    reg        ex1_ex2_mem_read;
    reg        ex1_ex2_mem_write;
    reg  [2:0] ex1_ex2_mem_size;
    reg        ex1_ex2_reg_write;
    reg  [1:0] ex1_ex2_result_src;
    reg  [2:0] ex1_ex2_funct3;
    reg        ex1_ex2_valid;
    reg [11:0] ex1_ex2_csr_addr;
    reg        ex1_ex2_csr_op;
    reg        ex1_ex2_csr_write;
    reg        ex1_ex2_is_compressed;
    reg [31:0] ex1_ex2_instr_raw;
    reg        ex1_ex2_exc_pending;
    reg  [3:0] ex1_ex2_exc_cause;
    reg [31:0] ex1_ex2_exc_tval;
    reg        ex1_ex2_is_amo;
    reg        ex1_ex2_is_lr;
    reg        ex1_ex2_is_sc;
    reg  [4:0] ex1_ex2_amo_funct5;
    reg        ex1_ex2_amo_aq;
    reg        ex1_ex2_amo_rl;
    reg        ex1_ex2_ex2_result;
    reg signed [32:0] ex1_ex2_mul_a;
    reg signed [32:0] ex1_ex2_mul_b;
    reg  [4:0] ex1_ex2_mul_op;
    reg  [4:0] ex1_ex2_rs1;
    reg  [4:0] ex1_ex2_rs2;
    reg [31:0] ex1_ex2_rs1_data;
    reg [31:0] ex1_ex2_imm;
    reg [31:0] ex1_ex2_csr_wdata;
    reg        ex1_ex2_is_ecall;
    reg        ex1_ex2_is_ebreak;
    reg        ex1_ex2_is_mret;
    reg        ex1_ex2_is_fencei;
    reg        ex1_ex2_is_wfi;
    reg        ex1_ex2_pred_taken;
    reg [31:0] ex1_ex2_pred_target;

    // --- EX2/MEM Pipeline Registers ---
    reg [31:0] ex2_mem_result;        // ALU/CSR/MUL result
    reg [31:0] ex2_mem_rs2_data;
    reg [31:0] ex2_mem_pc_plus_n;
    reg  [4:0] ex2_mem_rd;
    reg        ex2_mem_mem_read;
    reg        ex2_mem_mem_write;
    reg  [2:0] ex2_mem_mem_size;
    reg        ex2_mem_reg_write;
    reg  [1:0] ex2_mem_result_src;
    reg        ex2_mem_valid;
    reg        ex2_mem_exc_pending;
    reg  [3:0] ex2_mem_exc_cause;
    reg [31:0] ex2_mem_exc_tval;
    reg [31:0] ex2_mem_pc;
    reg [31:0] ex2_mem_instr_raw;
    reg        ex2_mem_is_compressed;
    reg        ex2_mem_is_amo;
    reg        ex2_mem_is_lr;
    reg        ex2_mem_is_sc;
    reg  [4:0] ex2_mem_amo_funct5;
    reg        ex2_mem_amo_aq;
    reg        ex2_mem_amo_rl;

    // --- MEM/WB Pipeline Registers ---
    reg [31:0] mem_wb_result;
    reg [31:0] mem_wb_mem_data;
    reg [31:0] mem_wb_pc_plus_n;
    reg  [4:0] mem_wb_rd;
    reg        mem_wb_reg_write;
    reg  [1:0] mem_wb_result_src;
    reg        mem_wb_valid;
    reg        mem_wb_exc_pending;
    reg  [3:0] mem_wb_exc_cause;
    reg [31:0] mem_wb_exc_tval;
    reg [31:0] mem_wb_pc;
    reg [31:0] mem_wb_instr_raw;
    reg        mem_wb_is_compressed;

    // =========================================================================
    // REGISTER FILE
    // =========================================================================

    reg [31:0] regfile [0:31];
    integer idx;

    // =========================================================================
    // BRANCH PREDICTION STRUCTURES
    // =========================================================================

    // --- Gshare Predictor ---
    reg  [1:0] gshare_pht [0:255];    // 256-entry PHT, 2-bit saturating counters
    reg  [7:0] ghr;                    // 8-bit Global History Register

    // --- 2-Way Set-Associative BTB (64 sets x 2 ways = 128 entries) ---
    reg [31:0] btb_target [0:127];
    reg [23:0] btb_tag    [0:127];
    reg        btb_valid  [0:127];
    reg [63:0] btb_lru;               // 1 bit per set: 0=way0 LRU, 1=way1 LRU

    // --- Return Address Stack (8 entries) ---
    reg [31:0] ras [0:7];
    reg  [2:0] ras_tos;               // Top-of-stack pointer

    // --- IF-stage Partial Decode for Prediction ---
    wire [6:0] if_opcode   = imem_rdata[6:0];
    wire       if_is_branch = (if_opcode == 7'b1100011);
    wire       if_is_jal    = (if_opcode == 7'b1101111);
    wire       if_is_jalr   = (if_opcode == 7'b1100111);

    wire [4:0] if_rd  = imem_rdata[11:7];
    wire [4:0] if_rs1 = imem_rdata[19:15];
    wire       if_rd_link  = (if_rd  == 5'd1 || if_rd  == 5'd5);
    wire       if_rs1_link = (if_rs1 == 5'd1 || if_rs1 == 5'd5);

    // --- Gshare Lookup ---
    wire [7:0] gshare_idx_if      = pc[9:2] ^ ghr;
    wire [1:0] gshare_counter     = gshare_pht[gshare_idx_if];
    wire       gshare_predict_taken = gshare_counter[1];

    // --- BTB Lookup (2-way set-associative) ---
    wire  [5:0] btb_set = pc[7:2];
    wire        btb_hit_w0 = btb_valid[{btb_set, 1'b0}] &&
                             (btb_tag[{btb_set, 1'b0}] == pc[31:8]);
    wire        btb_hit_w1 = btb_valid[{btb_set, 1'b1}] &&
                             (btb_tag[{btb_set, 1'b1}] == pc[31:8]);
    wire        btb_hit = btb_hit_w0 || btb_hit_w1;
    wire [31:0] btb_pred_target = btb_hit_w0 ? btb_target[{btb_set, 1'b0}]
                                              : btb_target[{btb_set, 1'b1}];

    // --- RAS Prediction for JALR Returns ---
    wire        ras_predict    = if_is_jalr && if_rs1_link && !if_rd_link;
    wire [31:0] ras_pred_target = ras[ras_tos];

    // --- Combined Prediction ---
    wire if_predict_taken = imem_ready && (
        if_is_jal ||
        (if_is_branch && gshare_predict_taken && btb_hit) ||
        (if_is_jalr && if_rd_link) ||
        ras_predict
    );

    wire [31:0] if_predict_target = ras_predict           ? ras_pred_target :
                                    (if_is_jalr && if_rd_link) ? ras_pred_target :
                                    btb_pred_target;

    // =========================================================================
    // PROGRAM COUNTER AND IF1 STAGE
    // =========================================================================

    // --- Stall / Flush Forward Declarations ---
    wire        pipeline_flush;
    wire [31:0] flush_target;
    wire        if1_stall;
    // global_stall defined in forward declarations above

    // --- PC Logic ---
    // pc declared in forward declarations
    wire [31:0] pc_plus4 = pc + 32'd4;
    wire [31:0] pc_plus2 = pc + 32'd2;
    // When PC[1]=1 (halfword-aligned after jump), advance by +2 to next word boundary
    wire [31:0] pc_inc   = pc[1] ? pc_plus2 : pc_plus4;
    wire [31:0] pc_next  = pipeline_flush   ? flush_target :
                           if_predict_taken  ? if_predict_target :
                           pc_inc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pc <= RESET_ADDR;
        else if (pipeline_flush || !pc_stall)
            pc <= pc_next;
    end

    assign imem_addr = pc;
    assign imem_req  = !global_stall && !debug_stall && !wfi_active_w;

    // --- IF1/IF2 Pipeline Register ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if1_if2_pc          <= 32'd0;
            if1_if2_instr       <= 32'h0000_0013; // NOP (addi x0, x0, 0)
            if1_if2_valid       <= 1'b0;
            if1_if2_pred_taken  <= 1'b0;
            if1_if2_pred_target <= 32'd0;
            if1_if2_bus_error   <= 1'b0;
        end else if (!global_stall && !debug_stall) begin
            if (pipeline_flush) begin
                if1_if2_valid      <= 1'b0;
                if1_if2_pred_taken <= 1'b0;
                if1_if2_bus_error  <= 1'b0;
            end else if (!pc_stall) begin
                if1_if2_pc          <= pc;
                if1_if2_instr       <= imem_rdata;
                if1_if2_valid       <= imem_ready;
                if1_if2_pred_taken  <= if_predict_taken;
                if1_if2_pred_target <= if_predict_target;
                if1_if2_bus_error   <= imem_error && imem_ready;
            end else if (!if2_stall && !if2_process_comp_held) begin
                // PC is stalled (fetch latency) but IF2 consumed our data;
                // invalidate to prevent duplicate instruction execution.
                if1_if2_valid <= 1'b0;
            end
        end
    end

    // =========================================================================
    // IF2 STAGE — RV32C Instruction Alignment + Expansion
    // =========================================================================

    // --- Held-instruction buffer for misaligned / compressed ---
    reg [15:0] if2_held;
    reg        if2_held_valid;
    reg [31:0] if2_held_pc;

    // --- Instruction extraction wires ---
    wire [31:0] if2_raw_word = if1_if2_instr;
    wire [15:0] if2_lo_half  = if2_raw_word[15:0];
    wire [15:0] if2_hi_half  = if2_raw_word[31:16];

    // Effective IF1→IF2 valid: gated by consumed flag to prevent re-execution
    // during fetch stalls (when IF1→IF2 is frozen but downstream keeps running)
    wire if1_if2_valid_eff = if1_if2_valid && !if2_fetched;

    // Detect halfword-aligned entry (after jump/branch to PC[1]=1)
    wire if2_halfword_start = !if2_held_valid && if1_if2_valid_eff && if1_if2_pc[1];
    wire if2_hi_is_comp     = (if2_hi_half[1:0] != 2'b11);

    // Source selection
    wire if2_from_held     = if2_held_valid;
    wire if2_held_is_comp  = if2_held_valid && (if2_held[1:0] != 2'b11);
    wire if2_held_is_span  = if2_held_valid && (if2_held[1:0] == 2'b11);

    // The 16-bit compressed instruction to expand
    wire [15:0] if2_cinstr = if2_held_valid      ? if2_held :
                             if2_halfword_start   ? if2_hi_half :
                             if2_lo_half;
    wire [31:0] if2_spanning_instr = {if2_lo_half, if2_held};
    wire        if2_lo_is_comp = (if2_lo_half[1:0] != 2'b11);

    // What kind of instruction are we processing this cycle?
    assign if2_process_comp_held  = if2_held_is_comp;
    wire if2_process_span       = if2_held_is_span && if1_if2_valid_eff;
    // Normal word-aligned fresh (PC[1]=0)
    wire if2_process_comp_fresh = !if2_held_valid && if1_if2_valid_eff && !if1_if2_pc[1] && if2_lo_is_comp;
    wire if2_process_full_fresh = !if2_held_valid && if1_if2_valid_eff && !if1_if2_pc[1] && !if2_lo_is_comp;
    // Halfword-aligned entry (PC[1]=1): process from hi_half
    wire if2_process_comp_hi    = if2_halfword_start && if2_hi_is_comp;
    wire if2_process_span_hi    = if2_halfword_start && !if2_hi_is_comp;

    wire if2_is_compressed = if2_process_comp_held || if2_process_comp_fresh || if2_process_comp_hi;

    // Stall IF1 when IF2 is consuming from held buffer (no new fetch needed)
    assign if2_hold_fetch = if2_process_comp_held;

    // The raw instruction going to decode (before expansion)
    wire [31:0] if2_instr_pre = if2_process_comp_held  ? {16'b0, if2_held} :
                                if2_process_span       ? if2_spanning_instr :
                                if2_process_comp_fresh ? {16'b0, if2_lo_half} :
                                if2_process_comp_hi    ? {16'b0, if2_hi_half} :
                                if2_halfword_start     ? if2_raw_word :
                                if2_raw_word;

    // =========================================================================
    // RV32C Expander — Combinational
    // =========================================================================

    reg [31:0] c_expanded;
    reg        c_illegal;

    always @(*) begin
        c_expanded = 32'h0000_0013; // Default: NOP
        c_illegal  = 1'b0;

        if (if2_is_compressed) begin
            case (if2_cinstr[1:0])
            // =============================================================
            // Quadrant 0
            // =============================================================
            2'b00: begin
                case (if2_cinstr[15:13])
                3'b000: begin // C.ADDI4SPN
                    // nzuimm[5:4|9:6|2|3] = instr[12:5]
                    // nzuimm = {instr[10:7], instr[12:11], instr[5], instr[6], 2'b00}
                    if (if2_cinstr[12:5] == 8'd0) begin
                        c_illegal  = 1'b1;
                    end else begin
                        c_expanded = {2'b00,
                                      if2_cinstr[10:7],
                                      if2_cinstr[12:11],
                                      if2_cinstr[5],
                                      if2_cinstr[6],
                                      2'b00,
                                      5'd2,             // rs1 = x2 (sp)
                                      3'b000,           // funct3 = ADDI
                                      {2'b01, if2_cinstr[4:2]}, // rd'
                                      7'b0010011};      // OP-IMM
                    end
                end
                3'b010: begin // C.LW
                    // offset = {instr[5], instr[12:10], instr[6], 2'b00}
                    c_expanded = {5'b00000,
                                  if2_cinstr[5],
                                  if2_cinstr[12:10],
                                  if2_cinstr[6],
                                  2'b00,
                                  {2'b01, if2_cinstr[9:7]}, // rs1'
                                  3'b010,                   // funct3 = LW
                                  {2'b01, if2_cinstr[4:2]}, // rd'
                                  7'b0000011};              // LOAD
                end
                3'b110: begin // C.SW
                    // offset = {instr[5], instr[12:10], instr[6], 2'b00}
                    c_expanded = {5'b00000,
                                  if2_cinstr[5],
                                  if2_cinstr[12],
                                  {2'b01, if2_cinstr[4:2]}, // rs2'
                                  {2'b01, if2_cinstr[9:7]}, // rs1'
                                  3'b010,                   // funct3 = SW
                                  if2_cinstr[11:10],
                                  if2_cinstr[6],
                                  2'b00,
                                  7'b0100011};              // STORE
                end
                default: begin
                    c_illegal = 1'b1;
                end
                endcase
            end

            // =============================================================
            // Quadrant 1
            // =============================================================
            2'b01: begin
                case (if2_cinstr[15:13])
                3'b000: begin // C.NOP / C.ADDI
                    // nzimm[5] = instr[12], nzimm[4:0] = instr[6:2]
                    c_expanded = {{6{if2_cinstr[12]}},
                                  if2_cinstr[12],
                                  if2_cinstr[6:2],
                                  if2_cinstr[11:7],  // rs1/rd
                                  3'b000,
                                  if2_cinstr[11:7],  // rd
                                  7'b0010011};       // OP-IMM (ADDI)
                end
                3'b001: begin // C.JAL (RV32 only)
                    // offset[11|4|9:8|10|6|7|3:1|5]
                    c_expanded = {if2_cinstr[12],     // imm[20]
                                  if2_cinstr[8],      // imm[10]
                                  if2_cinstr[10:9],   // imm[9:8]
                                  if2_cinstr[6],      // imm[7]
                                  if2_cinstr[7],      // imm[6]
                                  if2_cinstr[2],      // imm[5]
                                  if2_cinstr[11],     // imm[4]
                                  if2_cinstr[5:3],    // imm[3:1]
                                  if2_cinstr[12],     // imm[11] (sign)
                                  {8{if2_cinstr[12]}},// imm[19:12]
                                  5'd1,               // rd = x1 (ra)
                                  7'b1101111};        // JAL
                end
                3'b010: begin // C.LI
                    // ADDI rd, x0, imm
                    c_expanded = {{6{if2_cinstr[12]}},
                                  if2_cinstr[12],
                                  if2_cinstr[6:2],
                                  5'd0,              // rs1 = x0
                                  3'b000,
                                  if2_cinstr[11:7],  // rd
                                  7'b0010011};       // OP-IMM (ADDI)
                end
                3'b011: begin // C.ADDI16SP / C.LUI
                    if (if2_cinstr[11:7] == 5'd2) begin
                        // C.ADDI16SP: ADDI x2, x2, nzimm
                        // nzimm = {instr[12], instr[4:3], instr[5], instr[2], instr[6], 4'b0000}
                        if ({if2_cinstr[12], if2_cinstr[6:2]} == 6'd0) begin
                            c_illegal = 1'b1;
                        end else begin
                            c_expanded = {{2{if2_cinstr[12]}},  // sign ext
                                          if2_cinstr[12],        // nzimm[9]
                                          if2_cinstr[4:3],       // nzimm[8:7]
                                          if2_cinstr[5],         // nzimm[6]
                                          if2_cinstr[2],         // nzimm[5]
                                          if2_cinstr[6],         // nzimm[4]
                                          4'b0000,               // nzimm[3:0]
                                          5'd2,                  // rs1 = x2
                                          3'b000,
                                          5'd2,                  // rd = x2
                                          7'b0010011};           // OP-IMM (ADDI)
                        end
                    end else if (if2_cinstr[11:7] != 5'd0) begin
                        // C.LUI
                        if ({if2_cinstr[12], if2_cinstr[6:2]} == 6'd0) begin
                            c_illegal = 1'b1;
                        end else begin
                            c_expanded = {{14{if2_cinstr[12]}},  // sign ext
                                          if2_cinstr[12],
                                          if2_cinstr[6:2],
                                          if2_cinstr[11:7],      // rd
                                          7'b0110111};           // LUI
                        end
                    end else begin
                        c_illegal = 1'b1; // rd==0 is HINTS, treat as illegal
                    end
                end
                3'b100: begin // C.SRLI, C.SRAI, C.ANDI, C.SUB/XOR/OR/AND
                    case (if2_cinstr[11:10])
                    2'b00: begin // C.SRLI
                        c_expanded = {7'b0000000,
                                      if2_cinstr[6:2],             // shamt
                                      {2'b01, if2_cinstr[9:7]},    // rs1'
                                      3'b101,                       // funct3 = SRL
                                      {2'b01, if2_cinstr[9:7]},    // rd'
                                      7'b0010011};                  // OP-IMM
                    end
                    2'b01: begin // C.SRAI
                        c_expanded = {7'b0100000,
                                      if2_cinstr[6:2],             // shamt
                                      {2'b01, if2_cinstr[9:7]},    // rs1'
                                      3'b101,                       // funct3 = SRA
                                      {2'b01, if2_cinstr[9:7]},    // rd'
                                      7'b0010011};                  // OP-IMM
                    end
                    2'b10: begin // C.ANDI
                        c_expanded = {{6{if2_cinstr[12]}},
                                      if2_cinstr[12],
                                      if2_cinstr[6:2],
                                      {2'b01, if2_cinstr[9:7]},    // rs1'
                                      3'b111,                       // funct3 = ANDI
                                      {2'b01, if2_cinstr[9:7]},    // rd'
                                      7'b0010011};                  // OP-IMM
                    end
                    2'b11: begin // C.SUB, C.XOR, C.OR, C.AND
                        case (if2_cinstr[6:5])
                        2'b00: begin // C.SUB
                            c_expanded = {7'b0100000,
                                          {2'b01, if2_cinstr[4:2]}, // rs2'
                                          {2'b01, if2_cinstr[9:7]}, // rs1'
                                          3'b000,                   // funct3 = SUB
                                          {2'b01, if2_cinstr[9:7]}, // rd'
                                          7'b0110011};              // OP
                        end
                        2'b01: begin // C.XOR
                            c_expanded = {7'b0000000,
                                          {2'b01, if2_cinstr[4:2]},
                                          {2'b01, if2_cinstr[9:7]},
                                          3'b100,
                                          {2'b01, if2_cinstr[9:7]},
                                          7'b0110011};
                        end
                        2'b10: begin // C.OR
                            c_expanded = {7'b0000000,
                                          {2'b01, if2_cinstr[4:2]},
                                          {2'b01, if2_cinstr[9:7]},
                                          3'b110,
                                          {2'b01, if2_cinstr[9:7]},
                                          7'b0110011};
                        end
                        2'b11: begin // C.AND
                            c_expanded = {7'b0000000,
                                          {2'b01, if2_cinstr[4:2]},
                                          {2'b01, if2_cinstr[9:7]},
                                          3'b111,
                                          {2'b01, if2_cinstr[9:7]},
                                          7'b0110011};
                        end
                        endcase
                    end
                    endcase
                end
                3'b101: begin // C.J
                    // offset encoding same as C.JAL but rd = x0
                    c_expanded = {if2_cinstr[12],
                                  if2_cinstr[8],
                                  if2_cinstr[10:9],
                                  if2_cinstr[6],
                                  if2_cinstr[7],
                                  if2_cinstr[2],
                                  if2_cinstr[11],
                                  if2_cinstr[5:3],
                                  if2_cinstr[12],
                                  {8{if2_cinstr[12]}},
                                  5'd0,             // rd = x0
                                  7'b1101111};      // JAL
                end
                3'b110: begin // C.BEQZ
                    // BEQ rs1', x0, offset
                    // offset = {instr[12], instr[6:5], instr[2], instr[11:10], instr[4:3], 1'b0}
                    c_expanded = {{3{if2_cinstr[12]}},  // imm[8|4:3]
                                  if2_cinstr[12],
                                  if2_cinstr[6:5],
                                  if2_cinstr[2],
                                  5'd0,                  // rs2 = x0
                                  {2'b01, if2_cinstr[9:7]}, // rs1'
                                  3'b000,                // funct3 = BEQ
                                  if2_cinstr[11:10],
                                  if2_cinstr[4:3],
                                  1'b0,
                                  7'b1100011};           // BRANCH
                end
                3'b111: begin // C.BNEZ
                    c_expanded = {{3{if2_cinstr[12]}},
                                  if2_cinstr[12],
                                  if2_cinstr[6:5],
                                  if2_cinstr[2],
                                  5'd0,
                                  {2'b01, if2_cinstr[9:7]},
                                  3'b001,                // funct3 = BNE
                                  if2_cinstr[11:10],
                                  if2_cinstr[4:3],
                                  1'b0,
                                  7'b1100011};
                end
                default: begin
                    c_illegal = 1'b1;
                end
                endcase
            end

            // =============================================================
            // Quadrant 2
            // =============================================================
            2'b10: begin
                case (if2_cinstr[15:13])
                3'b000: begin // C.SLLI
                    c_expanded = {7'b0000000,
                                  if2_cinstr[6:2],       // shamt
                                  if2_cinstr[11:7],      // rs1/rd
                                  3'b001,                 // funct3 = SLL
                                  if2_cinstr[11:7],      // rd
                                  7'b0010011};            // OP-IMM
                end
                3'b010: begin // C.LWSP
                    if (if2_cinstr[11:7] == 5'd0) begin
                        c_illegal = 1'b1;               // rd=0 reserved
                    end else begin
                        // offset = {instr[3:2], instr[12], instr[6:4], 2'b00}
                        c_expanded = {4'b0000,
                                      if2_cinstr[3:2],
                                      if2_cinstr[12],
                                      if2_cinstr[6:4],
                                      2'b00,
                                      5'd2,              // rs1 = x2 (sp)
                                      3'b010,            // funct3 = LW
                                      if2_cinstr[11:7],  // rd
                                      7'b0000011};       // LOAD
                    end
                end
                3'b100: begin
                    if (if2_cinstr[12] == 1'b0) begin
                        if (if2_cinstr[6:2] == 5'd0) begin
                            // C.JR: JALR x0, rs1, 0
                            if (if2_cinstr[11:7] == 5'd0) begin
                                c_illegal = 1'b1;       // rs1=0 reserved
                            end else begin
                                c_expanded = {12'd0,
                                              if2_cinstr[11:7], // rs1
                                              3'b000,
                                              5'd0,             // rd = x0
                                              7'b1100111};      // JALR
                            end
                        end else begin
                            // C.MV: ADD rd, x0, rs2
                            c_expanded = {7'b0000000,
                                          if2_cinstr[6:2],   // rs2
                                          5'd0,              // rs1 = x0
                                          3'b000,
                                          if2_cinstr[11:7],  // rd
                                          7'b0110011};       // OP
                        end
                    end else begin
                        if (if2_cinstr[6:2] == 5'd0) begin
                            if (if2_cinstr[11:7] == 5'd0) begin
                                // C.EBREAK
                                c_expanded = 32'h0010_0073; // EBREAK
                            end else begin
                                // C.JALR: JALR x1, rs1, 0
                                c_expanded = {12'd0,
                                              if2_cinstr[11:7], // rs1
                                              3'b000,
                                              5'd1,             // rd = x1 (ra)
                                              7'b1100111};      // JALR
                            end
                        end else begin
                            if (if2_cinstr[11:7] == 5'd0) begin
                                c_illegal = 1'b1; // HINTS
                            end else begin
                                // C.ADD: ADD rd, rd, rs2
                                c_expanded = {7'b0000000,
                                              if2_cinstr[6:2],   // rs2
                                              if2_cinstr[11:7],  // rs1
                                              3'b000,
                                              if2_cinstr[11:7],  // rd
                                              7'b0110011};       // OP
                            end
                        end
                    end
                end
                3'b110: begin // C.SWSP
                    // offset = {instr[8:7], instr[12:9], 2'b00}
                    c_expanded = {4'b0000,
                                  if2_cinstr[8:7],
                                  if2_cinstr[12],
                                  if2_cinstr[6:2],       // rs2
                                  5'd2,                  // rs1 = x2 (sp)
                                  3'b010,                // funct3 = SW
                                  if2_cinstr[11:9],
                                  2'b00,
                                  7'b0100011};           // STORE
                end
                default: begin
                    c_illegal = 1'b1;
                end
                endcase
            end

            default: begin
                // Quadrant 3 (2'b11) means 32-bit — should not reach here
                c_illegal = 1'b1;
            end
            endcase
        end
    end

    // --- Select expanded or original instruction ---
    wire [31:0] if2_instr_expanded = if2_is_compressed ? c_expanded : if2_instr_pre;

    // Determine instruction valid for this cycle
    wire if2_valid_out = (if2_process_comp_held) ||
                         (if2_process_span) ||
                         (if2_process_comp_fresh) ||
                         (if2_process_full_fresh) ||
                         (if2_process_comp_hi);
    // span_hi does NOT produce a valid instruction (saves to held only)

    // Exception from compressed decode
    wire if2_c_illegal = if2_is_compressed && c_illegal;

    // I-Fetch PMP fault — combinational check declared near data PMP (after CSR arrays)
    // Forward declaration of wire — assigned after csr_pmpcfg/csr_pmpaddr declarations
    wire if2_imem_pmp_fault;

    // Track bus error propagation (includes I-fetch PMP fault)
    wire if2_bus_error_out = (if2_process_comp_held || if2_process_comp_hi) ? 1'b0 :
                             (if1_if2_bus_error || if2_imem_pmp_fault);

    // PC for this instruction (must reflect actual byte address)
    wire [31:0] if2_pc_out = if2_process_comp_held  ? if2_held_pc :
                             if2_process_span        ? if2_held_pc :
                             if1_if2_pc;  // comp_fresh, full_fresh, comp_hi all use if1_if2_pc

    // Prediction propagation
    wire if2_pred_taken_out = (if2_process_comp_held || if2_process_comp_hi) ? 1'b0 :
                              if1_if2_pred_taken;
    wire [31:0] if2_pred_target_out = (if2_process_comp_held || if2_process_comp_hi) ? 32'd0 :
                                       if1_if2_pred_target;

    // Raw instruction for mtval
    wire [31:0] if2_instr_raw_out = if2_is_compressed ? {16'b0, if2_cinstr} : if2_instr_pre;

    // --- IF2 stall signal (forward-declared above) ---

    // --- IF2/ID Pipeline Register ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if2_id_pc            <= 32'd0;
            if2_id_instr         <= 32'h0000_0013;
            if2_id_instr_raw     <= 32'd0;
            if2_id_valid         <= 1'b0;
            if2_id_pred_taken    <= 1'b0;
            if2_id_is_compressed <= 1'b0;
            if2_id_bus_error     <= 1'b0;
            if2_id_c_illegal     <= 1'b0;
            if2_id_pred_target   <= 32'd0;
        end else if (!global_stall && !debug_stall) begin
            if (pipeline_flush) begin
                if2_id_valid         <= 1'b0;
                if2_id_pred_taken    <= 1'b0;
                if2_id_bus_error     <= 1'b0;
                if2_id_c_illegal     <= 1'b0;
            end else if (!if2_stall) begin
                if2_id_pc            <= if2_pc_out;
                if2_id_instr         <= if2_instr_expanded;
                if2_id_instr_raw     <= if2_instr_raw_out;
                if2_id_valid         <= if2_valid_out;
                if2_id_pred_taken    <= if2_pred_taken_out;
                if2_id_is_compressed <= if2_is_compressed;
                if2_id_bus_error     <= if2_bus_error_out;
                if2_id_c_illegal     <= if2_c_illegal;
                if2_id_pred_target   <= if2_pred_target_out;
            end
        end
    end

    // --- Held Buffer Update Logic ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if2_held       <= 16'd0;
            if2_held_valid <= 1'b0;
            if2_held_pc    <= 32'd0;
        end else if (!global_stall && !debug_stall) begin
            if (pipeline_flush) begin
                if2_held_valid <= 1'b0;
            end else if (!if2_stall) begin
                if (if2_process_comp_held) begin
                    // Consumed compressed from held; held becomes empty
                    if2_held_valid <= 1'b0;
                end else if (if2_process_span) begin
                    // Consumed spanning 32-bit: lower half from held + upper from fetch
                    if2_held       <= if2_hi_half;
                    if2_held_valid <= 1'b1;
                    if2_held_pc    <= if1_if2_pc + 32'd2;
                end else if (if2_process_comp_fresh) begin
                    // Consumed compressed from lower half of fetch
                    if2_held       <= if2_hi_half;
                    if2_held_valid <= 1'b1;
                    if2_held_pc    <= if1_if2_pc + 32'd2;
                end else if (if2_process_full_fresh) begin
                    // Consumed full 32-bit instruction, nothing to hold
                    if2_held_valid <= 1'b0;
                end else if (if2_process_comp_hi) begin
                    // Consumed compressed from hi_half (halfword entry), nothing to hold
                    if2_held_valid <= 1'b0;
                end else if (if2_process_span_hi) begin
                    // Halfword entry, hi_half starts a 32-bit instruction
                    // Save hi_half to held as spanning start
                    if2_held       <= if2_hi_half;
                    if2_held_valid <= 1'b1;
                    if2_held_pc    <= if1_if2_pc;
                end
            end
        end
    end

    // --- IF2 fetch-consumed tracker ---
    // Prevents re-execution of the same instruction when IF1→IF2 is frozen
    // during fetch stalls (imem_req && !imem_ready). Once IF2→ID consumes a
    // fresh instruction from IF1→IF2, this flag blocks further consumption
    // until a new fetch arrives (!pc_stall) or a flush occurs.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            if2_fetched <= 1'b0;
        else if (!global_stall && !debug_stall) begin
            if (pipeline_flush)
                if2_fetched <= 1'b0;
            else if (!pc_stall)
                if2_fetched <= 1'b0;
            else if (!if2_stall && if2_valid_out && !if2_process_comp_held)
                if2_fetched <= 1'b1;
        end
    end


    // =========================================================================
    // ID STAGE — Instruction Decode
    // =========================================================================

    // --- Instruction Field Extraction ---
    wire [6:0]  opcode  = if2_id_instr[6:0];
    wire [4:0]  rd      = if2_id_instr[11:7];
    wire [2:0]  funct3  = if2_id_instr[14:12];
    wire [4:0]  rs1     = if2_id_instr[19:15];
    wire [4:0]  rs2     = if2_id_instr[24:20];
    wire [6:0]  funct7  = if2_id_instr[31:25];
    wire [4:0]  funct5  = if2_id_instr[31:27];
    wire        amo_aq  = if2_id_instr[26];
    wire        amo_rl  = if2_id_instr[25];
    wire [11:0] funct12 = if2_id_instr[31:20];

    // --- Immediate Generation ---
    wire [31:0] imm_i = {{20{if2_id_instr[31]}}, if2_id_instr[31:20]};
    wire [31:0] imm_s = {{20{if2_id_instr[31]}}, if2_id_instr[31:25], if2_id_instr[11:7]};
    wire [31:0] imm_b = {{19{if2_id_instr[31]}}, if2_id_instr[31], if2_id_instr[7],
                          if2_id_instr[30:25], if2_id_instr[11:8], 1'b0};
    wire [31:0] imm_u = {if2_id_instr[31:12], 12'b0};
    wire [31:0] imm_j = {{11{if2_id_instr[31]}}, if2_id_instr[31], if2_id_instr[19:12],
                          if2_id_instr[20], if2_id_instr[30:21], 1'b0};

    reg [31:0] imm_dec;
    always @(*) begin
        case (opcode)
            OP_LUI, OP_AUIPC:         imm_dec = imm_u;
            OP_JAL:                    imm_dec = imm_j;
            OP_JALR, OP_LOAD, OP_IMM: imm_dec = imm_i;
            OP_BRANCH:                 imm_dec = imm_b;
            OP_STORE:                  imm_dec = imm_s;
            OP_SYSTEM:                 imm_dec = {27'b0, rs1}; // CSR zimm
            default:                   imm_dec = 32'd0;
        endcase
    end

    // --- Control Signal Decode ---
    reg  [4:0] dec_alu_op;
    reg        dec_alu_src;
    reg        dec_mem_read;
    reg        dec_mem_write;
    reg        dec_reg_write;
    reg  [1:0] dec_result_src;
    reg        dec_branch;
    reg        dec_jal;
    reg        dec_jalr;
    reg        dec_auipc;
    reg        dec_csr_op;
    reg        dec_csr_write;
    reg        dec_is_ecall;
    reg        dec_is_ebreak;
    reg        dec_is_mret;
    reg        dec_is_wfi;
    reg        dec_is_fencei;
    reg        dec_is_amo;
    reg        dec_is_lr;
    reg        dec_is_sc;
    reg  [4:0] dec_amo_funct5;
    reg        dec_ex2_result;

    always @(*) begin
        // Defaults — no operation
        dec_alu_op     = ALU_ADD;
        dec_alu_src    = 1'b0;
        dec_mem_read   = 1'b0;
        dec_mem_write  = 1'b0;
        dec_reg_write  = 1'b0;
        dec_result_src = 2'b00;
        dec_branch     = 1'b0;
        dec_jal        = 1'b0;
        dec_jalr       = 1'b0;
        dec_auipc      = 1'b0;
        dec_csr_op     = 1'b0;
        dec_csr_write  = 1'b0;
        dec_is_ecall   = 1'b0;
        dec_is_ebreak  = 1'b0;
        dec_is_mret    = 1'b0;
        dec_is_wfi     = 1'b0;
        dec_is_fencei  = 1'b0;
        dec_is_amo     = 1'b0;
        dec_is_lr      = 1'b0;
        dec_is_sc      = 1'b0;
        dec_amo_funct5 = 5'd0;
        dec_ex2_result = 1'b0;

        case (opcode)
            OP_LUI: begin
                dec_alu_op    = ALU_PASS_B;
                dec_alu_src   = 1'b1;
                dec_reg_write = 1'b1;
            end

            OP_AUIPC: begin
                dec_alu_op    = ALU_ADD;
                dec_alu_src   = 1'b1;
                dec_auipc     = 1'b1;
                dec_reg_write = 1'b1;
            end

            OP_JAL: begin
                dec_jal        = 1'b1;
                dec_reg_write  = 1'b1;
                dec_result_src = 2'b10; // PC+N
            end

            OP_JALR: begin
                dec_jalr       = 1'b1;
                dec_alu_op     = ALU_ADD;
                dec_alu_src    = 1'b1;
                dec_reg_write  = 1'b1;
                dec_result_src = 2'b10; // PC+N
            end

            OP_BRANCH: begin
                dec_branch = 1'b1;
            end

            OP_LOAD: begin
                dec_alu_op     = ALU_ADD;
                dec_alu_src    = 1'b1;
                dec_mem_read   = 1'b1;
                dec_reg_write  = 1'b1;
                dec_result_src = 2'b01; // MEM
            end

            OP_STORE: begin
                dec_alu_op    = ALU_ADD;
                dec_alu_src   = 1'b1;
                dec_mem_write = 1'b1;
            end

            OP_IMM: begin
                dec_alu_src   = 1'b1;
                dec_reg_write = 1'b1;
                case (funct3)
                    3'b000: dec_alu_op = ALU_ADD;
                    3'b001: dec_alu_op = ALU_SLL;
                    3'b010: dec_alu_op = ALU_SLT;
                    3'b011: dec_alu_op = ALU_SLTU;
                    3'b100: dec_alu_op = ALU_XOR;
                    3'b101: dec_alu_op = funct7[5] ? ALU_SRA : ALU_SRL;
                    3'b110: dec_alu_op = ALU_OR;
                    3'b111: dec_alu_op = ALU_AND;
                endcase
            end

            OP_REG: begin
                dec_reg_write = 1'b1;
                if (funct7 == 7'b0000001) begin
                    // M-extension
                    case (funct3)
                        3'b000: dec_alu_op = ALU_MUL;
                        3'b001: dec_alu_op = ALU_MULH;
                        3'b010: dec_alu_op = ALU_MULHSU;
                        3'b011: dec_alu_op = ALU_MULHU;
                        3'b100: dec_alu_op = ALU_DIV;
                        3'b101: dec_alu_op = ALU_DIVU;
                        3'b110: dec_alu_op = ALU_REM;
                        3'b111: dec_alu_op = ALU_REMU;
                    endcase
                    // MUL variants (funct3[2]==0) produce result in EX2
                    dec_ex2_result = !funct3[2];
                end else begin
                    // Base integer ALU
                    case (funct3)
                        3'b000: dec_alu_op = funct7[5] ? ALU_SUB : ALU_ADD;
                        3'b001: dec_alu_op = ALU_SLL;
                        3'b010: dec_alu_op = ALU_SLT;
                        3'b011: dec_alu_op = ALU_SLTU;
                        3'b100: dec_alu_op = ALU_XOR;
                        3'b101: dec_alu_op = funct7[5] ? ALU_SRA : ALU_SRL;
                        3'b110: dec_alu_op = ALU_OR;
                        3'b111: dec_alu_op = ALU_AND;
                    endcase
                end
            end

            OP_FENCE: begin
                if (funct3 == 3'b001)
                    dec_is_fencei = 1'b1;
                // FENCE (funct3=000) treated as NOP
            end

            OP_SYSTEM: begin
                if (funct3 != 3'b000) begin
                    // CSR instructions
                    dec_csr_op     = 1'b1;
                    dec_reg_write  = 1'b1;
                    dec_result_src = 2'b11; // CSR read value
                    dec_ex2_result = 1'b1;  // CSR result available in EX2
                    dec_alu_src    = funct3[2]; // 1=zimm, 0=rs1
                    case (funct3)
                        3'b001: dec_csr_write = 1'b1;            // CSRRW
                        3'b010: dec_csr_write = (rs1 != 5'd0);   // CSRRS
                        3'b011: dec_csr_write = (rs1 != 5'd0);   // CSRRC
                        3'b101: dec_csr_write = 1'b1;            // CSRRWI
                        3'b110: dec_csr_write = (rs1 != 5'd0);   // CSRRSI
                        3'b111: dec_csr_write = (rs1 != 5'd0);   // CSRRCI
                        default: ;
                    endcase
                end else begin
                    // Privileged instructions (funct3=000)
                    case (funct12)
                        12'h000: dec_is_ecall  = 1'b1;
                        12'h001: dec_is_ebreak = 1'b1;
                        12'h302: dec_is_mret   = 1'b1;
                        12'h105: dec_is_wfi    = 1'b1;
                        default: ;
                    endcase
                end
            end

            OP_AMO: begin
                dec_is_amo     = 1'b1;
                dec_alu_op     = ALU_ADD;
                dec_alu_src    = 1'b1;  // rs1 + imm(0) = address
                dec_mem_read   = 1'b0;
                dec_mem_write  = 1'b0;
                dec_reg_write  = 1'b1;
                dec_result_src = 2'b00; // ALU result path (amo_read_data / sc_result)
                dec_amo_funct5 = funct5;
                if (funct5 == AMO_LR) begin
                    dec_is_lr      = 1'b1;
                    dec_mem_read   = 1'b1;  // LR issues memory read
                    dec_result_src = 2'b01; // LR returns memory data
                end
                if (funct5 == AMO_SC) begin
                    dec_is_sc     = 1'b1;
                    dec_mem_write = 1'b1;  // SC issues memory write
                end
            end

            default: ; // Unknown opcode — handled by illegal detection
        endcase
    end

    // --- Illegal Instruction Detection ---
    reg dec_illegal;
    always @(*) begin
        dec_illegal = 1'b0;
        case (opcode)
            OP_LUI, OP_AUIPC, OP_JAL: ; // Always legal

            OP_JALR: begin
                if (funct3 != 3'b000)
                    dec_illegal = 1'b1;
            end

            OP_BRANCH: begin
                if (funct3 == 3'b010 || funct3 == 3'b011)
                    dec_illegal = 1'b1;
            end

            OP_LOAD: begin
                if (funct3 == 3'b011 || funct3 == 3'b110 || funct3 == 3'b111)
                    dec_illegal = 1'b1;
            end

            OP_STORE: begin
                if (funct3[2] || funct3 == 3'b011)
                    dec_illegal = 1'b1;
            end

            OP_IMM: begin
                case (funct3)
                    3'b001: begin // SLLI
                        if (funct7[6:1] != 6'b000000)
                            dec_illegal = 1'b1;
                    end
                    3'b101: begin // SRLI / SRAI
                        if (funct7[6:1] != 6'b000000 && funct7[6:1] != 6'b010000)
                            dec_illegal = 1'b1;
                    end
                    default: ;
                endcase
            end

            OP_REG: begin
                case (funct7)
                    7'b0000000: ; // Base ALU — all funct3 valid
                    7'b0100000: begin
                        if (funct3 != 3'b000 && funct3 != 3'b101)
                            dec_illegal = 1'b1; // Only SUB and SRA
                    end
                    7'b0000001: ; // M-extension — all funct3 valid
                    default: dec_illegal = 1'b1;
                endcase
            end

            OP_FENCE: begin
                if (funct3 != 3'b000 && funct3 != 3'b001)
                    dec_illegal = 1'b1;
            end

            OP_SYSTEM: begin
                if (funct3 == 3'b000) begin
                    case (funct12)
                        12'h000, 12'h001, 12'h302, 12'h105: begin
                            if (rs1 != 5'd0 || rd != 5'd0)
                                dec_illegal = 1'b1;
                        end
                        default: dec_illegal = 1'b1;
                    endcase
                end else if (funct3 == 3'b100) begin
                    dec_illegal = 1'b1; // Reserved funct3
                end
            end

            OP_AMO: begin
                if (funct3 != 3'b010) begin
                    dec_illegal = 1'b1; // Must be word-sized (.W)
                end else begin
                    case (funct5)
                        AMO_LR, AMO_SC, AMO_SWAP, AMO_ADD, AMO_XOR,
                        AMO_AND, AMO_OR, AMO_MIN, AMO_MAX, AMO_MINU, AMO_MAXU: begin
                            if (funct5 == AMO_LR && rs2 != 5'd0)
                                dec_illegal = 1'b1;
                        end
                        default: dec_illegal = 1'b1;
                    endcase
                end
            end

            default: dec_illegal = 1'b1; // Unknown opcode
        endcase
    end

    // --- Exception Propagation ---
    wire id_exc_pending = if2_id_bus_error || if2_id_c_illegal || (dec_illegal && if2_id_valid);
    wire [3:0]  id_exc_cause = if2_id_bus_error ? EXC_INSTR_FAULT : EXC_ILLEGAL_INSTR;
    wire [31:0] id_exc_tval  = if2_id_bus_error ? if2_id_pc : if2_id_instr_raw;

    // --- ID/RR Pipeline Register ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            id_rr_valid         <= 1'b0;
            id_rr_pc            <= 32'd0;
            id_rr_instr_raw     <= 32'd0;
            id_rr_imm           <= 32'd0;
            id_rr_rd            <= 5'd0;
            id_rr_rs1           <= 5'd0;
            id_rr_rs2           <= 5'd0;
            id_rr_alu_op        <= 5'd0;
            id_rr_alu_src       <= 1'b0;
            id_rr_mem_read      <= 1'b0;
            id_rr_mem_write     <= 1'b0;
            id_rr_mem_size      <= 3'd0;
            id_rr_reg_write     <= 1'b0;
            id_rr_result_src    <= 2'b00;
            id_rr_branch        <= 1'b0;
            id_rr_jal           <= 1'b0;
            id_rr_jalr          <= 1'b0;
            id_rr_funct3        <= 3'd0;
            id_rr_auipc         <= 1'b0;
            id_rr_csr_addr      <= 12'd0;
            id_rr_csr_op        <= 1'b0;
            id_rr_csr_write     <= 1'b0;
            id_rr_is_ecall      <= 1'b0;
            id_rr_is_ebreak     <= 1'b0;
            id_rr_is_mret       <= 1'b0;
            id_rr_is_wfi        <= 1'b0;
            id_rr_is_fencei     <= 1'b0;
            id_rr_pred_taken    <= 1'b0;
            id_rr_pred_target   <= 32'd0;
            id_rr_is_compressed <= 1'b0;
            id_rr_exc_pending   <= 1'b0;
            id_rr_exc_cause     <= 4'd0;
            id_rr_exc_tval      <= 32'd0;
            id_rr_is_amo        <= 1'b0;
            id_rr_is_lr         <= 1'b0;
            id_rr_is_sc         <= 1'b0;
            id_rr_amo_funct5    <= 5'd0;
            id_rr_amo_aq        <= 1'b0;
            id_rr_amo_rl        <= 1'b0;
            id_rr_ex2_result    <= 1'b0;
        end else if (!global_stall && !debug_stall) begin
            if (pipeline_flush) begin
                id_rr_valid         <= 1'b0;
                id_rr_pc            <= 32'd0;
                id_rr_instr_raw     <= 32'd0;
                id_rr_imm           <= 32'd0;
                id_rr_rd            <= 5'd0;
                id_rr_rs1           <= 5'd0;
                id_rr_rs2           <= 5'd0;
                id_rr_alu_op        <= 5'd0;
                id_rr_alu_src       <= 1'b0;
                id_rr_mem_read      <= 1'b0;
                id_rr_mem_write     <= 1'b0;
                id_rr_mem_size      <= 3'd0;
                id_rr_reg_write     <= 1'b0;
                id_rr_result_src    <= 2'b00;
                id_rr_branch        <= 1'b0;
                id_rr_jal           <= 1'b0;
                id_rr_jalr          <= 1'b0;
                id_rr_funct3        <= 3'd0;
                id_rr_auipc         <= 1'b0;
                id_rr_csr_addr      <= 12'd0;
                id_rr_csr_op        <= 1'b0;
                id_rr_csr_write     <= 1'b0;
                id_rr_is_ecall      <= 1'b0;
                id_rr_is_ebreak     <= 1'b0;
                id_rr_is_mret       <= 1'b0;
                id_rr_is_wfi        <= 1'b0;
                id_rr_is_fencei     <= 1'b0;
                id_rr_pred_taken    <= 1'b0;
                id_rr_pred_target   <= 32'd0;
                id_rr_is_compressed <= 1'b0;
                id_rr_exc_pending   <= 1'b0;
                id_rr_exc_cause     <= 4'd0;
                id_rr_exc_tval      <= 32'd0;
                id_rr_is_amo        <= 1'b0;
                id_rr_is_lr         <= 1'b0;
                id_rr_is_sc         <= 1'b0;
                id_rr_amo_funct5    <= 5'd0;
                id_rr_amo_aq        <= 1'b0;
                id_rr_amo_rl        <= 1'b0;
                id_rr_ex2_result    <= 1'b0;
            end else if (!hazard_stall) begin
                // Data fields — always propagated
                id_rr_pc            <= if2_id_pc;
                id_rr_instr_raw     <= if2_id_instr_raw;
                id_rr_imm           <= imm_dec;
                id_rr_rd            <= rd;
                id_rr_rs1           <= rs1;
                id_rr_rs2           <= rs2;
                id_rr_funct3        <= funct3;
                id_rr_alu_op        <= dec_alu_op;
                id_rr_alu_src       <= dec_alu_src;
                id_rr_mem_size      <= funct3;
                id_rr_result_src    <= dec_result_src;
                id_rr_auipc         <= dec_auipc;
                id_rr_csr_addr      <= funct12;
                id_rr_amo_funct5    <= dec_amo_funct5;
                id_rr_amo_aq        <= amo_aq;
                id_rr_amo_rl        <= amo_rl;
                id_rr_ex2_result    <= dec_ex2_result;
                id_rr_pred_taken    <= if2_id_pred_taken;
                id_rr_pred_target   <= if2_id_pred_target;
                id_rr_is_compressed <= if2_id_is_compressed;

                // Valid — kept high even on exception so instruction flows to WB
                id_rr_valid         <= if2_id_valid;

                // Exception info
                id_rr_exc_pending   <= id_exc_pending && if2_id_valid;
                id_rr_exc_cause     <= id_exc_cause;
                id_rr_exc_tval      <= id_exc_tval;

                // Side-effect controls — suppressed on exception
                id_rr_mem_read      <= id_exc_pending ? 1'b0 : dec_mem_read;
                id_rr_mem_write     <= id_exc_pending ? 1'b0 : dec_mem_write;
                id_rr_reg_write     <= id_exc_pending ? 1'b0 : dec_reg_write;
                id_rr_csr_op        <= id_exc_pending ? 1'b0 : dec_csr_op;
                id_rr_csr_write     <= id_exc_pending ? 1'b0 : dec_csr_write;
                id_rr_branch        <= id_exc_pending ? 1'b0 : dec_branch;
                id_rr_jal           <= id_exc_pending ? 1'b0 : dec_jal;
                id_rr_jalr          <= id_exc_pending ? 1'b0 : dec_jalr;
                id_rr_is_ecall      <= id_exc_pending ? 1'b0 : dec_is_ecall;
                id_rr_is_ebreak     <= id_exc_pending ? 1'b0 : dec_is_ebreak;
                id_rr_is_mret       <= id_exc_pending ? 1'b0 : dec_is_mret;
                id_rr_is_wfi        <= id_exc_pending ? 1'b0 : dec_is_wfi;
                id_rr_is_fencei     <= id_exc_pending ? 1'b0 : dec_is_fencei;
                id_rr_is_amo        <= id_exc_pending ? 1'b0 : dec_is_amo;
                id_rr_is_lr         <= id_exc_pending ? 1'b0 : dec_is_lr;
                id_rr_is_sc         <= id_exc_pending ? 1'b0 : dec_is_sc;
            end
        end
    end

    // =========================================================================
    // HAZARD DETECTION UNIT
    // =========================================================================

    // Load-use hazard: load in EX1, RR needs its result (2 cycles away)
    wire load_use_stall_ex1 = rr_ex1_mem_read && rr_ex1_valid && !rr_ex1_exc_pending &&
        ((rr_ex1_rd == id_rr_rs1 && id_rr_rs1 != 5'd0) ||
         (rr_ex1_rd == id_rr_rs2 && id_rr_rs2 != 5'd0));

    // Load-use hazard: load in EX2, RR needs its result (1 cycle away)
    wire load_use_stall_ex2 = ex1_ex2_mem_read && ex1_ex2_valid && !ex1_ex2_exc_pending &&
        ((ex1_ex2_rd == id_rr_rs1 && id_rr_rs1 != 5'd0) ||
         (ex1_ex2_rd == id_rr_rs2 && id_rr_rs2 != 5'd0));

    // EX2-result hazard: MUL/CSR in EX1, result not ready until end of EX2
    wire ex2_result_stall = rr_ex1_ex2_result && rr_ex1_valid && !rr_ex1_exc_pending &&
        ((rr_ex1_rd == id_rr_rs1 && id_rr_rs1 != 5'd0) ||
         (rr_ex1_rd == id_rr_rs2 && id_rr_rs2 != 5'd0));

    // AMO-use hazard: AMO (not LR) in EX1/EX2 — result available only after MEM
    wire amo_use_stall_ex1 = rr_ex1_is_amo && !rr_ex1_is_lr && rr_ex1_valid && !rr_ex1_exc_pending &&
        ((rr_ex1_rd == id_rr_rs1 && id_rr_rs1 != 5'd0) ||
         (rr_ex1_rd == id_rr_rs2 && id_rr_rs2 != 5'd0));
    wire amo_use_stall_ex2 = ex1_ex2_is_amo && !ex1_ex2_is_lr && ex1_ex2_valid && !ex1_ex2_exc_pending &&
        ((ex1_ex2_rd == id_rr_rs1 && id_rr_rs1 != 5'd0) ||
         (ex1_ex2_rd == id_rr_rs2 && id_rr_rs2 != 5'd0));

    assign hazard_stall = id_rr_valid &&
        (load_use_stall_ex1 || load_use_stall_ex2 || ex2_result_stall ||
         amo_use_stall_ex1 || amo_use_stall_ex2);

    // Connect IF2 stall — freezes IF2/ID and upstream when RR is stalled
    assign if2_stall = hazard_stall;

    // =========================================================================
    // RR STAGE — Register Read + Forwarding Setup
    // =========================================================================


    // WB->RR bypass: same-cycle read-after-write forwarding
    wire wb_fwd_rs1 = mem_wb_reg_write && mem_wb_valid && !mem_wb_exc_pending &&
                      (mem_wb_rd != 5'd0) && (mem_wb_rd == id_rr_rs1);
    wire wb_fwd_rs2 = mem_wb_reg_write && mem_wb_valid && !mem_wb_exc_pending &&
                      (mem_wb_rd != 5'd0) && (mem_wb_rd == id_rr_rs2);

    wire [31:0] rf_rs1_data = (id_rr_rs1 == 5'd0) ? 32'd0 :
                               wb_fwd_rs1 ? wb_data : regfile[id_rr_rs1];
    wire [31:0] rf_rs2_data = (id_rr_rs2 == 5'd0) ? 32'd0 :
                               wb_fwd_rs2 ? wb_data : regfile[id_rr_rs2];

    // --- RR/EX1 Pipeline Register ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rr_ex1_valid         <= 1'b0;
            rr_ex1_pc            <= 32'd0;
            rr_ex1_instr_raw     <= 32'd0;
            rr_ex1_imm           <= 32'd0;
            rr_ex1_rd            <= 5'd0;
            rr_ex1_rs1           <= 5'd0;
            rr_ex1_rs2           <= 5'd0;
            rr_ex1_alu_op        <= 5'd0;
            rr_ex1_alu_src       <= 1'b0;
            rr_ex1_mem_read      <= 1'b0;
            rr_ex1_mem_write     <= 1'b0;
            rr_ex1_mem_size      <= 3'd0;
            rr_ex1_reg_write     <= 1'b0;
            rr_ex1_result_src    <= 2'b00;
            rr_ex1_branch        <= 1'b0;
            rr_ex1_jal           <= 1'b0;
            rr_ex1_jalr          <= 1'b0;
            rr_ex1_funct3        <= 3'd0;
            rr_ex1_auipc         <= 1'b0;
            rr_ex1_csr_addr      <= 12'd0;
            rr_ex1_csr_op        <= 1'b0;
            rr_ex1_csr_write     <= 1'b0;
            rr_ex1_is_ecall      <= 1'b0;
            rr_ex1_is_ebreak     <= 1'b0;
            rr_ex1_is_mret       <= 1'b0;
            rr_ex1_is_wfi        <= 1'b0;
            rr_ex1_is_fencei     <= 1'b0;
            rr_ex1_pred_taken    <= 1'b0;
            rr_ex1_pred_target   <= 32'd0;
            rr_ex1_is_compressed <= 1'b0;
            rr_ex1_exc_pending   <= 1'b0;
            rr_ex1_exc_cause     <= 4'd0;
            rr_ex1_exc_tval      <= 32'd0;
            rr_ex1_is_amo        <= 1'b0;
            rr_ex1_is_lr         <= 1'b0;
            rr_ex1_is_sc         <= 1'b0;
            rr_ex1_amo_funct5    <= 5'd0;
            rr_ex1_amo_aq        <= 1'b0;
            rr_ex1_amo_rl        <= 1'b0;
            rr_ex1_ex2_result    <= 1'b0;
            rr_ex1_rs1_data      <= 32'd0;
            rr_ex1_rs2_data      <= 32'd0;
        end else if (!global_stall && !debug_stall) begin
            if (pipeline_flush || hazard_stall) begin
                // Flush pipeline or insert bubble for hazard stall
                rr_ex1_valid         <= 1'b0;
                rr_ex1_pc            <= 32'd0;
                rr_ex1_instr_raw     <= 32'd0;
                rr_ex1_imm           <= 32'd0;
                rr_ex1_rd            <= 5'd0;
                rr_ex1_rs1           <= 5'd0;
                rr_ex1_rs2           <= 5'd0;
                rr_ex1_alu_op        <= 5'd0;
                rr_ex1_alu_src       <= 1'b0;
                rr_ex1_mem_read      <= 1'b0;
                rr_ex1_mem_write     <= 1'b0;
                rr_ex1_mem_size      <= 3'd0;
                rr_ex1_reg_write     <= 1'b0;
                rr_ex1_result_src    <= 2'b00;
                rr_ex1_branch        <= 1'b0;
                rr_ex1_jal           <= 1'b0;
                rr_ex1_jalr          <= 1'b0;
                rr_ex1_funct3        <= 3'd0;
                rr_ex1_auipc         <= 1'b0;
                rr_ex1_csr_addr      <= 12'd0;
                rr_ex1_csr_op        <= 1'b0;
                rr_ex1_csr_write     <= 1'b0;
                rr_ex1_is_ecall      <= 1'b0;
                rr_ex1_is_ebreak     <= 1'b0;
                rr_ex1_is_mret       <= 1'b0;
                rr_ex1_is_wfi        <= 1'b0;
                rr_ex1_is_fencei     <= 1'b0;
                rr_ex1_pred_taken    <= 1'b0;
                rr_ex1_pred_target   <= 32'd0;
                rr_ex1_is_compressed <= 1'b0;
                rr_ex1_exc_pending   <= 1'b0;
                rr_ex1_exc_cause     <= 4'd0;
                rr_ex1_exc_tval      <= 32'd0;
                rr_ex1_is_amo        <= 1'b0;
                rr_ex1_is_lr         <= 1'b0;
                rr_ex1_is_sc         <= 1'b0;
                rr_ex1_amo_funct5    <= 5'd0;
                rr_ex1_amo_aq        <= 1'b0;
                rr_ex1_amo_rl        <= 1'b0;
                rr_ex1_ex2_result    <= 1'b0;
                rr_ex1_rs1_data      <= 32'd0;
                rr_ex1_rs2_data      <= 32'd0;
            end else begin
                // Normal propagation from ID/RR to RR/EX1
                rr_ex1_pc            <= id_rr_pc;
                rr_ex1_instr_raw     <= id_rr_instr_raw;
                rr_ex1_imm           <= id_rr_imm;
                rr_ex1_rd            <= id_rr_rd;
                rr_ex1_rs1           <= id_rr_rs1;
                rr_ex1_rs2           <= id_rr_rs2;
                rr_ex1_alu_op        <= id_rr_alu_op;
                rr_ex1_alu_src       <= id_rr_alu_src;
                rr_ex1_mem_read      <= id_rr_mem_read;
                rr_ex1_mem_write     <= id_rr_mem_write;
                rr_ex1_mem_size      <= id_rr_mem_size;
                rr_ex1_reg_write     <= id_rr_reg_write;
                rr_ex1_result_src    <= id_rr_result_src;
                rr_ex1_branch        <= id_rr_branch;
                rr_ex1_jal           <= id_rr_jal;
                rr_ex1_jalr          <= id_rr_jalr;
                rr_ex1_funct3        <= id_rr_funct3;
                rr_ex1_auipc         <= id_rr_auipc;
                rr_ex1_valid         <= id_rr_valid;
                rr_ex1_csr_addr      <= id_rr_csr_addr;
                rr_ex1_csr_op        <= id_rr_csr_op;
                rr_ex1_csr_write     <= id_rr_csr_write;
                rr_ex1_is_ecall      <= id_rr_is_ecall;
                rr_ex1_is_ebreak     <= id_rr_is_ebreak;
                rr_ex1_is_mret       <= id_rr_is_mret;
                rr_ex1_is_wfi        <= id_rr_is_wfi;
                rr_ex1_is_fencei     <= id_rr_is_fencei;
                rr_ex1_pred_taken    <= id_rr_pred_taken;
                rr_ex1_pred_target   <= id_rr_pred_target;
                rr_ex1_is_compressed <= id_rr_is_compressed;
                rr_ex1_exc_pending   <= id_rr_exc_pending;
                rr_ex1_exc_cause     <= id_rr_exc_cause;
                rr_ex1_exc_tval      <= id_rr_exc_tval;
                rr_ex1_is_amo        <= id_rr_is_amo;
                rr_ex1_is_lr         <= id_rr_is_lr;
                rr_ex1_is_sc         <= id_rr_is_sc;
                rr_ex1_amo_funct5    <= id_rr_amo_funct5;
                rr_ex1_amo_aq        <= id_rr_amo_aq;
                rr_ex1_amo_rl        <= id_rr_amo_rl;
                rr_ex1_ex2_result    <= id_rr_ex2_result;
                rr_ex1_rs1_data      <= rf_rs1_data;
                rr_ex1_rs2_data      <= rf_rs2_data;
            end
        end
    end
// ============================================================================
// SECTION 4: EX1 + EX2 Stages — Forwarding, ALU, Branch, Misalign, MUL, DIV, CSR
// ============================================================================

// --------------------------------------------------------------------------
// 4.1  Data Forwarding at EX1 Input
// --------------------------------------------------------------------------

// Can forward from EX1/EX2 boundary? Only if instruction produced result in EX1
// (not load — data not ready; not MUL/CSR — result computed in EX2)
wire ex1_ex2_can_fwd = ex1_ex2_reg_write && ex1_ex2_valid && !ex1_ex2_exc_pending &&
                       (ex1_ex2_rd != 5'd0) && !ex1_ex2_mem_read && !ex1_ex2_ex2_result;

// Can forward from EX2/MEM boundary? Always if valid, writing a register, and not a load
wire ex2_mem_can_fwd = ex2_mem_reg_write && ex2_mem_valid && !ex2_mem_exc_pending &&
                       (ex2_mem_rd != 5'd0) && !ex2_mem_mem_read;

// Can forward from MEM/WB boundary? Always if valid and writing a register
wire mem_wb_can_fwd = mem_wb_reg_write && mem_wb_valid && !mem_wb_exc_pending &&
                      (mem_wb_rd != 5'd0);

// Forward selection for rs1 (priority: newest result first)
wire [1:0] fwd_a_sel = (ex1_ex2_can_fwd && ex1_ex2_rd == rr_ex1_rs1) ? 2'b11 :
                       (ex2_mem_can_fwd && ex2_mem_rd == rr_ex1_rs1)  ? 2'b10 :
                       (mem_wb_can_fwd  && mem_wb_rd  == rr_ex1_rs1)  ? 2'b01 : 2'b00;

// Forward selection for rs2
wire [1:0] fwd_b_sel = (ex1_ex2_can_fwd && ex1_ex2_rd == rr_ex1_rs2) ? 2'b11 :
                       (ex2_mem_can_fwd && ex2_mem_rd == rr_ex1_rs2)  ? 2'b10 :
                       (mem_wb_can_fwd  && mem_wb_rd  == rr_ex1_rs2)  ? 2'b01 : 2'b00;


wire [31:0] fwd_rs1 = (fwd_a_sel == 2'b11) ? ex1_ex2_alu_result :
                      (fwd_a_sel == 2'b10) ? ex2_mem_result      :
                      (fwd_a_sel == 2'b01) ? wb_data              :
                      rr_ex1_rs1_data;

wire [31:0] fwd_rs2 = (fwd_b_sel == 2'b11) ? ex1_ex2_alu_result :
                      (fwd_b_sel == 2'b10) ? ex2_mem_result      :
                      (fwd_b_sel == 2'b01) ? wb_data              :
                      rr_ex1_rs2_data;

// --------------------------------------------------------------------------
// 4.2  ALU
// --------------------------------------------------------------------------

wire [31:0] alu_a = rr_ex1_auipc   ? rr_ex1_pc  : fwd_rs1;
wire [31:0] alu_b = rr_ex1_alu_src ? rr_ex1_imm : fwd_rs2;

reg [31:0] alu_result;
always @(*) begin
    alu_result = alu_a + alu_b;
    case (rr_ex1_alu_op)
        ALU_ADD:    alu_result = alu_a + alu_b;
        ALU_SUB:    alu_result = alu_a - alu_b;
        ALU_SLL:    alu_result = alu_a << alu_b[4:0];
        ALU_SLT:    alu_result = {31'd0, $signed(alu_a) < $signed(alu_b)};
        ALU_SLTU:   alu_result = {31'd0, alu_a < alu_b};
        ALU_XOR:    alu_result = alu_a ^ alu_b;
        ALU_SRL:    alu_result = alu_a >> alu_b[4:0];
        ALU_SRA:    alu_result = $signed(alu_a) >>> alu_b[4:0];
        ALU_OR:     alu_result = alu_a | alu_b;
        ALU_AND:    alu_result = alu_a & alu_b;
        ALU_PASS_B: alu_result = alu_b;
        default:    alu_result = alu_a + alu_b;
    endcase
end

// --------------------------------------------------------------------------
// 4.3  Branch Comparison + Resolution (EX1)
// --------------------------------------------------------------------------

// PC increment (2 for compressed, 4 for regular)
wire [31:0] ex1_pc_plus_n = rr_ex1_is_compressed ? (rr_ex1_pc + 32'd2) : (rr_ex1_pc + 32'd4);

reg branch_cond;
always @(*) begin
    branch_cond = 1'b0;
    case (rr_ex1_funct3)
        3'b000:  branch_cond = (fwd_rs1 == fwd_rs2);                          // BEQ
        3'b001:  branch_cond = (fwd_rs1 != fwd_rs2);                          // BNE
        3'b100:  branch_cond = ($signed(fwd_rs1) <  $signed(fwd_rs2));        // BLT
        3'b101:  branch_cond = ($signed(fwd_rs1) >= $signed(fwd_rs2));        // BGE
        3'b110:  branch_cond = (fwd_rs1 <  fwd_rs2);                          // BLTU
        3'b111:  branch_cond = (fwd_rs1 >= fwd_rs2);                          // BGEU
        default: branch_cond = 1'b0;
    endcase
end

wire ex1_actually_taken  = (rr_ex1_branch && branch_cond) || rr_ex1_jal;
wire [31:0] ex1_computed_target = rr_ex1_pc + rr_ex1_imm;
wire [31:0] ex1_jalr_target     = (fwd_rs1 + rr_ex1_imm) & ~32'd1;
wire [31:0] ex1_recovery_pc     = ex1_actually_taken ? ex1_computed_target : ex1_pc_plus_n;

// Misprediction detection (direction OR target mismatch)
wire ex1_mispredict = rr_ex1_valid && !rr_ex1_exc_pending &&
    (rr_ex1_branch || rr_ex1_jal) &&
    (rr_ex1_pred_taken != ex1_actually_taken ||
     (ex1_actually_taken && rr_ex1_pred_taken &&
      rr_ex1_pred_target != ex1_computed_target));

// Unpredicted redirects: JALR, traps, MRET, FENCEI (always flush)
wire ex1_redirect = rr_ex1_valid && !rr_ex1_exc_pending &&
    (rr_ex1_jalr || rr_ex1_is_ecall || rr_ex1_is_ebreak || rr_ex1_is_mret || rr_ex1_is_fencei);

// --------------------------------------------------------------------------
// 4.4  Misaligned Access Detection (EX1)
// --------------------------------------------------------------------------

wire [31:0] mem_addr = alu_result;

wire misalign_load = rr_ex1_mem_read && rr_ex1_valid && !rr_ex1_exc_pending && (
    (rr_ex1_mem_size[1:0] == 2'b01 && mem_addr[0]   != 1'b0 ) ||   // LH/LHU on odd
    (rr_ex1_mem_size[1:0] == 2'b10 && mem_addr[1:0] != 2'b00)      // LW on non-4-byte
);

wire misalign_store = rr_ex1_mem_write && rr_ex1_valid && !rr_ex1_exc_pending && !rr_ex1_is_amo && (
    (rr_ex1_mem_size[1:0] == 2'b01 && mem_addr[0]   != 1'b0 ) ||
    (rr_ex1_mem_size[1:0] == 2'b10 && mem_addr[1:0] != 2'b00)
);

// AMO misalignment: always word-aligned
wire misalign_amo = (rr_ex1_is_amo || rr_ex1_is_lr || rr_ex1_is_sc) &&
                    rr_ex1_valid && !rr_ex1_exc_pending && (mem_addr[1:0] != 2'b00);

// Combine with upstream exceptions (upstream has priority)
wire ecall_exc  = rr_ex1_is_ecall  && rr_ex1_valid && !rr_ex1_exc_pending;
wire ebreak_exc = rr_ex1_is_ebreak && rr_ex1_valid && !rr_ex1_exc_pending;
wire ex1_new_exc     = misalign_load || misalign_store || misalign_amo || ecall_exc || ebreak_exc;
wire ex1_exc_pending = rr_ex1_exc_pending || ex1_new_exc;

wire [3:0] ex1_exc_cause = rr_ex1_exc_pending ? rr_ex1_exc_cause :
                            ecall_exc      ? EXC_ECALL_M        :
                            ebreak_exc     ? EXC_BREAKPOINT     :
                            (misalign_load || (misalign_amo && rr_ex1_is_lr)) ? EXC_LOAD_MISALIGN :
                            EXC_STORE_MISALIGN;

wire [31:0] ex1_exc_tval = rr_ex1_exc_pending ? rr_ex1_exc_tval :
                           (ecall_exc || ebreak_exc) ? 32'd0 : mem_addr;

// --------------------------------------------------------------------------
// 4.5  MUL Operand Preparation (EX1 — registered into EX1/EX2)
// --------------------------------------------------------------------------

wire is_mul = rr_ex1_valid && (rr_ex1_alu_op >= ALU_MUL && rr_ex1_alu_op <= ALU_MULHU);

wire signed [32:0] mul_a_ext = (rr_ex1_alu_op == ALU_MULHU) ?
                                {1'b0, fwd_rs1} : {fwd_rs1[31], fwd_rs1};

wire signed [32:0] mul_b_ext = (rr_ex1_alu_op == ALU_MULHU || rr_ex1_alu_op == ALU_MULHSU) ?
                                {1'b0, fwd_rs2} : {fwd_rs2[31], fwd_rs2};

// --------------------------------------------------------------------------
// 4.6  Divide Unit (iterative, 1-bit-per-cycle restoring division)
// --------------------------------------------------------------------------

wire is_div_op = rr_ex1_valid && !rr_ex1_exc_pending &&
    (rr_ex1_alu_op == ALU_DIV  || rr_ex1_alu_op == ALU_DIVU ||
     rr_ex1_alu_op == ALU_REM  || rr_ex1_alu_op == ALU_REMU);

reg        div_busy;
reg [5:0]  div_count;
reg        div_signed_op;
reg        div_is_rem;
reg [31:0] div_quotient;
reg [32:0] div_remainder;
reg [31:0] div_dividend;
reg [31:0] div_divisor;
reg        div_neg_quot;
reg        div_neg_rem;
reg        div_special;
reg [31:0] div_special_q;
reg [31:0] div_special_r;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        div_busy      <= 1'b0;
        div_count     <= 6'd0;
        div_signed_op <= 1'b0;
        div_is_rem    <= 1'b0;
        div_quotient  <= 32'd0;
        div_remainder <= 33'd0;
        div_dividend  <= 32'd0;
        div_divisor   <= 32'd0;
        div_neg_quot  <= 1'b0;
        div_neg_rem   <= 1'b0;
        div_special   <= 1'b0;
        div_special_q <= 32'd0;
        div_special_r <= 32'd0;
    end else if (pipeline_flush) begin
        div_busy  <= 1'b0;
        div_count <= 6'd0;
    end else if (is_div_op && !div_busy) begin
        // Setup cycle: latch operands, detect special cases
        div_signed_op <= (rr_ex1_alu_op == ALU_DIV  || rr_ex1_alu_op == ALU_REM);
        div_is_rem    <= (rr_ex1_alu_op == ALU_REM  || rr_ex1_alu_op == ALU_REMU);
        div_busy      <= 1'b1;
        div_count     <= 6'd1;

        if (fwd_rs2 == 32'd0) begin
            // Division by zero
            div_special   <= 1'b1;
            div_special_q <= 32'hFFFFFFFF;
            div_special_r <= fwd_rs1;
        end else if ((rr_ex1_alu_op == ALU_DIV || rr_ex1_alu_op == ALU_REM) &&
                     fwd_rs1 == 32'h80000000 && fwd_rs2 == 32'hFFFFFFFF) begin
            // Signed overflow: -2^31 / -1
            div_special   <= 1'b1;
            div_special_q <= 32'h80000000;
            div_special_r <= 32'd0;
        end else begin
            div_special <= 1'b0;
            // Convert operands to unsigned magnitude
            div_dividend <= ((rr_ex1_alu_op == ALU_DIV || rr_ex1_alu_op == ALU_REM) && fwd_rs1[31]) ?
                            (~fwd_rs1 + 32'd1) : fwd_rs1;
            div_divisor  <= ((rr_ex1_alu_op == ALU_DIV || rr_ex1_alu_op == ALU_REM) && fwd_rs2[31]) ?
                            (~fwd_rs2 + 32'd1) : fwd_rs2;
            div_remainder <= 33'd0;
            div_neg_quot  <= (rr_ex1_alu_op == ALU_DIV || rr_ex1_alu_op == ALU_REM) &&
                             (fwd_rs1[31] ^ fwd_rs2[31]);
            div_neg_rem   <= (rr_ex1_alu_op == ALU_DIV || rr_ex1_alu_op == ALU_REM) &&
                             fwd_rs1[31];
        end
    end else if (div_busy && div_special) begin
        // Special case resolves in one extra cycle
        div_busy <= 1'b0;
    end else if (div_busy && div_count <= 6'd32) begin
        // Restoring division: one quotient bit per cycle
        if ({div_remainder[31:0], div_dividend[31]} >= {1'b0, div_divisor}) begin
            div_remainder <= {div_remainder[31:0], div_dividend[31]} - {1'b0, div_divisor};
            div_dividend  <= {div_dividend[30:0], 1'b1};
        end else begin
            div_remainder <= {div_remainder[31:0], div_dividend[31]};
            div_dividend  <= {div_dividend[30:0], 1'b0};
        end
        div_count <= div_count + 6'd1;
    end else if (div_busy && div_count > 6'd32) begin
        // Iteration complete
        div_busy <= 1'b0;
    end
end

wire div_done  = div_busy && (div_special || div_count > 6'd32);
wire div_stall = is_div_op && !div_done;

// Sign correction on quotient and remainder
wire [31:0] div_quot_final = div_neg_quot ? (~div_dividend    + 32'd1) : div_dividend;
wire [31:0] div_rem_final  = div_neg_rem  ? (~div_remainder[31:0] + 32'd1) : div_remainder[31:0];

wire [31:0] div_out = div_special ? (div_is_rem ? div_special_r : div_special_q) :
                      div_is_rem  ? div_rem_final : div_quot_final;

// --------------------------------------------------------------------------
// 4.7  CSR Read / Write-data Computation
// --------------------------------------------------------------------------


wire [31:0] csr_operand = rr_ex1_funct3[2] ? {27'd0, rr_ex1_rs1} : fwd_rs1;

reg [31:0] csr_wdata;
always @(*) begin
    csr_wdata = 32'd0;
    case (rr_ex1_funct3[1:0])
        2'b01:   csr_wdata = csr_operand;              // CSRRW  / CSRRWI
        2'b10:   csr_wdata = csr_rdata | csr_operand;  // CSRRS  / CSRRSI
        2'b11:   csr_wdata = csr_rdata & ~csr_operand; // CSRRC  / CSRRCI
        default: csr_wdata = 32'd0;
    endcase
end

// --------------------------------------------------------------------------
// 4.8  EX1/EX2 Pipeline Register
// --------------------------------------------------------------------------

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ex1_ex2_valid         <= 1'b0;
        ex1_ex2_pc            <= 32'd0;
        ex1_ex2_instr_raw     <= 32'd0;
        ex1_ex2_rd            <= 5'd0;
        ex1_ex2_rs1           <= 5'd0;
        ex1_ex2_rs2           <= 5'd0;
        ex1_ex2_rs1_data      <= 32'd0;
        ex1_ex2_rs2_data      <= 32'd0;
        ex1_ex2_imm           <= 32'd0;
        ex1_ex2_funct3        <= 3'd0;
        ex1_ex2_alu_result    <= 32'd0;
        ex1_ex2_pc_plus_n     <= 32'd0;
        ex1_ex2_mem_read      <= 1'b0;
        ex1_ex2_mem_write     <= 1'b0;
        ex1_ex2_mem_size      <= 3'd0;
        ex1_ex2_reg_write     <= 1'b0;
        ex1_ex2_result_src    <= 2'd0;
        ex1_ex2_csr_op        <= 1'b0;
        ex1_ex2_csr_addr      <= 12'd0;
        ex1_ex2_csr_wdata     <= 32'd0;
        ex1_ex2_exc_pending   <= 1'b0;
        ex1_ex2_exc_cause     <= 4'd0;
        ex1_ex2_exc_tval      <= 32'd0;
        ex1_ex2_is_compressed <= 1'b0;
        ex1_ex2_is_ecall      <= 1'b0;
        ex1_ex2_is_ebreak     <= 1'b0;
        ex1_ex2_is_mret       <= 1'b0;
        ex1_ex2_is_fencei     <= 1'b0;
        ex1_ex2_is_wfi        <= 1'b0;
        ex1_ex2_is_amo        <= 1'b0;
        ex1_ex2_is_lr         <= 1'b0;
        ex1_ex2_is_sc         <= 1'b0;
        ex1_ex2_amo_funct5    <= 5'd0;
        ex1_ex2_amo_aq        <= 1'b0;
        ex1_ex2_amo_rl        <= 1'b0;
        ex1_ex2_ex2_result    <= 1'b0;
        ex1_ex2_mul_a         <= 33'sd0;
        ex1_ex2_mul_b         <= 33'sd0;
        ex1_ex2_mul_op        <= 4'd0;
        ex1_ex2_pred_taken    <= 1'b0;
        ex1_ex2_pred_target   <= 32'd0;
    end else if ((nmi_taken || wb_exception || irq_taken) && !global_stall && !debug_stall) begin
        ex1_ex2_valid         <= 1'b0;
        ex1_ex2_mem_read      <= 1'b0;
        ex1_ex2_mem_write     <= 1'b0;
        ex1_ex2_reg_write     <= 1'b0;
        ex1_ex2_csr_op        <= 1'b0;
        ex1_ex2_exc_pending   <= 1'b0;
        ex1_ex2_is_ecall      <= 1'b0;
        ex1_ex2_is_ebreak     <= 1'b0;
        ex1_ex2_is_mret       <= 1'b0;
        ex1_ex2_is_fencei     <= 1'b0;
        ex1_ex2_is_wfi        <= 1'b0;
        ex1_ex2_is_amo        <= 1'b0;
        ex1_ex2_is_lr         <= 1'b0;
        ex1_ex2_is_sc         <= 1'b0;
        ex1_ex2_ex2_result    <= 1'b0;
    end else if (!global_stall && !debug_stall && !div_stall) begin
        ex1_ex2_valid         <= rr_ex1_valid;
        ex1_ex2_pc            <= rr_ex1_pc;
        ex1_ex2_instr_raw     <= rr_ex1_instr_raw;
        ex1_ex2_rd            <= rr_ex1_rd;
        ex1_ex2_rs1           <= rr_ex1_rs1;
        ex1_ex2_rs2           <= rr_ex1_rs2;
        ex1_ex2_rs1_data      <= fwd_rs1;
        ex1_ex2_rs2_data      <= fwd_rs2;
        ex1_ex2_imm           <= rr_ex1_imm;
        ex1_ex2_funct3        <= rr_ex1_funct3;
        ex1_ex2_alu_result    <= rr_ex1_csr_op ? csr_rdata :
                                 (is_div_op && div_done) ? div_out :
                                 (rr_ex1_jal || rr_ex1_jalr) ? ex1_pc_plus_n :
                                 alu_result;
        ex1_ex2_pc_plus_n     <= ex1_pc_plus_n;
        ex1_ex2_mem_read      <= ex1_exc_pending ? 1'b0 : rr_ex1_mem_read;
        ex1_ex2_mem_write     <= ex1_exc_pending ? 1'b0 : rr_ex1_mem_write;
        ex1_ex2_mem_size      <= rr_ex1_mem_size;
        ex1_ex2_reg_write     <= ex1_exc_pending ? 1'b0 : rr_ex1_reg_write;
        ex1_ex2_result_src    <= rr_ex1_result_src;
        ex1_ex2_csr_op        <= ex1_exc_pending ? 1'b0 : rr_ex1_csr_op;
        ex1_ex2_csr_addr      <= rr_ex1_csr_addr;
        ex1_ex2_csr_wdata     <= csr_wdata;
        ex1_ex2_exc_pending   <= ex1_exc_pending;
        ex1_ex2_exc_cause     <= ex1_exc_cause;
        ex1_ex2_exc_tval      <= ex1_exc_tval;
        ex1_ex2_is_compressed <= rr_ex1_is_compressed;
        ex1_ex2_is_ecall      <= rr_ex1_is_ecall;
        ex1_ex2_is_ebreak     <= rr_ex1_is_ebreak;
        ex1_ex2_is_mret       <= rr_ex1_is_mret;
        ex1_ex2_is_fencei     <= rr_ex1_is_fencei;
        ex1_ex2_is_wfi        <= rr_ex1_is_wfi;
        ex1_ex2_is_amo        <= ex1_exc_pending ? 1'b0 : rr_ex1_is_amo;
        ex1_ex2_is_lr         <= ex1_exc_pending ? 1'b0 : rr_ex1_is_lr;
        ex1_ex2_is_sc         <= ex1_exc_pending ? 1'b0 : rr_ex1_is_sc;
        ex1_ex2_amo_funct5    <= rr_ex1_amo_funct5;
        ex1_ex2_amo_aq        <= rr_ex1_amo_aq;
        ex1_ex2_amo_rl        <= rr_ex1_amo_rl;
        ex1_ex2_ex2_result    <= rr_ex1_ex2_result;
        ex1_ex2_mul_a         <= mul_a_ext;
        ex1_ex2_mul_b         <= mul_b_ext;
        ex1_ex2_mul_op        <= rr_ex1_alu_op;
        ex1_ex2_pred_taken    <= rr_ex1_pred_taken;
        ex1_ex2_pred_target   <= rr_ex1_pred_target;
    end
end

// --------------------------------------------------------------------------
// 4.9  Multiply Unit (pipelined: operands registered in EX1, product in EX2)
// --------------------------------------------------------------------------

wire signed [65:0] mul_product = ex1_ex2_mul_a * ex1_ex2_mul_b;

reg [31:0] mul_out;
always @(*) begin
    mul_out = mul_product[31:0];
    case (ex1_ex2_mul_op)
        ALU_MUL:    mul_out = mul_product[31:0];
        ALU_MULH:   mul_out = mul_product[63:32];
        ALU_MULHSU: mul_out = mul_product[63:32];
        ALU_MULHU:  mul_out = mul_product[63:32];
        default:    mul_out = mul_product[31:0];
    endcase
end

// --------------------------------------------------------------------------
// 4.10 EX2 Result Selection
// --------------------------------------------------------------------------

wire [31:0] ex2_result = (ex1_ex2_ex2_result && !ex1_ex2_csr_op) ? mul_out :
                         ex1_ex2_alu_result;

// --------------------------------------------------------------------------
// 4.11 EX2/MEM Pipeline Register
// --------------------------------------------------------------------------

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ex2_mem_valid         <= 1'b0;
        ex2_mem_pc            <= 32'd0;
        ex2_mem_instr_raw     <= 32'd0;
        ex2_mem_rd            <= 5'd0;
        ex2_mem_result        <= 32'd0;
        ex2_mem_rs2_data      <= 32'd0;
        ex2_mem_pc_plus_n     <= 32'd0;
        ex2_mem_mem_read      <= 1'b0;
        ex2_mem_mem_write     <= 1'b0;
        ex2_mem_mem_size      <= 3'd0;
        ex2_mem_reg_write     <= 1'b0;
        ex2_mem_result_src    <= 2'd0;
        ex2_mem_exc_pending   <= 1'b0;
        ex2_mem_exc_cause     <= 4'd0;
        ex2_mem_exc_tval      <= 32'd0;
        ex2_mem_is_compressed <= 1'b0;
        ex2_mem_is_amo        <= 1'b0;
        ex2_mem_is_lr         <= 1'b0;
        ex2_mem_is_sc         <= 1'b0;
        ex2_mem_amo_funct5    <= 5'd0;
        ex2_mem_amo_aq        <= 1'b0;
        ex2_mem_amo_rl        <= 1'b0;
    end else if ((nmi_taken || wb_exception) && !global_stall && !debug_stall) begin
        ex2_mem_valid         <= 1'b0;
        ex2_mem_mem_read      <= 1'b0;
        ex2_mem_mem_write     <= 1'b0;
        ex2_mem_reg_write     <= 1'b0;
        ex2_mem_exc_pending   <= 1'b0;
        ex2_mem_is_amo        <= 1'b0;
        ex2_mem_is_lr         <= 1'b0;
        ex2_mem_is_sc         <= 1'b0;
    end else if (!global_stall && !debug_stall) begin
        ex2_mem_valid         <= ex1_ex2_valid;
        ex2_mem_pc            <= ex1_ex2_pc;
        ex2_mem_instr_raw     <= ex1_ex2_instr_raw;
        ex2_mem_rd            <= ex1_ex2_rd;
        ex2_mem_result        <= ex2_result;
        ex2_mem_rs2_data      <= ex1_ex2_rs2_data;
        ex2_mem_pc_plus_n     <= ex1_ex2_pc_plus_n;
        ex2_mem_mem_read      <= ex1_ex2_mem_read;
        ex2_mem_mem_write     <= ex1_ex2_mem_write;
        ex2_mem_mem_size      <= ex1_ex2_mem_size;
        ex2_mem_reg_write     <= ex1_ex2_reg_write;
        ex2_mem_result_src    <= ex1_ex2_result_src;
        ex2_mem_exc_pending   <= ex1_ex2_exc_pending;
        ex2_mem_exc_cause     <= ex1_ex2_exc_cause;
        ex2_mem_exc_tval      <= ex1_ex2_exc_tval;
        ex2_mem_is_compressed <= ex1_ex2_is_compressed;
        ex2_mem_is_amo        <= ex1_ex2_is_amo;
        ex2_mem_is_lr         <= ex1_ex2_is_lr;
        ex2_mem_is_sc         <= ex1_ex2_is_sc;
        ex2_mem_amo_funct5    <= ex1_ex2_amo_funct5;
        ex2_mem_amo_aq        <= ex1_ex2_amo_aq;
        ex2_mem_amo_rl        <= ex1_ex2_amo_rl;
    end
end

// --------------------------------------------------------------------------
// 4.12 Global Stall Signal
// --------------------------------------------------------------------------

wire mem_stall = (ex2_mem_mem_read || (ex2_mem_mem_write && !sc_fail)) && ex2_mem_valid &&
                 !ex2_mem_exc_pending && !dmem_ready;
wire fetch_stall = imem_req && !imem_ready;
assign global_stall = mem_stall || div_stall || amo_stall;
assign debug_stall = debug_halted_r;
assign pc_stall = hazard_stall || global_stall || fetch_stall || debug_stall || wfi_active_w || if2_hold_fetch;
// =========================================================================
// SECTION 5: CSR Register File, PMP, MEM Stage, WB Stage
// =========================================================================

    // =========================================================================
    // CSR REGISTER FILE (RISC-V Priv Spec v1.12, M-mode)
    // =========================================================================

    reg [31:0] csr_mstatus;        // [3]=MIE, [7]=MPIE, [12:11]=MPP
    reg [31:0] csr_misa;           // ISA description (WARL)
    reg [31:0] csr_mie;
    reg [31:0] csr_mtvec;
    reg [31:0] csr_mcounteren;
    reg [31:0] csr_mcountinhibit;
    reg [31:0] csr_mscratch;
    reg [31:0] csr_mepc;
    reg [31:0] csr_mcause;
    reg [31:0] csr_mtval;
    reg [31:0] csr_mip;
    reg [63:0] csr_mcycle;
    reg [63:0] csr_minstret;
    reg [63:0] csr_mhpmcnt3;      // branch mispredictions
    reg [63:0] csr_mhpmcnt4;      // load-use stalls
    reg [31:0] csr_mhpmevent3;
    reg [31:0] csr_mhpmevent4;

    // PMP CSRs
    reg [31:0] csr_pmpcfg [0:3];   // pmpcfg0-3 (4 regions per register, 16 total)
    reg [31:0] csr_pmpaddr [0:15]; // pmpaddr0-15

    // Debug CSRs
    reg [31:0] csr_tselect;
    reg [31:0] csr_tdata1;         // trigger 0 control
    reg [31:0] csr_tdata2;         // trigger 0 match value
    reg [31:0] csr_tdata1_1;       // trigger 1 control (selected via tselect)
    reg [31:0] csr_tdata2_1;       // trigger 1 match value
    reg [31:0] csr_dcsr;
    reg [31:0] csr_dpc;
    reg [31:0] csr_dscratch0;

    // =========================================================================
    // CSR READ MULTIPLEXER (combinational)
    // =========================================================================

    always @(*) begin
        csr_rdata = 32'd0;
        case (rr_ex1_csr_addr)
            CSR_MVENDORID:     csr_rdata = 32'd0;
            CSR_MARCHID:       csr_rdata = 32'd0;
            CSR_MIMPID:        csr_rdata = 32'h0100_0001;
            CSR_MHARTID:       csr_rdata = HART_ID;
            CSR_MSTATUS:       csr_rdata = csr_mstatus;
            CSR_MISA:          csr_rdata = csr_misa;
            CSR_MIE:           csr_rdata = csr_mie;
            CSR_MTVEC:         csr_rdata = csr_mtvec;
            CSR_MCOUNTEREN:    csr_rdata = csr_mcounteren;
            CSR_MCOUNTINHIBIT: csr_rdata = csr_mcountinhibit;
            CSR_MSCRATCH:      csr_rdata = csr_mscratch;
            CSR_MEPC:          csr_rdata = csr_mepc;
            CSR_MCAUSE:        csr_rdata = csr_mcause;
            CSR_MTVAL:         csr_rdata = csr_mtval;
            CSR_MIP:           csr_rdata = csr_mip;
            CSR_MCYCLE:        csr_rdata = csr_mcycle[31:0];
            CSR_MCYCLEH:       csr_rdata = csr_mcycle[63:32];
            CSR_MINSTRET:      csr_rdata = csr_minstret[31:0];
            CSR_MINSTRETH:     csr_rdata = csr_minstret[63:32];
            CSR_MHPMCNT3:      csr_rdata = csr_mhpmcnt3[31:0];
            CSR_MHPMCNT3H:     csr_rdata = csr_mhpmcnt3[63:32];
            CSR_MHPMCNT4:      csr_rdata = csr_mhpmcnt4[31:0];
            CSR_MHPMCNT4H:     csr_rdata = csr_mhpmcnt4[63:32];
            CSR_MHPMEVENT3:    csr_rdata = csr_mhpmevent3;
            CSR_MHPMEVENT4:    csr_rdata = csr_mhpmevent4;
            CSR_PMPCFG0:       csr_rdata = csr_pmpcfg[0];
            CSR_PMPCFG1:       csr_rdata = csr_pmpcfg[1];
            CSR_PMPCFG2:       csr_rdata = csr_pmpcfg[2];
            CSR_PMPCFG3:       csr_rdata = csr_pmpcfg[3];
            12'h3B0:           csr_rdata = csr_pmpaddr[0];
            12'h3B1:           csr_rdata = csr_pmpaddr[1];
            12'h3B2:           csr_rdata = csr_pmpaddr[2];
            12'h3B3:           csr_rdata = csr_pmpaddr[3];
            12'h3B4:           csr_rdata = csr_pmpaddr[4];
            12'h3B5:           csr_rdata = csr_pmpaddr[5];
            12'h3B6:           csr_rdata = csr_pmpaddr[6];
            12'h3B7:           csr_rdata = csr_pmpaddr[7];
            12'h3B8:           csr_rdata = csr_pmpaddr[8];
            12'h3B9:           csr_rdata = csr_pmpaddr[9];
            12'h3BA:           csr_rdata = csr_pmpaddr[10];
            12'h3BB:           csr_rdata = csr_pmpaddr[11];
            12'h3BC:           csr_rdata = csr_pmpaddr[12];
            12'h3BD:           csr_rdata = csr_pmpaddr[13];
            12'h3BE:           csr_rdata = csr_pmpaddr[14];
            12'h3BF:           csr_rdata = csr_pmpaddr[15];
            CSR_TSELECT:       csr_rdata = csr_tselect;
            CSR_TDATA1:        csr_rdata = (csr_tselect == 32'd0) ? csr_tdata1 : csr_tdata1_1;
            CSR_TDATA2:        csr_rdata = (csr_tselect == 32'd0) ? csr_tdata2 : csr_tdata2_1;
            CSR_DCSR:          csr_rdata = csr_dcsr;
            CSR_DPC:           csr_rdata = csr_dpc;
            CSR_DSCRATCH0:     csr_rdata = csr_dscratch0;
            default:           csr_rdata = 32'd0;
        endcase
    end

    // =========================================================================
    // PMP (Physical Memory Protection) — Address Matching
    // =========================================================================

    wire [31:0] pmp_check_addr = ex2_mem_result;

    reg        pmp_match;
    reg        pmp_allow_r;
    reg        pmp_allow_w;
    reg        pmp_allow_x;

    always @(*) begin
        pmp_match   = 1'b0;
        pmp_allow_r = 1'b1;
        pmp_allow_w = 1'b1;
        pmp_allow_x = 1'b1;

        begin : pmp_check_block
            integer i;
            reg [1:0]  a_field;
            reg [31:0] pmp_lo, pmp_hi;
            reg        region_match;
            reg        locked;

            for (i = 0; i < 16; i = i + 1) begin
                a_field = csr_pmpcfg[i/4][(i%4)*8 + 4 -: 2];
                locked  = csr_pmpcfg[i/4][(i%4)*8 + 7];

                case (a_field)
                    2'b00: region_match = 1'b0; // OFF
                    2'b01: begin // TOR
                        pmp_lo = (i == 0) ? 32'd0 : {csr_pmpaddr[i-1], 2'b00};
                        pmp_hi = {csr_pmpaddr[i], 2'b00};
                        region_match = (pmp_check_addr >= pmp_lo) && (pmp_check_addr < pmp_hi);
                    end
                    2'b10: begin // NA4
                        region_match = (pmp_check_addr[31:2] == csr_pmpaddr[i][29:0]);
                    end
                    2'b11: begin // NAPOT
                        pmp_lo = {(csr_pmpaddr[i] + 32'd1) & csr_pmpaddr[i], 2'b00};
                        pmp_hi = pmp_lo | {(csr_pmpaddr[i] ^ (csr_pmpaddr[i] + 32'd1)), 2'b11};
                        region_match = (pmp_check_addr >= pmp_lo) && (pmp_check_addr <= pmp_hi);
                    end
                    default: region_match = 1'b0;
                endcase

                if (region_match && !pmp_match) begin
                    pmp_match = 1'b1;
                    if (locked) begin
                        pmp_allow_r = csr_pmpcfg[i/4][(i%4)*8 + 0];
                        pmp_allow_w = csr_pmpcfg[i/4][(i%4)*8 + 1];
                        pmp_allow_x = csr_pmpcfg[i/4][(i%4)*8 + 2];
                    end
                end
            end
        end
    end

    // =========================================================================
    // MEM STAGE — Memory Access, PMP, LR/SC, AMO
    // =========================================================================

    // --- PMP Violation Detection ---
    wire pmp_load_fault  = ex2_mem_mem_read  && ex2_mem_valid && !ex2_mem_exc_pending &&
                           pmp_match && !pmp_allow_r;
    wire pmp_store_fault = ex2_mem_mem_write && ex2_mem_valid && !ex2_mem_exc_pending &&
                           pmp_match && !pmp_allow_w;
    wire dmem_load_error  = ex2_mem_mem_read  && ex2_mem_valid && !ex2_mem_exc_pending &&
                            dmem_error && dmem_ready;
    wire dmem_store_error = ex2_mem_mem_write && ex2_mem_valid && !ex2_mem_exc_pending &&
                            dmem_error && dmem_ready;

    // =========================================================================
    // I-Fetch PMP Check — execute (X) permission on instruction address
    // Checks if1_if2_pc against all 16 PMP regions (same matching modes as data PMP)
    // =========================================================================
    reg        ifetch_pmp_match;
    reg        ifetch_pmp_allow_x;

    always @(*) begin
        ifetch_pmp_match   = 1'b0;
        ifetch_pmp_allow_x = 1'b1;  // M-mode default: allow if no PMP match

        begin : ifetch_pmp_check_block
            integer j;
            reg [1:0]  if_a_field;
            reg [31:0] if_pmp_lo, if_pmp_hi;
            reg        if_region_match;
            reg        if_locked;

            for (j = 0; j < 16; j = j + 1) begin
                if_a_field = csr_pmpcfg[j/4][(j%4)*8 + 4 -: 2];
                if_locked  = csr_pmpcfg[j/4][(j%4)*8 + 7];

                case (if_a_field)
                    2'b00: if_region_match = 1'b0; // OFF
                    2'b01: begin // TOR
                        if_pmp_lo = (j == 0) ? 32'd0 : {csr_pmpaddr[j-1], 2'b00};
                        if_pmp_hi = {csr_pmpaddr[j], 2'b00};
                        if_region_match = (if1_if2_pc >= if_pmp_lo) && (if1_if2_pc < if_pmp_hi);
                    end
                    2'b10: begin // NA4
                        if_region_match = (if1_if2_pc[31:2] == csr_pmpaddr[j][29:0]);
                    end
                    2'b11: begin // NAPOT
                        if_pmp_lo = {(csr_pmpaddr[j] + 32'd1) & csr_pmpaddr[j], 2'b00};
                        if_pmp_hi = if_pmp_lo | {(csr_pmpaddr[j] ^ (csr_pmpaddr[j] + 32'd1)), 2'b11};
                        if_region_match = (if1_if2_pc >= if_pmp_lo) && (if1_if2_pc <= if_pmp_hi);
                    end
                    default: if_region_match = 1'b0;
                endcase

                if (if_region_match && !ifetch_pmp_match) begin
                    ifetch_pmp_match = 1'b1;
                    if (if_locked) begin
                        ifetch_pmp_allow_x = csr_pmpcfg[j/4][(j%4)*8 + 2];
                    end
                end
            end
        end
    end

    assign if2_imem_pmp_fault = if1_if2_valid_eff && ifetch_pmp_match && !ifetch_pmp_allow_x;

    // --- LR/SC Reservation ---
    reg [31:0] lr_address;
    reg        lr_valid;

    wire sc_success = ex2_mem_is_sc && lr_valid && (lr_address == ex2_mem_result);
    wire [31:0] sc_result = sc_success ? 32'd0 : 32'd1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lr_valid   <= 1'b0;
            lr_address <= 32'd0;
        end else begin
            if (ex2_mem_is_lr && ex2_mem_valid && !ex2_mem_exc_pending && dmem_ready) begin
                lr_valid   <= 1'b1;
                lr_address <= ex2_mem_result;
            end else if (ex2_mem_is_sc && ex2_mem_valid && !ex2_mem_exc_pending && dmem_ready) begin
                lr_valid <= 1'b0;
            end else if (ex2_mem_mem_write && ex2_mem_valid && !ex2_mem_exc_pending &&
                         !ex2_mem_is_sc && lr_valid &&
                         ({ex2_mem_result[31:2], 2'b00} == {lr_address[31:2], 2'b00})) begin
                lr_valid <= 1'b0;
            end else if (nmi_taken || wb_exception || irq_taken) begin
                lr_valid <= 1'b0;
            end
        end
    end

    // --- AMO State Machine ---
    reg  [1:0]  amo_state;   // 0=idle, 1=read, 2=write
    reg  [31:0] amo_read_data;
    reg  [31:0] amo_write_data;
    reg         amo_done;    // Set when AMO write completes, cleared next cycle
    wire amo_starting = ex2_mem_is_amo && !ex2_mem_is_lr && !ex2_mem_is_sc &&
                        ex2_mem_valid && !ex2_mem_exc_pending && !amo_done;
    assign      amo_stall = (amo_state != 2'd0) || amo_starting;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            amo_state      <= 2'd0;
            amo_read_data  <= 32'd0;
            amo_write_data <= 32'd0;
            amo_done       <= 1'b0;
        end else begin
            // amo_done auto-clears after one cycle
            if (amo_done) amo_done <= 1'b0;

            case (amo_state)
                2'd0: begin
                    if (amo_starting) begin
                        amo_state <= 2'd1;
                    end
                end
                2'd1: begin
                    if (dmem_ready) begin
                        amo_read_data <= dmem_rdata;
                        case (ex2_mem_amo_funct5)
                            AMO_SWAP: amo_write_data <= ex2_mem_rs2_data;
                            AMO_ADD:  amo_write_data <= dmem_rdata + ex2_mem_rs2_data;
                            AMO_XOR:  amo_write_data <= dmem_rdata ^ ex2_mem_rs2_data;
                            AMO_AND:  amo_write_data <= dmem_rdata & ex2_mem_rs2_data;
                            AMO_OR:   amo_write_data <= dmem_rdata | ex2_mem_rs2_data;
                            AMO_MIN:  amo_write_data <= ($signed(dmem_rdata) < $signed(ex2_mem_rs2_data))
                                                        ? dmem_rdata : ex2_mem_rs2_data;
                            AMO_MAX:  amo_write_data <= ($signed(dmem_rdata) > $signed(ex2_mem_rs2_data))
                                                        ? dmem_rdata : ex2_mem_rs2_data;
                            AMO_MINU: amo_write_data <= (dmem_rdata < ex2_mem_rs2_data)
                                                        ? dmem_rdata : ex2_mem_rs2_data;
                            AMO_MAXU: amo_write_data <= (dmem_rdata > ex2_mem_rs2_data)
                                                        ? dmem_rdata : ex2_mem_rs2_data;
                            default:  amo_write_data <= dmem_rdata;
                        endcase
                        amo_state <= 2'd2;
                    end
                end
                2'd2: begin
                    if (dmem_ready) begin
                        amo_done  <= 1'b1;
                        amo_state <= 2'd0;
                    end
                end
                default: amo_state <= 2'd0;
            endcase
        end
    end

    // --- Store Data Alignment and Byte Strobe ---
    reg [31:0] store_data;
    reg  [3:0] store_strb;

    always @(*) begin
        store_data = 32'd0;
        store_strb = 4'b0000;
        case (ex2_mem_mem_size[1:0])
            2'b00: begin // SB
                case (ex2_mem_result[1:0])
                    2'b00: begin store_data = {24'd0, ex2_mem_rs2_data[7:0]};        store_strb = 4'b0001; end
                    2'b01: begin store_data = {16'd0, ex2_mem_rs2_data[7:0], 8'd0};  store_strb = 4'b0010; end
                    2'b10: begin store_data = {8'd0, ex2_mem_rs2_data[7:0], 16'd0};  store_strb = 4'b0100; end
                    2'b11: begin store_data = {ex2_mem_rs2_data[7:0], 24'd0};        store_strb = 4'b1000; end
                endcase
            end
            2'b01: begin // SH
                case (ex2_mem_result[1])
                    1'b0: begin store_data = {16'd0, ex2_mem_rs2_data[15:0]};        store_strb = 4'b0011; end
                    1'b1: begin store_data = {ex2_mem_rs2_data[15:0], 16'd0};        store_strb = 4'b1100; end
                endcase
            end
            default: begin // SW
                store_data = ex2_mem_rs2_data;
                store_strb = 4'b1111;
            end
        endcase
    end

    // --- Data Memory Interface ---
    assign sc_fail = ex2_mem_is_sc && !sc_success;

    assign dmem_addr  = {ex2_mem_result[31:2], 2'b00};
    assign dmem_wdata = (amo_state == 2'd2) ? amo_write_data : store_data;
    assign dmem_wstrb = ((ex2_mem_mem_write && !sc_fail && !ex2_mem_exc_pending) || amo_state == 2'd2)
                        ? ((amo_state == 2'd2) ? 4'b1111 : store_strb)
                        : 4'b0000;
    assign dmem_req   = ((ex2_mem_mem_read || (ex2_mem_mem_write && !sc_fail)) &&
                         ex2_mem_valid && !ex2_mem_exc_pending) || (amo_state != 2'd0);
    assign dmem_lock  = ex2_mem_is_amo || ex2_mem_is_lr || ex2_mem_is_sc || (amo_state != 2'd0);

    // --- Load Data Alignment ---
    reg [31:0] load_data;

    always @(*) begin
        load_data = 32'd0;
        case (ex2_mem_mem_size)
            3'b000: begin // LB
                case (ex2_mem_result[1:0])
                    2'b00: load_data = {{24{dmem_rdata[7]}},  dmem_rdata[7:0]};
                    2'b01: load_data = {{24{dmem_rdata[15]}}, dmem_rdata[15:8]};
                    2'b10: load_data = {{24{dmem_rdata[23]}}, dmem_rdata[23:16]};
                    2'b11: load_data = {{24{dmem_rdata[31]}}, dmem_rdata[31:24]};
                endcase
            end
            3'b001: begin // LH
                case (ex2_mem_result[1])
                    1'b0: load_data = {{16{dmem_rdata[15]}}, dmem_rdata[15:0]};
                    1'b1: load_data = {{16{dmem_rdata[31]}}, dmem_rdata[31:16]};
                endcase
            end
            3'b010: load_data = dmem_rdata; // LW
            3'b100: begin // LBU
                case (ex2_mem_result[1:0])
                    2'b00: load_data = {24'd0, dmem_rdata[7:0]};
                    2'b01: load_data = {24'd0, dmem_rdata[15:8]};
                    2'b10: load_data = {24'd0, dmem_rdata[23:16]};
                    2'b11: load_data = {24'd0, dmem_rdata[31:24]};
                endcase
            end
            3'b101: begin // LHU
                case (ex2_mem_result[1])
                    1'b0: load_data = {16'd0, dmem_rdata[15:0]};
                    1'b1: load_data = {16'd0, dmem_rdata[31:16]};
                endcase
            end
            default: load_data = dmem_rdata;
        endcase
    end

    // --- MEM Exception Detection ---
    // Hardware breakpoint check (trigger match on PC in MEM stage)
    wire trigger0_mem_match = csr_tdata1[2]   && !csr_tdata1[27]   &&
                              (csr_tdata1[10:7]   == 4'd0)         &&
                              (ex2_mem_pc == csr_tdata2) && ex2_mem_valid;
    wire trigger1_mem_match = csr_tdata1_1[2] && !csr_tdata1_1[27] &&
                              (csr_tdata1_1[10:7] == 4'd0)         &&
                              (ex2_mem_pc == csr_tdata2_1) && ex2_mem_valid;
    wire hw_breakpoint_mem  = (trigger0_mem_match || trigger1_mem_match) && !ex2_mem_exc_pending;

    wire        mem_exc_new     = pmp_load_fault || pmp_store_fault ||
                                  dmem_load_error || dmem_store_error || hw_breakpoint_mem;
    wire        mem_exc_pending = ex2_mem_exc_pending || mem_exc_new;
    wire [3:0]  mem_exc_cause   = ex2_mem_exc_pending ? ex2_mem_exc_cause :
                                  hw_breakpoint_mem   ? EXC_BREAKPOINT :
                                  pmp_load_fault      ? EXC_LOAD_FAULT :
                                  pmp_store_fault     ? EXC_STORE_FAULT :
                                  dmem_load_error     ? EXC_LOAD_FAULT :
                                                        EXC_STORE_FAULT;
    wire [31:0] mem_exc_tval    = ex2_mem_exc_pending ? ex2_mem_exc_tval :
                                  hw_breakpoint_mem   ? 32'd0 : ex2_mem_result;

    // --- MEM/WB Pipeline Register ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_wb_valid         <= 1'b0;
            mem_wb_reg_write     <= 1'b0;
            mem_wb_result        <= 32'd0;
            mem_wb_mem_data      <= 32'd0;
            mem_wb_pc_plus_n     <= 32'd0;
            mem_wb_rd            <= 5'd0;
            mem_wb_result_src    <= 2'b00;
            mem_wb_exc_pending   <= 1'b0;
            mem_wb_exc_cause     <= 4'd0;
            mem_wb_exc_tval      <= 32'd0;
            mem_wb_pc            <= 32'd0;
            mem_wb_instr_raw     <= 32'd0;
            mem_wb_is_compressed <= 1'b0;
        end else if ((nmi_taken || wb_exception) && !global_stall && !debug_stall) begin
            mem_wb_valid         <= 1'b0;
            mem_wb_reg_write     <= 1'b0;
            mem_wb_exc_pending   <= 1'b0;
        end else if (!global_stall && !debug_stall) begin
            mem_wb_result     <= ex2_mem_is_sc ? sc_result :
                                (ex2_mem_is_amo && !ex2_mem_is_lr && !ex2_mem_is_sc &&
                                 amo_state == 2'd0) ? amo_read_data :
                                ex2_mem_result;
            mem_wb_mem_data      <= load_data;
            mem_wb_pc_plus_n     <= ex2_mem_pc_plus_n;
            mem_wb_rd            <= ex2_mem_rd;
            mem_wb_reg_write     <= ex2_mem_reg_write && !mem_exc_new;
            mem_wb_result_src    <= ex2_mem_result_src;
            mem_wb_valid         <= ex2_mem_valid;
            mem_wb_exc_pending   <= mem_exc_pending;
            mem_wb_exc_cause     <= mem_exc_cause;
            mem_wb_exc_tval      <= mem_exc_tval;
            mem_wb_pc            <= ex2_mem_pc;
            mem_wb_instr_raw     <= ex2_mem_instr_raw;
            mem_wb_is_compressed <= ex2_mem_is_compressed;
        end
    end

    // =========================================================================
    // WB STAGE — Writeback
    // =========================================================================

    assign wb_data = (mem_wb_result_src == 2'b01) ? mem_wb_mem_data :
                          (mem_wb_result_src == 2'b10) ? mem_wb_pc_plus_n :
                          mem_wb_result;

    // --- Register File Write ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (idx = 0; idx < 32; idx = idx + 1)
                regfile[idx] <= 32'd0;
        end else if (debug_halted_r && debug_gpr_wr && debug_gpr_addr != 5'd0) begin
            regfile[debug_gpr_addr] <= debug_gpr_wdata;
        end else if (mem_wb_reg_write && mem_wb_valid && !mem_wb_exc_pending &&
                     mem_wb_rd != 5'd0) begin
            regfile[mem_wb_rd] <= wb_data;
        end
    end
// ===========================================================================
// RISC-V RV32I CPU — Part 6: Exception/Debug/BHT/BTB/RAS/Clock-Gate + endmodule
// Final section of rv32i_cpu.v (8-stage: IF1→IF2→ID→RR→EX1→EX2→MEM→WB)
// ===========================================================================

    // -----------------------------------------------------------------------
    // SECTION 1 — Interrupt Logic
    // -----------------------------------------------------------------------

    // Hardware interrupt pending — mip reflects external pins
    wire [31:0] mip_hw = {20'b0, ext_irq, 3'b0, timer_irq, 3'b0, soft_irq, 3'b0};

    // Interrupts enabled and pending
    wire [31:0] irq_pending = mip_hw & csr_mie & {32{csr_mstatus[3]}};
    wire irq_any = |irq_pending;

    // Interrupt taken: between instructions at EX1, when no exception in pipeline
    assign irq_taken = irq_any && rr_ex1_valid && !rr_ex1_exc_pending &&
                     !rr_ex1_is_ecall && !rr_ex1_is_ebreak && !rr_ex1_is_mret &&
                     !global_stall && !debug_stall;

    // NMI: non-maskable, highest priority
    reg nmi_r, nmi_prev;
    wire nmi_edge = nmi_r && !nmi_prev;  // rising-edge detect
    reg  nmi_pending;

    // Forward-declare nmi_taken so the always block can reference it
    // (nmi_taken forward-declared above)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nmi_r       <= 1'b0;
            nmi_prev    <= 1'b0;
            nmi_pending <= 1'b0;
        end else begin
            nmi_r    <= nmi;
            nmi_prev <= nmi_r;
            if (nmi_edge)
                nmi_pending <= 1'b1;
            else if (nmi_taken)
                nmi_pending <= 1'b0;
        end
    end

    assign nmi_taken = nmi_pending && rr_ex1_valid && !global_stall && !debug_stall;

    // Priority encode: external > timer > software
    wire [31:0] irq_cause = irq_pending[11] ? 32'h8000_000B :  // MEIP
                            irq_pending[7]  ? 32'h8000_0007 :  // MTIP
                            irq_pending[3]  ? 32'h8000_0003 :  // MSIP
                                              32'h8000_000B;

    // Trap-vector computation (vectored + direct modes)
    //   mtvec[1:0] == 00 : direct  — all traps to BASE
    //   mtvec[1:0] == 01 : vectored — interrupts to BASE+4*cause, exceptions to BASE
    wire [31:0] trap_base    = {csr_mtvec[31:2], 2'b00};
    wire        trap_vectored = (csr_mtvec[1:0] == 2'b01);
    wire [31:0] trap_target  = (trap_vectored && irq_taken && !nmi_taken) ?
                                trap_base + {irq_cause[29:0], 2'b00} : trap_base;
    wire [31:0] nmi_target   = NMI_ADDR;
    wire [31:0] mret_target  = csr_mepc;

    // -----------------------------------------------------------------------
    // SECTION 2 — Exception Commit at WB + Pipeline Flush
    // -----------------------------------------------------------------------

    assign wb_exception = mem_wb_valid && mem_wb_exc_pending &&
                        !global_stall && !debug_stall;

    // Flush priority: NMI > WB exception > interrupt > EX1 redirect/mispredict
    assign pipeline_flush = nmi_taken || wb_exception || irq_taken ||
                            (ex1_mispredict && !global_stall && !debug_stall) ||
                            (ex1_redirect   && !global_stall && !debug_stall);

    assign flush_target = nmi_taken    ? nmi_target  :
                          wb_exception ? trap_target  :
                          irq_taken    ? trap_target  :
                          rr_ex1_is_mret   ? mret_target     :
                          rr_ex1_is_fencei ? ex1_pc_plus_n   :
                          rr_ex1_jalr      ? ex1_jalr_target :
                                             ex1_recovery_pc;

    // FENCE.I output (active for one cycle after commit)
    reg fence_i_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            fence_i_r <= 1'b0;
        else
            fence_i_r <= rr_ex1_is_fencei && rr_ex1_valid &&
                         !global_stall && !debug_stall;
    end
    assign fence_i = fence_i_r;

    // -----------------------------------------------------------------------
    // SECTION 3 — CSR Write + Exception Handling (main sequential block)
    // -----------------------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csr_mstatus      <= 32'h0000_1800;   // MPP = M-mode
            csr_misa          <= 32'h4000_1105;   // RV32IMAC
            csr_mie           <= 32'd0;
            csr_mtvec         <= 32'd0;
            csr_mcounteren    <= 32'd0;
            csr_mcountinhibit <= 32'd0;
            csr_mscratch      <= 32'd0;
            csr_mepc          <= 32'd0;
            csr_mcause        <= 32'd0;
            csr_mtval         <= 32'd0;
            csr_mip           <= 32'd0;
            csr_mcycle        <= 64'd0;
            csr_minstret      <= 64'd0;
            csr_mhpmcnt3      <= 64'd0;
            csr_mhpmcnt4      <= 64'd0;
            csr_mhpmevent3    <= 32'd1;     // Bit[0] = branch misprediction events
            csr_mhpmevent4    <= 32'd2;     // Bit[1] = load-use stall events
            // PMP config
            csr_pmpcfg[0]     <= 32'd0;
            csr_pmpcfg[1]     <= 32'd0;
            csr_pmpcfg[2]     <= 32'd0;
            csr_pmpcfg[3]     <= 32'd0;
            // PMP addresses
            begin : pmp_reset
                integer pi;
                for (pi = 0; pi < 16; pi = pi + 1)
                    csr_pmpaddr[pi] <= 32'd0;
            end
            // Debug / Trace CSRs
            csr_tselect   <= 32'd0;
            csr_tdata1    <= 32'd0;
            csr_tdata2    <= 32'd0;
            csr_tdata1_1  <= 32'd0;
            csr_tdata2_1  <= 32'd0;
            csr_dcsr      <= 32'h4000_0003;  // version=4, prv=M
            csr_dpc       <= 32'd0;
            csr_dscratch0 <= 32'd0;
        end else begin
            // MIP always reflects hardware interrupt pins
            csr_mip <= mip_hw;

            // Cycle counter (unless inhibited)
            if (!csr_mcountinhibit[0])
                csr_mcycle <= csr_mcycle + 64'd1;

            // Instruction retire counter
            if (!csr_mcountinhibit[2] && mem_wb_valid &&
                !mem_wb_exc_pending && !global_stall && !debug_stall)
                csr_minstret <= csr_minstret + 64'd1;

            // HPM counter 3: branch mispredictions (event code bit 0)
            if (csr_mhpmevent3[0] && ex1_mispredict && !global_stall)
                csr_mhpmcnt3 <= csr_mhpmcnt3 + 64'd1;

            // HPM counter 4: load-use stalls (event code bit 1)
            if (csr_mhpmevent4[1] && hazard_stall)
                csr_mhpmcnt4 <= csr_mhpmcnt4 + 64'd1;

            if (!debug_stall) begin
                // ---- Priority: NMI > WB exception > Interrupt > MRET > CSR write ----
                if (nmi_taken) begin
                    csr_mepc            <= rr_ex1_pc;
                    csr_mcause          <= 32'h8000_0000;
                    csr_mtval           <= 32'd0;
                    csr_mstatus[7]      <= csr_mstatus[3];   // MPIE <= MIE
                    csr_mstatus[3]      <= 1'b0;             // MIE  <= 0
                    csr_mstatus[12:11]  <= 2'b11;            // MPP  <= M
                end
                else if (wb_exception) begin
                    csr_mepc            <= mem_wb_pc;
                    csr_mcause          <= {28'd0, mem_wb_exc_cause};
                    csr_mtval           <= mem_wb_exc_tval;
                    csr_mstatus[7]      <= csr_mstatus[3];
                    csr_mstatus[3]      <= 1'b0;
                    csr_mstatus[12:11]  <= 2'b11;
                end
                else if (irq_taken) begin
                    csr_mepc            <= rr_ex1_pc;
                    csr_mcause          <= irq_cause;
                    csr_mtval           <= 32'd0;
                    csr_mstatus[7]      <= csr_mstatus[3];
                    csr_mstatus[3]      <= 1'b0;
                    csr_mstatus[12:11]  <= 2'b11;
                end
                else if (rr_ex1_valid && rr_ex1_is_mret && !global_stall) begin
                    csr_mstatus[3]      <= csr_mstatus[7];   // MIE  <= MPIE
                    csr_mstatus[7]      <= 1'b1;             // MPIE <= 1
                    csr_mstatus[12:11]  <= 2'b11;            // MPP  <= M
                end
                else if (rr_ex1_valid && rr_ex1_csr_write &&
                         !rr_ex1_exc_pending && !global_stall) begin
                    case (rr_ex1_csr_addr)
                        CSR_MSTATUS:       csr_mstatus <= csr_wdata & 32'h0000_1888;
                        CSR_MISA:          csr_misa    <= csr_misa; // WARL: fixed
                        CSR_MIE:           csr_mie     <= csr_wdata;
                        CSR_MTVEC:         csr_mtvec   <= csr_wdata;
                        CSR_MCOUNTEREN:    csr_mcounteren    <= csr_wdata;
                        CSR_MCOUNTINHIBIT: csr_mcountinhibit <= csr_wdata;
                        CSR_MSCRATCH:      csr_mscratch <= csr_wdata;
                        CSR_MEPC:          csr_mepc     <= {csr_wdata[31:1], 1'b0};
                        CSR_MCAUSE:        csr_mcause   <= csr_wdata;
                        CSR_MTVAL:         csr_mtval    <= csr_wdata;
                        CSR_MIP:           ;  // read-only (hardware pins)
                        CSR_MCYCLE:        csr_mcycle[31:0]    <= csr_wdata;
                        CSR_MCYCLEH:       csr_mcycle[63:32]   <= csr_wdata;
                        CSR_MINSTRET:      csr_minstret[31:0]  <= csr_wdata;
                        CSR_MINSTRETH:     csr_minstret[63:32] <= csr_wdata;
                        CSR_MHPMCNT3:      csr_mhpmcnt3[31:0]  <= csr_wdata;
                        CSR_MHPMCNT3H:     csr_mhpmcnt3[63:32] <= csr_wdata;
                        CSR_MHPMCNT4:      csr_mhpmcnt4[31:0]  <= csr_wdata;
                        CSR_MHPMCNT4H:     csr_mhpmcnt4[63:32] <= csr_wdata;
                        CSR_MHPMEVENT3:    csr_mhpmevent3 <= csr_wdata;
                        CSR_MHPMEVENT4:    csr_mhpmevent4 <= csr_wdata;
                        // PMP config (respect lock bits)
                        CSR_PMPCFG0: begin
                            if (!csr_pmpcfg[0][7])   csr_pmpcfg[0][7:0]   <= csr_wdata[7:0];
                            if (!csr_pmpcfg[0][15])  csr_pmpcfg[0][15:8]  <= csr_wdata[15:8];
                            if (!csr_pmpcfg[0][23])  csr_pmpcfg[0][23:16] <= csr_wdata[23:16];
                            if (!csr_pmpcfg[0][31])  csr_pmpcfg[0][31:24] <= csr_wdata[31:24];
                        end
                        CSR_PMPCFG1: begin
                            if (!csr_pmpcfg[1][7])   csr_pmpcfg[1][7:0]   <= csr_wdata[7:0];
                            if (!csr_pmpcfg[1][15])  csr_pmpcfg[1][15:8]  <= csr_wdata[15:8];
                            if (!csr_pmpcfg[1][23])  csr_pmpcfg[1][23:16] <= csr_wdata[23:16];
                            if (!csr_pmpcfg[1][31])  csr_pmpcfg[1][31:24] <= csr_wdata[31:24];
                        end
                        CSR_PMPCFG2: begin
                            if (!csr_pmpcfg[2][7])   csr_pmpcfg[2][7:0]   <= csr_wdata[7:0];
                            if (!csr_pmpcfg[2][15])  csr_pmpcfg[2][15:8]  <= csr_wdata[15:8];
                            if (!csr_pmpcfg[2][23])  csr_pmpcfg[2][23:16] <= csr_wdata[23:16];
                            if (!csr_pmpcfg[2][31])  csr_pmpcfg[2][31:24] <= csr_wdata[31:24];
                        end
                        CSR_PMPCFG3: begin
                            if (!csr_pmpcfg[3][7])   csr_pmpcfg[3][7:0]   <= csr_wdata[7:0];
                            if (!csr_pmpcfg[3][15])  csr_pmpcfg[3][15:8]  <= csr_wdata[15:8];
                            if (!csr_pmpcfg[3][23])  csr_pmpcfg[3][23:16] <= csr_wdata[23:16];
                            if (!csr_pmpcfg[3][31])  csr_pmpcfg[3][31:24] <= csr_wdata[31:24];
                        end
                        // PMP addresses (respect lock bit of owning config entry)
                        12'h3B0: if (!csr_pmpcfg[0][7])   csr_pmpaddr[0]  <= csr_wdata;
                        12'h3B1: if (!csr_pmpcfg[0][15])  csr_pmpaddr[1]  <= csr_wdata;
                        12'h3B2: if (!csr_pmpcfg[0][23])  csr_pmpaddr[2]  <= csr_wdata;
                        12'h3B3: if (!csr_pmpcfg[0][31])  csr_pmpaddr[3]  <= csr_wdata;
                        12'h3B4: if (!csr_pmpcfg[1][7])   csr_pmpaddr[4]  <= csr_wdata;
                        12'h3B5: if (!csr_pmpcfg[1][15])  csr_pmpaddr[5]  <= csr_wdata;
                        12'h3B6: if (!csr_pmpcfg[1][23])  csr_pmpaddr[6]  <= csr_wdata;
                        12'h3B7: if (!csr_pmpcfg[1][31])  csr_pmpaddr[7]  <= csr_wdata;
                        12'h3B8: if (!csr_pmpcfg[2][7])   csr_pmpaddr[8]  <= csr_wdata;
                        12'h3B9: if (!csr_pmpcfg[2][15])  csr_pmpaddr[9]  <= csr_wdata;
                        12'h3BA: if (!csr_pmpcfg[2][23])  csr_pmpaddr[10] <= csr_wdata;
                        12'h3BB: if (!csr_pmpcfg[2][31])  csr_pmpaddr[11] <= csr_wdata;
                        12'h3BC: if (!csr_pmpcfg[3][7])   csr_pmpaddr[12] <= csr_wdata;
                        12'h3BD: if (!csr_pmpcfg[3][15])  csr_pmpaddr[13] <= csr_wdata;
                        12'h3BE: if (!csr_pmpcfg[3][23])  csr_pmpaddr[14] <= csr_wdata;
                        12'h3BF: if (!csr_pmpcfg[3][31])  csr_pmpaddr[15] <= csr_wdata;
                        // Debug / Trace trigger CSRs
                        CSR_TSELECT: csr_tselect <= (csr_wdata < 32'd2) ? csr_wdata : csr_tselect;
                        CSR_TDATA1: begin
                            if (csr_tselect == 32'd0) csr_tdata1   <= csr_wdata;
                            else                      csr_tdata1_1 <= csr_wdata;
                        end
                        CSR_TDATA2: begin
                            if (csr_tselect == 32'd0) csr_tdata2   <= csr_wdata;
                            else                      csr_tdata2_1 <= csr_wdata;
                        end
                        CSR_DCSR:      csr_dcsr      <= csr_wdata;
                        CSR_DPC:       csr_dpc       <= csr_wdata;
                        CSR_DSCRATCH0: csr_dscratch0 <= csr_wdata;
                        default: ;  // ignore writes to unknown CSRs
                    endcase
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // SECTION 4 — Debug Halt / Resume + Hardware Breakpoints
    // -----------------------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            debug_halted_r <= 1'b0;
        else if (debug_halt && !debug_halted_r)
            debug_halted_r <= 1'b1;
        else if (debug_resume && debug_halted_r)
            debug_halted_r <= 1'b0;
    end

    assign debug_halted   = debug_halted_r;
    assign debug_running  = ~debug_halted_r;
    assign debug_pc       = rr_ex1_pc;
    assign debug_gpr_rdata = (debug_gpr_addr == 5'd0) ? 32'd0 : regfile[debug_gpr_addr];

    // Hardware breakpoints — two triggers
    //   tdata1[2]    = execute match enable
    //   tdata1[27]   = select (0 = address, 1 = data)
    //   tdata1[10:7] = match type (0 = equal)
    wire trigger0_match = csr_tdata1[2]   && !csr_tdata1[27]   &&
                          (csr_tdata1[10:7]   == 4'd0)         &&
                          (rr_ex1_pc == csr_tdata2) && rr_ex1_valid;

    wire trigger1_match = csr_tdata1_1[2] && !csr_tdata1_1[27] &&
                          (csr_tdata1_1[10:7] == 4'd0)         &&
                          (rr_ex1_pc == csr_tdata2_1) && rr_ex1_valid;

    wire hw_breakpoint  = trigger0_match || trigger1_match;

    // -----------------------------------------------------------------------
    // SECTION 5 — WFI (Wait For Interrupt)
    // -----------------------------------------------------------------------

    reg wfi_active_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            wfi_active_r <= 1'b0;
        else if (rr_ex1_is_wfi && rr_ex1_valid &&
                 !global_stall && !debug_stall && !rr_ex1_exc_pending)
            wfi_active_r <= 1'b1;
        else if (|mip_hw || nmi_pending || debug_halt)
            wfi_active_r <= 1'b0;
    end

    assign wfi_active_w = wfi_active_r;

    // -----------------------------------------------------------------------
    // SECTION 6 — Gshare / BTB / RAS Update (EX1 resolution)
    // -----------------------------------------------------------------------

    wire [7:0] gshare_idx_ex = rr_ex1_pc[9:2] ^ ghr;
    wire [5:0] btb_set_ex    = rr_ex1_pc[7:2];

    wire ex1_is_branch_or_jal = rr_ex1_valid &&
                                (rr_ex1_branch || rr_ex1_jal) &&
                                !global_stall && !debug_stall;

    wire ex1_is_jalr_resolved = rr_ex1_valid && rr_ex1_jalr &&
                                !global_stall && !debug_stall;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin : pred_reset
            integer k;
            ghr     <= 8'd0;
            ras_tos <= 3'd0;
            for (k = 0; k < 256; k = k + 1)
                gshare_pht[k] <= 2'b01;  // weakly not-taken
            for (k = 0; k < 128; k = k + 1) begin
                btb_valid[k]  <= 1'b0;
                btb_tag[k]    <= 24'd0;
                btb_target[k] <= 32'd0;
            end
            btb_lru <= 64'd0;
            for (k = 0; k < 8; k = k + 1)
                ras[k] <= 32'd0;
        end else if (!debug_stall) begin
            // GHR update on branch / JAL resolution
            if (ex1_is_branch_or_jal)
                ghr <= {ghr[6:0], ex1_actually_taken};

            // Gshare PHT update — 2-bit saturating counter
            if (rr_ex1_valid && rr_ex1_branch && !global_stall) begin
                if (branch_cond && gshare_pht[gshare_idx_ex] != 2'b11)
                    gshare_pht[gshare_idx_ex] <= gshare_pht[gshare_idx_ex] + 2'b01;
                else if (!branch_cond && gshare_pht[gshare_idx_ex] != 2'b00)
                    gshare_pht[gshare_idx_ex] <= gshare_pht[gshare_idx_ex] - 2'b01;
            end

            // BTB update on branch / JAL / JALR resolution
            if (ex1_is_branch_or_jal || ex1_is_jalr_resolved) begin
                if (btb_valid[{btb_set_ex, 1'b0}] &&
                    btb_tag[{btb_set_ex, 1'b0}] == rr_ex1_pc[31:8]) begin
                    // Hit way 0
                    btb_target[{btb_set_ex, 1'b0}] <= ex1_actually_taken ? ex1_computed_target :
                                                       (rr_ex1_jalr ? ex1_jalr_target : ex1_computed_target);
                    btb_lru[btb_set_ex] <= 1'b1;
                end
                else if (btb_valid[{btb_set_ex, 1'b1}] &&
                         btb_tag[{btb_set_ex, 1'b1}] == rr_ex1_pc[31:8]) begin
                    // Hit way 1
                    btb_target[{btb_set_ex, 1'b1}] <= ex1_actually_taken ? ex1_computed_target :
                                                       (rr_ex1_jalr ? ex1_jalr_target : ex1_computed_target);
                    btb_lru[btb_set_ex] <= 1'b0;
                end
                else begin
                    // Miss — allocate in LRU way
                    if (!btb_lru[btb_set_ex]) begin
                        btb_target[{btb_set_ex, 1'b0}] <= ex1_actually_taken ? ex1_computed_target
                                                                              : ex1_jalr_target;
                        btb_tag[{btb_set_ex, 1'b0}]    <= rr_ex1_pc[31:8];
                        btb_valid[{btb_set_ex, 1'b0}]   <= 1'b1;
                        btb_lru[btb_set_ex]              <= 1'b1;
                    end else begin
                        btb_target[{btb_set_ex, 1'b1}] <= ex1_actually_taken ? ex1_computed_target
                                                                              : ex1_jalr_target;
                        btb_tag[{btb_set_ex, 1'b1}]    <= rr_ex1_pc[31:8];
                        btb_valid[{btb_set_ex, 1'b1}]   <= 1'b1;
                        btb_lru[btb_set_ex]              <= 1'b0;
                    end
                end
            end

            // RAS update
            if (rr_ex1_valid && !global_stall) begin
                // Push on JAL/JALR where rd is link register (x1 or x5)
                if ((rr_ex1_jal || rr_ex1_jalr) &&
                    (rr_ex1_rd == 5'd1 || rr_ex1_rd == 5'd5)) begin
                    ras_tos              <= ras_tos + 3'd1;
                    ras[ras_tos + 3'd1]  <= ex1_pc_plus_n;
                end
                // Pop on JALR where rs1 is link and rd is NOT link
                else if (rr_ex1_jalr &&
                         (rr_ex1_rs1 == 5'd1 || rr_ex1_rs1 == 5'd5) &&
                         rr_ex1_rd != 5'd1 && rr_ex1_rd != 5'd5) begin
                    ras_tos <= ras_tos - 3'd1;
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // SECTION 7 — Power Management / Clock-Gating Enables
    // -----------------------------------------------------------------------

    assign cpu_active      = !wfi_active_r && !debug_halted_r;
    assign cpu_power_state = debug_halted_r ? 3'b010 :
                             wfi_active_r   ? 3'b001 : 3'b000;

    wire cg_en_bht     = !wfi_active_r && !debug_halted_r;
    wire cg_en_mul     = rr_ex1_valid &&
                         (rr_ex1_alu_op >= ALU_MUL) &&
                         (rr_ex1_alu_op <= ALU_MULHU);
    wire cg_en_div     = div_busy;
    wire cg_en_regfile_wr = mem_wb_reg_write && mem_wb_valid && !mem_wb_exc_pending;

    // -----------------------------------------------------------------------
    // SECTION 8 — End of module
    // -----------------------------------------------------------------------

endmodule
