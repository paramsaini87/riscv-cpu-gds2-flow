// rv32i_cpu.v — RISC-V RV32IM 5-Stage Pipelined CPU
// ISA: RV32IM + Machine CSR (54 instructions)
// Pipeline: IF → ID → EX → MEM → WB
// Features: Data forwarding, hazard detection, dynamic branch prediction (BHT+BTB)
//           Multi-cycle multiply (3 cycles), iterative restoring divider (33 cycles)
//           Machine-mode CSR, ECALL/EBREAK trap handling, MRET
// Target: ~50K-80K gates on SKY130

module rv32i_cpu #(
    parameter RESET_ADDR = 32'h0000_0000
) (
    input                clk,
    input                rst_n,

    // Instruction memory interface
    output        [31:0] imem_addr,
    output               imem_req,
    input         [31:0] imem_rdata,
    input                imem_ready,

    // Data memory interface
    output        [31:0] dmem_addr,
    output        [31:0] dmem_wdata,
    output         [3:0] dmem_wstrb,
    output               dmem_req,
    input         [31:0] dmem_rdata,
    input                dmem_ready
);

    // =========================================================================
    // OPCODE DEFINITIONS (RV32I)
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

    // ALU operations (5-bit to accommodate M extension)
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
    // M extension
    localparam ALU_MUL    = 5'd11;
    localparam ALU_MULH   = 5'd12;
    localparam ALU_MULHSU = 5'd13;
    localparam ALU_MULHU  = 5'd14;
    localparam ALU_DIV    = 5'd16;
    localparam ALU_DIVU   = 5'd17;
    localparam ALU_REM    = 5'd18;
    localparam ALU_REMU   = 5'd19;

    // =========================================================================
    // PIPELINE REGISTERS
    // =========================================================================

    // IF/ID
    reg [31:0] ifid_pc;
    reg [31:0] ifid_instr;
    reg        ifid_valid;
    reg        ifid_predicted_taken;

    // ID/EX
    reg [31:0] idex_pc;
    reg [31:0] idex_rs1_data;
    reg [31:0] idex_rs2_data;
    reg [31:0] idex_imm;
    reg  [4:0] idex_rd;
    reg  [4:0] idex_rs1;
    reg  [4:0] idex_rs2;
    reg  [4:0] idex_alu_op;
    reg        idex_alu_src;       // 0=rs2, 1=imm
    reg        idex_mem_read;
    reg        idex_mem_write;
    reg  [2:0] idex_mem_size;      // funct3 for load/store width
    reg        idex_reg_write;
    reg  [1:0] idex_result_src;    // 0=ALU, 1=MEM, 2=PC+4, 3=CSR
    reg        idex_branch;
    reg        idex_jal;
    reg        idex_jalr;
    reg  [2:0] idex_funct3;
    reg        idex_auipc;         // explicit AUIPC flag (uses PC as ALU operand A)
    reg        idex_valid;
    // CSR fields
    reg [11:0] idex_csr_addr;
    reg        idex_csr_op;        // is a CSR read/write instruction
    reg        idex_csr_write;     // actually writes the CSR (not just read)
    reg        idex_is_ecall;
    reg        idex_is_ebreak;
    reg        idex_is_mret;
    reg        idex_predicted_taken;

    // EX/MEM
    reg [31:0] exmem_alu_result;
    reg [31:0] exmem_rs2_data;
    reg [31:0] exmem_pc_plus4;
    reg  [4:0] exmem_rd;
    reg        exmem_mem_read;
    reg        exmem_mem_write;
    reg  [2:0] exmem_mem_size;
    reg        exmem_reg_write;
    reg  [1:0] exmem_result_src;
    reg        exmem_valid;

    // MEM/WB
    reg [31:0] memwb_alu_result;
    reg [31:0] memwb_mem_data;
    reg [31:0] memwb_pc_plus4;
    reg  [4:0] memwb_rd;
    reg        memwb_reg_write;
    reg  [1:0] memwb_result_src;
    reg        memwb_valid;

    // =========================================================================
    // PROGRAM COUNTER + BRANCH PREDICTION
    // =========================================================================
    reg [31:0] pc;
    wire [31:0] pc_next;
    wire        pc_stall;
    wire        pipeline_flush;

    wire [31:0] pc_plus4 = pc + 32'd4;
    wire [31:0] branch_target;

    // Branch History Table: 64 entries × 2-bit saturating counter
    // States: 00=strongly not-taken, 01=weakly not-taken,
    //         10=weakly taken, 11=strongly taken
    reg [1:0] bht [0:63];

    // Branch Target Buffer: 64 entries (direct-mapped)
    reg [31:0] btb_target [0:63];
    reg [23:0] btb_tag    [0:63];
    reg        btb_valid  [0:63];

    // IF-stage partial decode for branch prediction
    wire [6:0] if_opcode = imem_rdata[6:0];
    wire if_is_branch = (if_opcode == 7'b1100011);  // OP_BRANCH
    wire if_is_jal    = (if_opcode == 7'b1101111);  // OP_JAL

    // BHT + BTB lookup (indexed by PC[7:2], 64 entries for 4-byte-aligned insns)
    wire [5:0] bht_idx_if = pc[7:2];
    wire [1:0] bht_counter_if = bht[bht_idx_if];
    wire       bht_predict_taken = bht_counter_if[1];  // MSB = taken prediction
    wire       btb_hit = btb_valid[bht_idx_if] && (btb_tag[bht_idx_if] == pc[31:8]);

    // Predict taken for JAL (always) or conditional branch (if BHT says taken)
    wire if_predict_taken = imem_ready && btb_hit &&
                            (if_is_jal || (if_is_branch && bht_predict_taken));
    wire [31:0] if_predict_target = btb_target[bht_idx_if];

    // PC mux: misprediction correction > prediction > sequential
    assign pc_next = pipeline_flush    ? branch_target :
                     if_predict_taken  ? if_predict_target :
                     pc_plus4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pc <= RESET_ADDR;
        else if (!pc_stall)
            pc <= pc_next;
    end

    // Instruction memory interface
    assign imem_addr = pc;
    // imem_req independent of fetch_stall to avoid combinational loop
    // Request when pipeline can accept (no downstream stalls or hazards)
    assign imem_req  = !(mem_stall || mul_div_stall || load_use_hazard);

    // =========================================================================
    // STAGE 1: INSTRUCTION FETCH (IF)
    // =========================================================================
    // IF/ID register: stall on pc_stall, flush on misprediction/redirect
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ifid_pc    <= 0;
            ifid_instr <= 32'h0000_0013; // NOP (addi x0, x0, 0)
            ifid_valid <= 0;
            ifid_predicted_taken <= 0;
        end else if (!mem_stall && !mul_div_stall) begin
            if (pipeline_flush) begin
                ifid_instr <= 32'h0000_0013;
                ifid_valid <= 0;
                ifid_predicted_taken <= 0;
            end else if (!pc_stall) begin
                ifid_pc    <= pc;
                ifid_instr <= imem_rdata;
                ifid_valid <= imem_ready;
                ifid_predicted_taken <= if_predict_taken;
            end else if (!load_use_hazard) begin
                // Fetch stall: instruction already consumed by ID/EX, insert bubble
                // (load_use_hazard inserts bubble in ID/EX instead, so IF/ID stays valid)
                ifid_valid <= 0;
            end
        end
    end

    // =========================================================================
    // STAGE 2: INSTRUCTION DECODE (ID)
    // =========================================================================

    // Instruction field extraction
    wire [6:0]  opcode = ifid_instr[6:0];
    wire [4:0]  rd     = ifid_instr[11:7];
    wire [2:0]  funct3 = ifid_instr[14:12];
    wire [4:0]  rs1    = ifid_instr[19:15];
    wire [4:0]  rs2    = ifid_instr[24:20];
    wire [6:0]  funct7 = ifid_instr[31:25];

    // Immediate generation (all RV32I formats)
    wire [31:0] imm_i = {{20{ifid_instr[31]}}, ifid_instr[31:20]};
    wire [31:0] imm_s = {{20{ifid_instr[31]}}, ifid_instr[31:25], ifid_instr[11:7]};
    wire [31:0] imm_b = {{19{ifid_instr[31]}}, ifid_instr[31], ifid_instr[7],
                          ifid_instr[30:25], ifid_instr[11:8], 1'b0};
    wire [31:0] imm_u = {ifid_instr[31:12], 12'b0};
    wire [31:0] imm_j = {{11{ifid_instr[31]}}, ifid_instr[31], ifid_instr[19:12],
                          ifid_instr[20], ifid_instr[30:21], 1'b0};

    // Immediate mux
    reg [31:0] imm_dec;
    always @(*) begin
        case (opcode)
            OP_IMM, OP_LOAD, OP_JALR: imm_dec = imm_i;
            OP_STORE:                  imm_dec = imm_s;
            OP_BRANCH:                 imm_dec = imm_b;
            OP_LUI, OP_AUIPC:         imm_dec = imm_u;
            OP_JAL:                    imm_dec = imm_j;
            default:                   imm_dec = 32'd0;
        endcase
    end

    // Register file (32 × 32-bit, x0 hardwired to 0)
    reg [31:0] regfile [0:31];
    integer idx;

    // WB→ID bypass: same-cycle read-after-write forwarding
    wire wb_fwd_rs1 = memwb_reg_write && memwb_valid && (memwb_rd != 5'd0) && (memwb_rd == rs1);
    wire wb_fwd_rs2 = memwb_reg_write && memwb_valid && (memwb_rd != 5'd0) && (memwb_rd == rs2);
    wire [31:0] rf_rs1_data = (rs1 == 5'd0) ? 32'd0 : wb_fwd_rs1 ? wb_data : regfile[rs1];
    wire [31:0] rf_rs2_data = (rs2 == 5'd0) ? 32'd0 : wb_fwd_rs2 ? wb_data : regfile[rs2];

    // Control signal decode
    reg [4:0]  dec_alu_op;
    reg        dec_alu_src;
    reg        dec_mem_read;
    reg        dec_mem_write;
    reg        dec_reg_write;
    reg [1:0]  dec_result_src;
    reg        dec_branch;
    reg        dec_jal;
    reg        dec_jalr;
    reg        dec_auipc;
    reg        dec_csr_op;
    reg        dec_csr_write;
    reg        dec_is_ecall;
    reg        dec_is_ebreak;
    reg        dec_is_mret;

    always @(*) begin
        dec_alu_op    = ALU_ADD;
        dec_alu_src   = 0;
        dec_mem_read  = 0;
        dec_mem_write = 0;
        dec_reg_write = 0;
        dec_result_src = 2'b00;
        dec_branch    = 0;
        dec_jal       = 0;
        dec_jalr      = 0;
        dec_auipc     = 0;
        dec_csr_op    = 0;
        dec_csr_write = 0;
        dec_is_ecall  = 0;
        dec_is_ebreak = 0;
        dec_is_mret   = 0;

        case (opcode)
            OP_LUI: begin
                dec_alu_op    = ALU_PASS_B;
                dec_alu_src   = 1;
                dec_reg_write = 1;
            end
            OP_AUIPC: begin
                dec_alu_op    = ALU_ADD;
                dec_alu_src   = 1;
                dec_reg_write = 1;
                dec_auipc     = 1;
            end
            OP_JAL: begin
                dec_jal       = 1;
                dec_reg_write = 1;
                dec_result_src = 2'b10; // PC+4
            end
            OP_JALR: begin
                dec_jalr      = 1;
                dec_alu_src   = 1;
                dec_reg_write = 1;
                dec_result_src = 2'b10;
            end
            OP_BRANCH: begin
                dec_branch    = 1;
            end
            OP_LOAD: begin
                dec_alu_op    = ALU_ADD;
                dec_alu_src   = 1;
                dec_mem_read  = 1;
                dec_reg_write = 1;
                dec_result_src = 2'b01; // MEM
            end
            OP_STORE: begin
                dec_alu_op    = ALU_ADD;
                dec_alu_src   = 1;
                dec_mem_write = 1;
            end
            OP_IMM: begin
                dec_alu_src   = 1;
                dec_reg_write = 1;
                case (funct3)
                    3'b000: dec_alu_op = ALU_ADD;
                    3'b001: dec_alu_op = ALU_SLL;
                    3'b010: dec_alu_op = ALU_SLT;
                    3'b011: dec_alu_op = ALU_SLTU;
                    3'b100: dec_alu_op = ALU_XOR;
                    3'b101: dec_alu_op = (funct7[5]) ? ALU_SRA : ALU_SRL;
                    3'b110: dec_alu_op = ALU_OR;
                    3'b111: dec_alu_op = ALU_AND;
                endcase
            end
            OP_REG: begin
                dec_reg_write = 1;
                if (funct7 == 7'b0000001) begin
                    // M extension: multiply/divide
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
                end else begin
                    case (funct3)
                        3'b000: dec_alu_op = (funct7[5]) ? ALU_SUB : ALU_ADD;
                        3'b001: dec_alu_op = ALU_SLL;
                        3'b010: dec_alu_op = ALU_SLT;
                        3'b011: dec_alu_op = ALU_SLTU;
                        3'b100: dec_alu_op = ALU_XOR;
                        3'b101: dec_alu_op = (funct7[5]) ? ALU_SRA : ALU_SRL;
                        3'b110: dec_alu_op = ALU_OR;
                        3'b111: dec_alu_op = ALU_AND;
                    endcase
                end
            end
            OP_FENCE: begin
                // NOP for single-core in-order
            end
            OP_SYSTEM: begin
                if (funct3 != 3'b000) begin
                    // CSR instructions (funct3: 001=CSRRW, 010=CSRRS, 011=CSRRC,
                    //                          101=CSRRWI, 110=CSRRSI, 111=CSRRCI)
                    dec_csr_op    = 1;
                    dec_reg_write = 1;
                    dec_result_src = 2'b11; // CSR read data
                    // CSRRS/CSRRC with rs1/uimm=0 don't write CSR
                    if (funct3[1:0] == 2'b01) // CSRRW/CSRRWI: always write
                        dec_csr_write = 1;
                    else // CSRRS/CSRRC: write only if operand != 0
                        dec_csr_write = (rs1 != 5'd0);
                end else begin
                    // ECALL/EBREAK/MRET (funct3=000, differentiated by funct12)
                    case (ifid_instr[31:20])
                        12'h000: dec_is_ecall  = 1;
                        12'h001: dec_is_ebreak = 1;
                        12'h302: dec_is_mret   = 1;
                        default: ; // NOP for unrecognized
                    endcase
                end
            end
        endcase
    end

    // =========================================================================
    // HAZARD DETECTION UNIT
    // =========================================================================
    wire load_use_hazard;
    assign load_use_hazard = idex_mem_read && idex_valid &&
                             ((idex_rd == rs1 && rs1 != 5'd0) ||
                              (idex_rd == rs2 && rs2 != 5'd0)) &&
                             (opcode != OP_LUI && opcode != OP_AUIPC &&
                              opcode != OP_JAL);

    // Memory stall: freeze entire pipeline when memory not ready
    wire mem_stall  = (exmem_mem_read || exmem_mem_write) && exmem_valid && !dmem_ready;
    wire fetch_stall = imem_req && !imem_ready;

    assign pc_stall = load_use_hazard || mem_stall || fetch_stall || mul_div_stall;

    // ID/EX register update
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || (pipeline_flush && !mem_stall && !mul_div_stall) || (load_use_hazard && !mem_stall && !mul_div_stall)) begin
            idex_pc         <= 0;
            idex_rs1_data   <= 0;
            idex_rs2_data   <= 0;
            idex_imm        <= 0;
            idex_rd         <= 0;
            idex_rs1        <= 0;
            idex_rs2        <= 0;
            idex_alu_op     <= ALU_ADD;
            idex_alu_src    <= 0;
            idex_mem_read   <= 0;
            idex_mem_write  <= 0;
            idex_mem_size   <= 0;
            idex_reg_write  <= 0;
            idex_result_src <= 0;
            idex_branch     <= 0;
            idex_jal        <= 0;
            idex_jalr       <= 0;
            idex_auipc      <= 0;
            idex_funct3     <= 0;
            idex_valid      <= 0;
            idex_csr_addr   <= 0;
            idex_csr_op     <= 0;
            idex_csr_write  <= 0;
            idex_is_ecall   <= 0;
            idex_is_ebreak  <= 0;
            idex_is_mret    <= 0;
            idex_predicted_taken <= 0;
        end else if (!mem_stall && !mul_div_stall) begin
            idex_pc         <= ifid_pc;
            idex_rs1_data   <= rf_rs1_data;
            idex_rs2_data   <= rf_rs2_data;
            idex_imm        <= imm_dec;
            idex_rd         <= rd;
            idex_rs1        <= rs1;
            idex_rs2        <= rs2;
            idex_alu_op     <= dec_alu_op;
            idex_alu_src    <= dec_alu_src;
            idex_mem_read   <= dec_mem_read;
            idex_mem_write  <= dec_mem_write;
            idex_mem_size   <= funct3;
            idex_reg_write  <= dec_reg_write;
            idex_result_src <= dec_result_src;
            idex_branch     <= dec_branch;
            idex_jal        <= dec_jal;
            idex_jalr       <= dec_jalr;
            idex_auipc      <= dec_auipc;
            idex_funct3     <= funct3;
            idex_valid      <= ifid_valid;
            idex_csr_addr   <= ifid_instr[31:20];
            idex_csr_op     <= dec_csr_op;
            idex_csr_write  <= dec_csr_write;
            idex_is_ecall   <= dec_is_ecall;
            idex_is_ebreak  <= dec_is_ebreak;
            idex_is_mret    <= dec_is_mret;
            idex_predicted_taken <= ifid_predicted_taken;
        end
    end

    // =========================================================================
    // STAGE 3: EXECUTE (EX)
    // =========================================================================

    // Data forwarding muxes
    wire [1:0] fwd_a_sel;
    wire [1:0] fwd_b_sel;

    // Forwarding unit
    assign fwd_a_sel = (exmem_reg_write && exmem_valid && exmem_rd != 5'd0 &&
                        exmem_rd == idex_rs1) ? 2'b10 :
                       (memwb_reg_write && memwb_valid && memwb_rd != 5'd0 &&
                        memwb_rd == idex_rs1) ? 2'b01 : 2'b00;

    assign fwd_b_sel = (exmem_reg_write && exmem_valid && exmem_rd != 5'd0 &&
                        exmem_rd == idex_rs2) ? 2'b10 :
                       (memwb_reg_write && memwb_valid && memwb_rd != 5'd0 &&
                        memwb_rd == idex_rs2) ? 2'b01 : 2'b00;

    // Writeback data mux (for forwarding from WB stage)
    wire [31:0] wb_data;
    assign wb_data = (memwb_result_src == 2'b01) ? memwb_mem_data :
                     (memwb_result_src == 2'b10) ? memwb_pc_plus4 :
                     memwb_alu_result;

    // Forwarded operands
    wire [31:0] fwd_rs1 = (fwd_a_sel == 2'b10) ? exmem_alu_result :
                          (fwd_a_sel == 2'b01) ? wb_data :
                          idex_rs1_data;

    wire [31:0] fwd_rs2 = (fwd_b_sel == 2'b10) ? exmem_alu_result :
                          (fwd_b_sel == 2'b01) ? wb_data :
                          idex_rs2_data;

    // ALU input B selection
    wire [31:0] alu_b = idex_alu_src ? idex_imm : fwd_rs2;

    // ALU — for AUIPC, operand A is PC instead of rs1
    wire [31:0] alu_a = idex_auipc ? idex_pc : fwd_rs1;

    // =====================================================================
    // MULTI-CYCLE MULTIPLY UNIT (3-cycle iterative shift-add)
    // =====================================================================
    // Produces 64-bit result from 32x32 multiply.
    // Cycle 0: latch operands, compute partial products (lower 16 bits)
    // Cycle 1: accumulate partial products (upper 16 bits)
    // Cycle 2: result ready
    // Pipeline stalls during mul_busy.

    wire is_mul_op = idex_valid && (idex_alu_op == ALU_MUL  || idex_alu_op == ALU_MULH ||
                                    idex_alu_op == ALU_MULHSU || idex_alu_op == ALU_MULHU);

    reg  [1:0]  mul_cycle;      // 0=idle, 1=phase1, 2=done
    reg         mul_busy;
    reg  [63:0] mul_result;
    reg  [4:0]  mul_op_saved;   // which MUL variant

    // Operand sign extension for 64-bit multiply
    wire [32:0] mul_a_ext = (idex_alu_op == ALU_MULHU) ? {1'b0, alu_a} :
                            {alu_a[31], alu_a};  // signed for MUL/MULH/MULHSU
    wire [32:0] mul_b_ext = (idex_alu_op == ALU_MULHU || idex_alu_op == ALU_MULHSU) ?
                            {1'b0, alu_b} : {alu_b[31], alu_b};

    // 33x33 signed multiply split into 3 cycles via registered partial products
    reg signed [32:0] mul_a_reg, mul_b_reg;
    reg signed [65:0] mul_partial;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mul_cycle   <= 0;
            mul_busy    <= 0;
            mul_result  <= 0;
            mul_op_saved <= 0;
            mul_a_reg   <= 0;
            mul_b_reg   <= 0;
            mul_partial <= 0;
        end else if (is_mul_op && mul_cycle == 0 && !mul_busy) begin
            // Cycle 0: latch operands
            mul_a_reg    <= $signed(mul_a_ext);
            mul_b_reg    <= $signed(mul_b_ext);
            mul_op_saved <= idex_alu_op;
            mul_cycle    <= 2'd1;
            mul_busy     <= 1;
        end else if (mul_cycle == 2'd1) begin
            // Cycle 1: compute full product
            mul_partial <= mul_a_reg * mul_b_reg;
            mul_cycle   <= 2'd2;
        end else if (mul_cycle == 2'd2) begin
            // Cycle 2: latch result, done
            mul_result <= mul_partial[63:0];
            mul_cycle  <= 0;
            mul_busy   <= 0;
        end
    end

    wire mul_done  = (mul_cycle == 2'd2);
    wire mul_stall = is_mul_op && !mul_done;

    // MUL result select — read from mul_partial directly (available when mul_done=1)
    reg [31:0] mul_out;
    always @(*) begin
        case (mul_op_saved)
            ALU_MUL:    mul_out = mul_partial[31:0];
            ALU_MULH:   mul_out = mul_partial[63:32];
            ALU_MULHSU: mul_out = mul_partial[63:32];
            ALU_MULHU:  mul_out = mul_partial[63:32];
            default:    mul_out = mul_partial[31:0];
        endcase
    end

    // =====================================================================
    // ITERATIVE RESTORING DIVIDER (33-cycle)
    // =====================================================================
    // 1 cycle to latch + handle special cases (div-by-zero, overflow)
    // 32 cycles for bit-by-bit restoring division
    // Pipeline stalls during div_busy.

    wire is_div_op = idex_valid && (idex_alu_op == ALU_DIV  || idex_alu_op == ALU_DIVU ||
                                    idex_alu_op == ALU_REM  || idex_alu_op == ALU_REMU);

    reg         div_busy;
    reg  [5:0]  div_count;       // 0-32 iteration counter
    reg         div_signed;      // operation is signed (DIV/REM)
    reg         div_is_rem;      // result is remainder (REM/REMU)
    reg [31:0]  div_quotient;
    reg [31:0]  div_remainder;
    reg [31:0]  div_divisor;
    reg         div_neg_quot;    // negate quotient at end
    reg         div_neg_rem;     // negate remainder at end
    reg         div_special;     // div-by-zero or overflow handled
    reg [31:0]  div_special_q;   // special case quotient
    reg [31:0]  div_special_r;   // special case remainder

    wire div_start = is_div_op && !div_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_busy      <= 0;
            div_count     <= 0;
            div_signed    <= 0;
            div_is_rem    <= 0;
            div_quotient  <= 0;
            div_remainder <= 0;
            div_divisor   <= 0;
            div_neg_quot  <= 0;
            div_neg_rem   <= 0;
            div_special   <= 0;
            div_special_q <= 0;
            div_special_r <= 0;
        end else if (div_start) begin
            // Cycle 0: latch operands, handle special cases
            div_signed <= (idex_alu_op == ALU_DIV || idex_alu_op == ALU_REM);
            div_is_rem <= (idex_alu_op == ALU_REM || idex_alu_op == ALU_REMU);
            div_busy   <= 1;
            div_count  <= 6'd1;

            if (alu_b == 32'd0) begin
                // Division by zero: DIV=-1, DIVU=0xFFFFFFFF, REM=rs1, REMU=rs1
                div_special   <= 1;
                div_special_q <= 32'hFFFFFFFF;
                div_special_r <= alu_a;
            end else if ((idex_alu_op == ALU_DIV || idex_alu_op == ALU_REM) &&
                         alu_a == 32'h80000000 && alu_b == 32'hFFFFFFFF) begin
                // Signed overflow: -2^31 / -1
                div_special   <= 1;
                div_special_q <= 32'h80000000;
                div_special_r <= 32'd0;
            end else begin
                div_special <= 0;
                // Restoring division: quotient holds dividend, remainder starts at 0
                if ((idex_alu_op == ALU_DIV || idex_alu_op == ALU_REM) && alu_a[31])
                    div_quotient <= ~alu_a + 32'd1;
                else
                    div_quotient <= alu_a;

                if ((idex_alu_op == ALU_DIV || idex_alu_op == ALU_REM) && alu_b[31])
                    div_divisor <= ~alu_b + 32'd1;
                else
                    div_divisor <= alu_b;

                div_remainder <= 32'd0;
                // Determine result signs for signed operations
                div_neg_quot <= (idex_alu_op == ALU_DIV || idex_alu_op == ALU_REM) &&
                                (alu_a[31] ^ alu_b[31]);
                div_neg_rem  <= (idex_alu_op == ALU_DIV || idex_alu_op == ALU_REM) &&
                                alu_a[31];
            end
        end else if (div_busy && div_special) begin
            // Special case: done in 1 extra cycle
            div_busy <= 0;
        end else if (div_busy && div_count <= 6'd32) begin
            // Restoring division: one bit per cycle
            // Shift remainder left, bring in 0, subtract divisor, restore if negative
            if ({div_remainder[30:0], div_quotient[31]} >= {1'b0, div_divisor}) begin
                div_remainder <= {div_remainder[30:0], div_quotient[31]} - div_divisor;
                div_quotient  <= {div_quotient[30:0], 1'b1};
            end else begin
                div_remainder <= {div_remainder[30:0], div_quotient[31]};
                div_quotient  <= {div_quotient[30:0], 1'b0};
            end
            div_count <= div_count + 6'd1;
        end else if (div_busy && div_count > 6'd32) begin
            // Done — just clear busy (sign correction applied combinationally in div_out)
            div_busy <= 0;
        end
    end

    wire div_done  = div_busy && (div_special ? 1'b1 :
                     (div_count > 6'd32));
    wire div_stall = is_div_op && !div_done;

    // Apply sign correction combinationally (unsigned divider, fix signs at output)
    wire [31:0] div_quot_final = div_neg_quot ? (~div_quotient + 32'd1) : div_quotient;
    wire [31:0] div_rem_final  = div_neg_rem  ? (~div_remainder + 32'd1) : div_remainder;
    wire [31:0] div_out = div_special ? (div_is_rem ? div_special_r : div_special_q) :
                          div_is_rem  ? div_rem_final : div_quot_final;

    // =====================================================================
    // MUL/DIV pipeline stall
    // =====================================================================
    wire mul_div_stall = mul_stall || div_stall;

    // ALU core
    reg [31:0] alu_result;
    always @(*) begin
        case (idex_alu_op)
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
            ALU_MUL, ALU_MULH, ALU_MULHSU, ALU_MULHU:
                        alu_result = mul_out;
            ALU_DIV, ALU_DIVU, ALU_REM, ALU_REMU:
                        alu_result = div_out;
            default:    alu_result = 32'd0;
        endcase
    end

    // =====================================================================
    // CSR REGISTER FILE (Machine-mode)
    // =====================================================================
    // mstatus bit map: [3]=MIE, [7]=MPIE, [12:11]=MPP
    localparam CSR_MSTATUS  = 12'h300;
    localparam CSR_MIE      = 12'h304;
    localparam CSR_MTVEC    = 12'h305;
    localparam CSR_MEPC     = 12'h341;
    localparam CSR_MCAUSE   = 12'h342;
    localparam CSR_MIP      = 12'h344;
    localparam CSR_MCYCLE   = 12'hB00;
    localparam CSR_MCYCLEH  = 12'hB80;
    localparam CSR_MINSTRET = 12'hB02;
    localparam CSR_MINSTRETH = 12'hB82;

    reg [31:0] csr_mstatus;
    reg [31:0] csr_mie;
    reg [31:0] csr_mtvec;
    reg [31:0] csr_mepc;
    reg [31:0] csr_mcause;
    reg [31:0] csr_mip;
    reg [63:0] csr_mcycle;
    reg [63:0] csr_minstret;

    // CSR read multiplexer (combinational)
    reg [31:0] csr_rdata;
    always @(*) begin
        case (idex_csr_addr)
            CSR_MSTATUS:  csr_rdata = csr_mstatus;
            CSR_MIE:      csr_rdata = csr_mie;
            CSR_MTVEC:    csr_rdata = csr_mtvec;
            CSR_MEPC:     csr_rdata = csr_mepc;
            CSR_MCAUSE:   csr_rdata = csr_mcause;
            CSR_MIP:      csr_rdata = csr_mip;
            CSR_MCYCLE:   csr_rdata = csr_mcycle[31:0];
            CSR_MCYCLEH:  csr_rdata = csr_mcycle[63:32];
            CSR_MINSTRET: csr_rdata = csr_minstret[31:0];
            CSR_MINSTRETH: csr_rdata = csr_minstret[63:32];
            default:      csr_rdata = 32'd0;
        endcase
    end

    // CSR operand: rs1 value for non-I, zero-extended uimm for I variants
    wire [31:0] csr_operand = idex_funct3[2] ? {27'd0, idex_rs1} : fwd_rs1;

    // CSR write data computation
    reg [31:0] csr_wdata;
    always @(*) begin
        case (idex_funct3[1:0])
            2'b01:   csr_wdata = csr_operand;              // CSRRW/CSRRWI
            2'b10:   csr_wdata = csr_rdata | csr_operand;  // CSRRS/CSRRSI
            2'b11:   csr_wdata = csr_rdata & ~csr_operand; // CSRRC/CSRRCI
            default: csr_wdata = 32'd0;
        endcase
    end

    // Exception/MRET detection
    wire ex_ecall  = idex_valid && idex_is_ecall;
    wire ex_ebreak = idex_valid && idex_is_ebreak;
    wire ex_mret   = idex_valid && idex_is_mret;
    wire ex_trap   = ex_ecall || ex_ebreak;
    wire ex_csr_write = idex_valid && idex_csr_op && idex_csr_write;

    // Trap vector computation (direct mode only: mtvec[1:0]=00)
    wire [31:0] trap_target = {csr_mtvec[31:2], 2'b00};
    wire [31:0] mret_target = csr_mepc;

    // CSR write and exception handling (sequential)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csr_mstatus  <= 32'h0000_1800; // MPP=11 (M-mode)
            csr_mie      <= 32'd0;
            csr_mtvec    <= 32'd0;
            csr_mepc     <= 32'd0;
            csr_mcause   <= 32'd0;
            csr_mip      <= 32'd0;
            csr_mcycle   <= 64'd0;
            csr_minstret <= 64'd0;
        end else begin
            // Cycle counter increments every clock
            csr_mcycle <= csr_mcycle + 64'd1;

            // Instruction retire counter
            if (memwb_valid && !mem_stall && !mul_div_stall)
                csr_minstret <= csr_minstret + 64'd1;

            // Exception: ECALL or EBREAK
            if (ex_trap) begin
                csr_mepc    <= idex_pc;
                csr_mcause  <= ex_ecall ? 32'd11 : 32'd3;
                csr_mstatus[7]    <= csr_mstatus[3];  // MPIE <= MIE
                csr_mstatus[3]    <= 1'b0;             // MIE <= 0
                csr_mstatus[12:11] <= 2'b11;           // MPP <= M-mode
            end
            // MRET
            else if (ex_mret) begin
                csr_mstatus[3]    <= csr_mstatus[7];  // MIE <= MPIE
                csr_mstatus[7]    <= 1'b1;             // MPIE <= 1
                csr_mstatus[12:11] <= 2'b11;           // MPP <= M-mode
            end
            // CSR instruction write (lower priority than exception)
            else if (ex_csr_write) begin
                case (idex_csr_addr)
                    CSR_MSTATUS:  csr_mstatus <= csr_wdata & 32'h0000_1888;
                    CSR_MIE:      csr_mie     <= csr_wdata;
                    CSR_MTVEC:    csr_mtvec   <= csr_wdata;
                    CSR_MEPC:     csr_mepc    <= {csr_wdata[31:2], 2'b00};
                    CSR_MCAUSE:   csr_mcause  <= csr_wdata;
                    CSR_MIP:      ; // MIP is read-only (set by external interrupts)
                    CSR_MCYCLE:   csr_mcycle[31:0]   <= csr_wdata;
                    CSR_MCYCLEH:  csr_mcycle[63:32]  <= csr_wdata;
                    CSR_MINSTRET: csr_minstret[31:0] <= csr_wdata;
                    CSR_MINSTRETH: csr_minstret[63:32] <= csr_wdata;
                    default: ;
                endcase
            end
        end
    end

    // Branch comparison unit
    reg branch_cond;
    always @(*) begin
        case (idex_funct3)
            3'b000: branch_cond = (fwd_rs1 == fwd_rs2);                         // BEQ
            3'b001: branch_cond = (fwd_rs1 != fwd_rs2);                         // BNE
            3'b100: branch_cond = ($signed(fwd_rs1) < $signed(fwd_rs2));         // BLT
            3'b101: branch_cond = ($signed(fwd_rs1) >= $signed(fwd_rs2));        // BGE
            3'b110: branch_cond = (fwd_rs1 < fwd_rs2);                          // BLTU
            3'b111: branch_cond = (fwd_rs1 >= fwd_rs2);                         // BGEU
            default: branch_cond = 0;
        endcase
    end

    // =====================================================================
    // BRANCH PREDICTION RESOLUTION (EX stage)
    // =====================================================================
    // Actual branch outcome
    wire ex_actually_taken = (idex_branch && branch_cond) || idex_jal;
    wire [31:0] ex_computed_target = idex_pc + idex_imm;

    // Recovery PC: where should we go if prediction was wrong?
    wire [31:0] ex_recovery_pc = ex_actually_taken ? ex_computed_target
                                                   : (idex_pc + 32'd4);

    // Misprediction: wrong direction OR wrong target (branches + JAL only)
    wire ex_mispredict = idex_valid && (idex_branch || idex_jal) &&
                         (idex_predicted_taken != ex_actually_taken);

    // Unpredicted redirects: JALR, traps, MRET (always flush)
    wire ex_unpredicted_redirect = idex_valid &&
        (idex_jalr || idex_is_ecall || idex_is_ebreak || idex_is_mret);

    // Pipeline flush = misprediction correction OR unpredicted redirect
    assign pipeline_flush = ex_mispredict || ex_unpredicted_redirect;

    // Branch target: correction address for mispredictions, or normal redirect
    assign branch_target = ex_trap   ? trap_target :
                           ex_mret   ? mret_target :
                           idex_jalr ? (fwd_rs1 + idex_imm) & ~32'd1 :
                           ex_recovery_pc;

    // BHT + BTB update (sequential, in EX stage on branch/JAL commit)
    wire [5:0] bht_idx_ex = idex_pc[7:2];
    wire ex_is_branch_or_jal = idex_valid && (idex_branch || idex_jal) &&
                               !mem_stall && !mul_div_stall;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin : bht_btb_reset
            integer k;
            for (k = 0; k < 64; k = k + 1) begin
                bht[k]        <= 2'b01;  // Weakly not-taken
                btb_valid[k]  <= 1'b0;
                btb_tag[k]    <= 24'd0;
                btb_target[k] <= 32'd0;
            end
        end else if (ex_is_branch_or_jal) begin
            // Update BTB: store target and tag
            btb_target[bht_idx_ex] <= ex_computed_target;
            btb_tag[bht_idx_ex]    <= idex_pc[31:8];
            btb_valid[bht_idx_ex]  <= 1'b1;

            // Update BHT: 2-bit saturating counter (branches only, not JAL)
            if (idex_branch) begin
                if (branch_cond && bht[bht_idx_ex] != 2'b11)
                    bht[bht_idx_ex] <= bht[bht_idx_ex] + 2'b01;  // Increment toward taken
                else if (!branch_cond && bht[bht_idx_ex] != 2'b00)
                    bht[bht_idx_ex] <= bht[bht_idx_ex] - 2'b01;  // Decrement toward not-taken
            end
        end
    end

    // EX/MEM register update
    wire [31:0] ex_pc_plus4 = idex_pc + 32'd4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exmem_alu_result <= 0;
            exmem_rs2_data   <= 0;
            exmem_pc_plus4   <= 0;
            exmem_rd         <= 0;
            exmem_mem_read   <= 0;
            exmem_mem_write  <= 0;
            exmem_mem_size   <= 0;
            exmem_reg_write  <= 0;
            exmem_result_src <= 0;
            exmem_valid      <= 0;
        end else if (!mem_stall && !mul_div_stall) begin
            exmem_alu_result <= idex_csr_op ? csr_rdata : alu_result;
            exmem_rs2_data   <= fwd_rs2;
            exmem_pc_plus4   <= ex_pc_plus4;
            exmem_rd         <= idex_rd;
            exmem_mem_read   <= idex_mem_read;
            exmem_mem_write  <= idex_mem_write;
            exmem_mem_size   <= idex_mem_size;
            exmem_reg_write  <= idex_reg_write;
            exmem_result_src <= idex_result_src;
            exmem_valid      <= idex_valid;
        end
    end

    // =========================================================================
    // STAGE 4: MEMORY ACCESS (MEM)
    // =========================================================================

    // Store data alignment and byte strobe generation
    reg [31:0] store_data;
    reg  [3:0] store_strb;

    always @(*) begin
        case (exmem_mem_size[1:0])
            2'b00: begin // SB
                case (exmem_alu_result[1:0])
                    2'b00: begin store_data = {24'd0, exmem_rs2_data[7:0]};
                                 store_strb = 4'b0001; end
                    2'b01: begin store_data = {16'd0, exmem_rs2_data[7:0], 8'd0};
                                 store_strb = 4'b0010; end
                    2'b10: begin store_data = {8'd0, exmem_rs2_data[7:0], 16'd0};
                                 store_strb = 4'b0100; end
                    2'b11: begin store_data = {exmem_rs2_data[7:0], 24'd0};
                                 store_strb = 4'b1000; end
                endcase
            end
            2'b01: begin // SH
                case (exmem_alu_result[1])
                    1'b0: begin store_data = {16'd0, exmem_rs2_data[15:0]};
                                store_strb = 4'b0011; end
                    1'b1: begin store_data = {exmem_rs2_data[15:0], 16'd0};
                                store_strb = 4'b1100; end
                endcase
            end
            default: begin // SW
                store_data = exmem_rs2_data;
                store_strb = 4'b1111;
            end
        endcase
    end

    // Data memory interface
    assign dmem_addr  = {exmem_alu_result[31:2], 2'b00};
    assign dmem_wdata = store_data;
    assign dmem_wstrb = exmem_mem_write ? store_strb : 4'b0000;
    assign dmem_req   = (exmem_mem_read || exmem_mem_write) && exmem_valid;

    // Load data alignment and sign extension
    reg [31:0] load_data;
    always @(*) begin
        case (exmem_mem_size)
            3'b000: begin // LB (sign-extended)
                case (exmem_alu_result[1:0])
                    2'b00: load_data = {{24{dmem_rdata[7]}},  dmem_rdata[7:0]};
                    2'b01: load_data = {{24{dmem_rdata[15]}}, dmem_rdata[15:8]};
                    2'b10: load_data = {{24{dmem_rdata[23]}}, dmem_rdata[23:16]};
                    2'b11: load_data = {{24{dmem_rdata[31]}}, dmem_rdata[31:24]};
                endcase
            end
            3'b001: begin // LH (sign-extended)
                case (exmem_alu_result[1])
                    1'b0: load_data = {{16{dmem_rdata[15]}}, dmem_rdata[15:0]};
                    1'b1: load_data = {{16{dmem_rdata[31]}}, dmem_rdata[31:16]};
                endcase
            end
            3'b010: load_data = dmem_rdata; // LW
            3'b100: begin // LBU (zero-extended)
                case (exmem_alu_result[1:0])
                    2'b00: load_data = {24'd0, dmem_rdata[7:0]};
                    2'b01: load_data = {24'd0, dmem_rdata[15:8]};
                    2'b10: load_data = {24'd0, dmem_rdata[23:16]};
                    2'b11: load_data = {24'd0, dmem_rdata[31:24]};
                endcase
            end
            3'b101: begin // LHU (zero-extended)
                case (exmem_alu_result[1])
                    1'b0: load_data = {16'd0, dmem_rdata[15:0]};
                    1'b1: load_data = {16'd0, dmem_rdata[31:16]};
                endcase
            end
            default: load_data = dmem_rdata;
        endcase
    end

    // MEM/WB register update
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            memwb_alu_result <= 0;
            memwb_mem_data   <= 0;
            memwb_pc_plus4   <= 0;
            memwb_rd         <= 0;
            memwb_reg_write  <= 0;
            memwb_result_src <= 0;
            memwb_valid      <= 0;
        end else if (!mem_stall && !mul_div_stall) begin
            memwb_alu_result <= exmem_alu_result;
            memwb_mem_data   <= load_data;
            memwb_pc_plus4   <= exmem_pc_plus4;
            memwb_rd         <= exmem_rd;
            memwb_reg_write  <= exmem_reg_write;
            memwb_result_src <= exmem_result_src;
            memwb_valid      <= exmem_valid;
        end
    end

    // =========================================================================
    // STAGE 5: WRITE BACK (WB)
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (idx = 0; idx < 32; idx = idx + 1)
                regfile[idx] <= 32'd0;
        end else if (memwb_reg_write && memwb_valid && memwb_rd != 5'd0) begin
            regfile[memwb_rd] <= wb_data;
        end
    end

endmodule
