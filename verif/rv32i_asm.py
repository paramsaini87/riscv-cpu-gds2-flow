#!/usr/bin/env python3
"""RV32IM Micro-Assembler — Two-pass assembler with label support.
Encodes all 37 RV32I + 8 RV32M + 6 CSR instructions + pseudo-instructions.
Outputs hex files for $readmemh in iverilog testbench."""

import struct, sys

# CSR address constants
CSR_MSTATUS  = 0x300
CSR_MIE      = 0x304
CSR_MTVEC    = 0x305
CSR_MEPC     = 0x341
CSR_MCAUSE   = 0x342
CSR_MIP      = 0x344
CSR_MCYCLE   = 0xB00
CSR_MCYCLEH  = 0xB80
CSR_MINSTRET = 0xB02
CSR_MINSTRETH= 0xB82

# Register ABI name mapping
REG = {f'x{i}': i for i in range(32)}
REG.update({
    'zero': 0, 'ra': 1, 'sp': 2, 'gp': 3, 'tp': 4,
    't0': 5, 't1': 6, 't2': 7,
    's0': 8, 'fp': 8, 's1': 9,
    'a0': 10, 'a1': 11, 'a2': 12, 'a3': 13,
    'a4': 14, 'a5': 15, 'a6': 16, 'a7': 17,
    's2': 18, 's3': 19, 's4': 20, 's5': 21,
    's6': 22, 's7': 23, 's8': 24, 's9': 25,
    's10': 26, 's11': 27,
    't3': 28, 't4': 29, 't5': 30, 't6': 31
})

def reg(name):
    if isinstance(name, int): return name
    return REG[name.lower().strip()]

def sext(val, bits):
    """Sign-extend val to 32 bits from given bit width."""
    mask = (1 << bits) - 1
    val = val & mask
    if val & (1 << (bits - 1)):
        val -= (1 << bits)
    return val

def creg(name):
    """Convert register name to 3-bit compressed register index (x8-x15 → 0-7)."""
    r = reg(name)
    assert 8 <= r <= 15, f"Compressed register must be x8-x15, got x{r}"
    return r - 8

def _encode_cj_offset(offset):
    """Encode CJ-type offset into bits [12:2] of a C.J/C.JAL instruction."""
    return (((offset >> 11) & 0x1) << 12) | \
           (((offset >> 4) & 0x1) << 11) | \
           (((offset >> 8) & 0x3) << 9) | \
           (((offset >> 10) & 0x1) << 8) | \
           (((offset >> 6) & 0x1) << 7) | \
           (((offset >> 7) & 0x1) << 6) | \
           (((offset >> 1) & 0x7) << 3) | \
           (((offset >> 5) & 0x1) << 2)

def _encode_cb_offset(offset):
    """Encode CB-type offset into bits of a C.BEQZ/C.BNEZ instruction."""
    return (((offset >> 8) & 0x1) << 12) | \
           (((offset >> 3) & 0x3) << 10) | \
           (((offset >> 6) & 0x3) << 5) | \
           (((offset >> 1) & 0x3) << 3) | \
           (((offset >> 5) & 0x1) << 2)

def encode_r(funct7, rs2, rs1, funct3, rd, opcode):
    return ((funct7 & 0x7F) << 25) | ((reg(rs2) & 0x1F) << 20) | \
           ((reg(rs1) & 0x1F) << 15) | ((funct3 & 0x7) << 12) | \
           ((reg(rd) & 0x1F) << 7) | (opcode & 0x7F)

def encode_i(imm, rs1, funct3, rd, opcode):
    return ((imm & 0xFFF) << 20) | ((reg(rs1) & 0x1F) << 15) | \
           ((funct3 & 0x7) << 12) | ((reg(rd) & 0x1F) << 7) | (opcode & 0x7F)

def encode_s(imm, rs2, rs1, funct3, opcode):
    imm7 = (imm >> 5) & 0x7F
    imm5 = imm & 0x1F
    return (imm7 << 25) | ((reg(rs2) & 0x1F) << 20) | \
           ((reg(rs1) & 0x1F) << 15) | ((funct3 & 0x7) << 12) | \
           (imm5 << 7) | (opcode & 0x7F)

def encode_b(imm, rs2, rs1, funct3, opcode):
    i12  = (imm >> 12) & 0x1
    i105 = (imm >> 5) & 0x3F
    i41  = (imm >> 1) & 0xF
    i11  = (imm >> 11) & 0x1
    return (i12 << 31) | (i105 << 25) | ((reg(rs2) & 0x1F) << 20) | \
           ((reg(rs1) & 0x1F) << 15) | ((funct3 & 0x7) << 12) | \
           (i41 << 8) | (i11 << 7) | (opcode & 0x7F)

def encode_u(imm, rd, opcode):
    return ((imm & 0xFFFFF) << 12) | ((reg(rd) & 0x1F) << 7) | (opcode & 0x7F)

def encode_j(imm, rd, opcode):
    i20  = (imm >> 20) & 0x1
    i101 = (imm >> 1) & 0x3FF
    i11  = (imm >> 11) & 0x1
    i1912 = (imm >> 12) & 0xFF
    return (i20 << 31) | (i101 << 21) | (i11 << 20) | \
           (i1912 << 12) | ((reg(rd) & 0x1F) << 7) | (opcode & 0x7F)


class Program:
    """Two-pass RV32I assembler with label support."""

    TOHOST_ADDR = 0x1000  # Memory-mapped test completion register
    _fail_cnt = 0  # Class-level counter for unique FAIL halt labels

    def __init__(self):
        self.ops = []  # list of (label_or_None, instr_func_or_None, args)

    # --- Label ---
    def label(self, name):
        self.ops.append((name, None, None))

    def _emit(self, fn, args):
        self.ops.append((None, fn, args))

    def ALIGN4(self):
        """Emit C.NOP if needed to align next instruction to 4-byte boundary."""
        self._emit('align4', None)

    # === R-TYPE ===
    def ADD(self, rd, rs1, rs2):   self._emit('r', (0x00, rs2, rs1, 0, rd, 0x33))
    def SUB(self, rd, rs1, rs2):   self._emit('r', (0x20, rs2, rs1, 0, rd, 0x33))
    def SLL(self, rd, rs1, rs2):   self._emit('r', (0x00, rs2, rs1, 1, rd, 0x33))
    def SLT(self, rd, rs1, rs2):   self._emit('r', (0x00, rs2, rs1, 2, rd, 0x33))
    def SLTU(self, rd, rs1, rs2):  self._emit('r', (0x00, rs2, rs1, 3, rd, 0x33))
    def XOR(self, rd, rs1, rs2):   self._emit('r', (0x00, rs2, rs1, 4, rd, 0x33))
    def SRL(self, rd, rs1, rs2):   self._emit('r', (0x00, rs2, rs1, 5, rd, 0x33))
    def SRA(self, rd, rs1, rs2):   self._emit('r', (0x20, rs2, rs1, 5, rd, 0x33))
    def OR(self, rd, rs1, rs2):    self._emit('r', (0x00, rs2, rs1, 6, rd, 0x33))
    def AND(self, rd, rs1, rs2):   self._emit('r', (0x00, rs2, rs1, 7, rd, 0x33))

    # === M-EXTENSION (MULTIPLY/DIVIDE) ===
    def MUL(self, rd, rs1, rs2):    self._emit('r', (0x01, rs2, rs1, 0, rd, 0x33))
    def MULH(self, rd, rs1, rs2):   self._emit('r', (0x01, rs2, rs1, 1, rd, 0x33))
    def MULHSU(self, rd, rs1, rs2): self._emit('r', (0x01, rs2, rs1, 2, rd, 0x33))
    def MULHU(self, rd, rs1, rs2):  self._emit('r', (0x01, rs2, rs1, 3, rd, 0x33))
    def DIV(self, rd, rs1, rs2):    self._emit('r', (0x01, rs2, rs1, 4, rd, 0x33))
    def DIVU(self, rd, rs1, rs2):   self._emit('r', (0x01, rs2, rs1, 5, rd, 0x33))
    def REM(self, rd, rs1, rs2):    self._emit('r', (0x01, rs2, rs1, 6, rd, 0x33))
    def REMU(self, rd, rs1, rs2):   self._emit('r', (0x01, rs2, rs1, 7, rd, 0x33))

    # === I-TYPE (ALU) ===
    def ADDI(self, rd, rs1, imm):  self._emit('i', (imm, rs1, 0, rd, 0x13))
    def SLTI(self, rd, rs1, imm):  self._emit('i', (imm, rs1, 2, rd, 0x13))
    def SLTIU(self, rd, rs1, imm): self._emit('i', (imm, rs1, 3, rd, 0x13))
    def XORI(self, rd, rs1, imm):  self._emit('i', (imm, rs1, 4, rd, 0x13))
    def ORI(self, rd, rs1, imm):   self._emit('i', (imm, rs1, 6, rd, 0x13))
    def ANDI(self, rd, rs1, imm):  self._emit('i', (imm, rs1, 7, rd, 0x13))
    def SLLI(self, rd, rs1, shamt):self._emit('i', (shamt & 0x1F, rs1, 1, rd, 0x13))
    def SRLI(self, rd, rs1, shamt):self._emit('i', (shamt & 0x1F, rs1, 5, rd, 0x13))
    def SRAI(self, rd, rs1, shamt):self._emit('i', (0x400 | (shamt & 0x1F), rs1, 5, rd, 0x13))

    # === LOAD ===
    def LB(self, rd, off, rs1):    self._emit('i', (off, rs1, 0, rd, 0x03))
    def LH(self, rd, off, rs1):    self._emit('i', (off, rs1, 1, rd, 0x03))
    def LW(self, rd, off, rs1):    self._emit('i', (off, rs1, 2, rd, 0x03))
    def LBU(self, rd, off, rs1):   self._emit('i', (off, rs1, 4, rd, 0x03))
    def LHU(self, rd, off, rs1):   self._emit('i', (off, rs1, 5, rd, 0x03))

    # === STORE ===
    def SB(self, rs2, off, rs1):   self._emit('s', (off, rs2, rs1, 0, 0x23))
    def SH(self, rs2, off, rs1):   self._emit('s', (off, rs2, rs1, 1, 0x23))
    def SW(self, rs2, off, rs1):   self._emit('s', (off, rs2, rs1, 2, 0x23))

    # === BRANCH ===
    def BEQ(self, rs1, rs2, label):  self._emit('b', (label, rs2, rs1, 0, 0x63))
    def BNE(self, rs1, rs2, label):  self._emit('b', (label, rs2, rs1, 1, 0x63))
    def BLT(self, rs1, rs2, label):  self._emit('b', (label, rs2, rs1, 4, 0x63))
    def BGE(self, rs1, rs2, label):  self._emit('b', (label, rs2, rs1, 5, 0x63))
    def BLTU(self, rs1, rs2, label): self._emit('b', (label, rs2, rs1, 6, 0x63))
    def BGEU(self, rs1, rs2, label): self._emit('b', (label, rs2, rs1, 7, 0x63))

    # === U-TYPE ===
    def LUI(self, rd, imm):   self._emit('u', (imm, rd, 0x37))
    def AUIPC(self, rd, imm): self._emit('u', (imm, rd, 0x17))

    # === JUMP ===
    def JAL(self, rd, label):      self._emit('j', (label, rd, 0x6F))
    def JALR(self, rd, rs1, imm):  self._emit('i', (imm, rs1, 0, rd, 0x67))

    # === SYSTEM ===
    def ECALL(self):   self._emit('i', (0, 'x0', 0, 'x0', 0x73))
    def EBREAK(self):  self._emit('i', (1, 'x0', 0, 'x0', 0x73))
    def FENCE(self):   self._emit('i', (0x0FF, 'x0', 0, 'x0', 0x0F))
    def MRET(self):    self._emit('i', (0x302, 'x0', 0, 'x0', 0x73))

    # === CSR INSTRUCTIONS ===
    def CSRRW(self, rd, csr, rs1):   self._emit('i', (csr, rs1, 1, rd, 0x73))
    def CSRRS(self, rd, csr, rs1):   self._emit('i', (csr, rs1, 2, rd, 0x73))
    def CSRRC(self, rd, csr, rs1):   self._emit('i', (csr, rs1, 3, rd, 0x73))
    def CSRRWI(self, rd, csr, uimm): self._emit('i', (csr, f'x{uimm}', 5, rd, 0x73))
    def CSRRSI(self, rd, csr, uimm): self._emit('i', (csr, f'x{uimm}', 6, rd, 0x73))
    def CSRRCI(self, rd, csr, uimm): self._emit('i', (csr, f'x{uimm}', 7, rd, 0x73))


    # === WFI ===
    def WFI(self):  self._emit('i', (0x105, 'x0', 0, 'x0', 0x73))

    # === RV32C COMPRESSED INSTRUCTIONS ===
    # Quadrant 0 (bits[1:0] = 00)
    def C_ADDI4SPN(self, rd_c, nzuimm):
        rd3 = creg(rd_c)
        bits = (0b000 << 13) | (((nzuimm >> 4) & 0x3) << 11) | (((nzuimm >> 6) & 0xF) << 7) | \
               (((nzuimm >> 2) & 0x1) << 6) | (((nzuimm >> 3) & 0x1) << 5) | (rd3 << 2) | 0b00
        self._emit('c16', bits)

    def C_LW(self, rd_c, rs1_c, offset):
        rd3 = creg(rd_c); rs13 = creg(rs1_c)
        bits = (0b010 << 13) | (((offset >> 3) & 0x7) << 10) | (rs13 << 7) | \
               (((offset >> 2) & 0x1) << 6) | (((offset >> 6) & 0x1) << 5) | (rd3 << 2) | 0b00
        self._emit('c16', bits)

    def C_SW(self, rs2_c, rs1_c, offset):
        rs23 = creg(rs2_c); rs13 = creg(rs1_c)
        bits = (0b110 << 13) | (((offset >> 5) & 0x1) << 12) | (((offset >> 3) & 0x3) << 10) | \
               (rs13 << 7) | (((offset >> 2) & 0x1) << 6) | (((offset >> 6) & 0x1) << 5) | (rs23 << 2) | 0b00
        self._emit('c16', bits)

    # Quadrant 1 (bits[1:0] = 01)
    def C_NOP(self):
        self._emit('c16', 0b000_0_00000_00000_01)

    def C_ADDI(self, rd, nzimm):
        r = reg(rd)
        bits = (0b000 << 13) | (((nzimm >> 5) & 0x1) << 12) | (r << 7) | ((nzimm & 0x1F) << 2) | 0b01
        self._emit('c16', bits)

    def C_JAL(self, label):
        def encode(offset):
            return (0b001 << 13) | _encode_cj_offset(offset) | 0b01
        self._emit('cj', (label, encode))

    def C_LI(self, rd, imm):
        r = reg(rd)
        bits = (0b010 << 13) | (((imm >> 5) & 0x1) << 12) | (r << 7) | ((imm & 0x1F) << 2) | 0b01
        self._emit('c16', bits)

    def C_ADDI16SP(self, nzimm):
        bits = (0b011 << 13) | (((nzimm >> 9) & 0x1) << 12) | (2 << 7) | \
               (((nzimm >> 4) & 0x1) << 6) | (((nzimm >> 6) & 0x1) << 5) | \
               (((nzimm >> 7) & 0x3) << 3) | (((nzimm >> 5) & 0x1) << 2) | 0b01
        self._emit('c16', bits)

    def C_LUI(self, rd, nzimm):
        r = reg(rd)
        bits = (0b011 << 13) | (((nzimm >> 5) & 0x1) << 12) | (r << 7) | ((nzimm & 0x1F) << 2) | 0b01
        self._emit('c16', bits)

    def C_SRLI(self, rd_c, shamt):
        rd3 = creg(rd_c)
        bits = (0b100 << 13) | (0 << 12) | (0b00 << 10) | (rd3 << 7) | ((shamt & 0x1F) << 2) | 0b01
        self._emit('c16', bits)

    def C_SRAI(self, rd_c, shamt):
        rd3 = creg(rd_c)
        bits = (0b100 << 13) | (0 << 12) | (0b01 << 10) | (rd3 << 7) | ((shamt & 0x1F) << 2) | 0b01
        self._emit('c16', bits)

    def C_ANDI(self, rd_c, imm):
        rd3 = creg(rd_c)
        bits = (0b100 << 13) | (((imm >> 5) & 0x1) << 12) | (0b10 << 10) | (rd3 << 7) | ((imm & 0x1F) << 2) | 0b01
        self._emit('c16', bits)

    def C_SUB(self, rd_c, rs2_c):
        rd3 = creg(rd_c); rs23 = creg(rs2_c)
        bits = (0b100 << 13) | (0 << 12) | (0b11 << 10) | (rd3 << 7) | (0b00 << 5) | (rs23 << 2) | 0b01
        self._emit('c16', bits)

    def C_XOR(self, rd_c, rs2_c):
        rd3 = creg(rd_c); rs23 = creg(rs2_c)
        bits = (0b100 << 13) | (0 << 12) | (0b11 << 10) | (rd3 << 7) | (0b01 << 5) | (rs23 << 2) | 0b01
        self._emit('c16', bits)

    def C_OR(self, rd_c, rs2_c):
        rd3 = creg(rd_c); rs23 = creg(rs2_c)
        bits = (0b100 << 13) | (0 << 12) | (0b11 << 10) | (rd3 << 7) | (0b10 << 5) | (rs23 << 2) | 0b01
        self._emit('c16', bits)

    def C_AND(self, rd_c, rs2_c):
        rd3 = creg(rd_c); rs23 = creg(rs2_c)
        bits = (0b100 << 13) | (0 << 12) | (0b11 << 10) | (rd3 << 7) | (0b11 << 5) | (rs23 << 2) | 0b01
        self._emit('c16', bits)

    def C_J(self, label):
        def encode(offset):
            return (0b101 << 13) | _encode_cj_offset(offset) | 0b01
        self._emit('cj', (label, encode))

    def C_BEQZ(self, rs1_c, label):
        rs13 = creg(rs1_c)
        def encode(offset):
            return (0b110 << 13) | _encode_cb_offset(offset) | (rs13 << 7) | 0b01
        self._emit('cb', (label, encode))

    def C_BNEZ(self, rs1_c, label):
        rs13 = creg(rs1_c)
        def encode(offset):
            return (0b111 << 13) | _encode_cb_offset(offset) | (rs13 << 7) | 0b01
        self._emit('cb', (label, encode))

    # Quadrant 2 (bits[1:0] = 10)
    def C_SLLI(self, rd, shamt):
        r = reg(rd)
        bits = (0b000 << 13) | (0 << 12) | (r << 7) | ((shamt & 0x1F) << 2) | 0b10
        self._emit('c16', bits)

    def C_LWSP(self, rd, offset):
        r = reg(rd)
        bits = (0b010 << 13) | (((offset >> 5) & 0x1) << 12) | (r << 7) | \
               (((offset >> 2) & 0x7) << 4) | (((offset >> 6) & 0x3) << 2) | 0b10
        self._emit('c16', bits)

    def C_JR(self, rs1):
        r = reg(rs1)
        bits = (0b100 << 13) | (0 << 12) | (r << 7) | (0 << 2) | 0b10
        self._emit('c16', bits)

    def C_MV(self, rd, rs2):
        rd_r = reg(rd); rs2_r = reg(rs2)
        bits = (0b100 << 13) | (0 << 12) | (rd_r << 7) | (rs2_r << 2) | 0b10
        self._emit('c16', bits)

    def C_EBREAK(self):
        self._emit('c16', 0x9002)

    def C_JALR(self, rs1):
        r = reg(rs1)
        bits = (0b100 << 13) | (1 << 12) | (r << 7) | (0 << 2) | 0b10
        self._emit('c16', bits)

    def C_ADD(self, rd, rs2):
        rd_r = reg(rd); rs2_r = reg(rs2)
        bits = (0b100 << 13) | (1 << 12) | (rd_r << 7) | (rs2_r << 2) | 0b10
        self._emit('c16', bits)

    def C_SWSP(self, rs2, offset):
        rs2_r = reg(rs2)
        bits = (0b110 << 13) | (((offset >> 5) & 0x1) << 12) | (((offset >> 2) & 0x7) << 9) | \
               (((offset >> 6) & 0x3) << 7) | (rs2_r << 2) | 0b10
        self._emit('c16', bits)

    # === RV32A ATOMIC INSTRUCTIONS ===
    def _amo(self, funct5, aq, rl, rs2, rs1, funct3, rd):
        """Encode AMO-type instruction."""
        funct7 = (funct5 << 2) | (aq << 1) | rl
        self._emit('r', (funct7, rs2, rs1, funct3, rd, 0x2F))

    def LR_W(self, rd, rs1, aq=0, rl=0):
        self._amo(0b00010, aq, rl, 'x0', rs1, 0b010, rd)

    def SC_W(self, rd, rs1, rs2, aq=0, rl=0):
        self._amo(0b00011, aq, rl, rs2, rs1, 0b010, rd)

    def AMOSWAP_W(self, rd, rs2, rs1, aq=0, rl=0):
        self._amo(0b00001, aq, rl, rs2, rs1, 0b010, rd)

    def AMOADD_W(self, rd, rs2, rs1, aq=0, rl=0):
        self._amo(0b00000, aq, rl, rs2, rs1, 0b010, rd)

    def AMOAND_W(self, rd, rs2, rs1, aq=0, rl=0):
        self._amo(0b01100, aq, rl, rs2, rs1, 0b010, rd)

    def AMOOR_W(self, rd, rs2, rs1, aq=0, rl=0):
        self._amo(0b01000, aq, rl, rs2, rs1, 0b010, rd)

    def AMOXOR_W(self, rd, rs2, rs1, aq=0, rl=0):
        self._amo(0b00100, aq, rl, rs2, rs1, 0b010, rd)

    def AMOMIN_W(self, rd, rs2, rs1, aq=0, rl=0):
        self._amo(0b10000, aq, rl, rs2, rs1, 0b010, rd)

    def AMOMAX_W(self, rd, rs2, rs1, aq=0, rl=0):
        self._amo(0b10100, aq, rl, rs2, rs1, 0b010, rd)

    def AMOMINU_W(self, rd, rs2, rs1, aq=0, rl=0):
        self._amo(0b11000, aq, rl, rs2, rs1, 0b010, rd)

    def AMOMAXU_W(self, rd, rs2, rs1, aq=0, rl=0):
        self._amo(0b11100, aq, rl, rs2, rs1, 0b010, rd)

    # === RAW INSTRUCTION ===
    def RAW(self, word):
        """Emit a raw 32-bit instruction word."""
        self._emit('raw', (word,))

    # === PSEUDO-INSTRUCTIONS ===
    def NOP(self):             self.ADDI('x0', 'x0', 0)
    def MV(self, rd, rs1):     self.ADDI(rd, rs1, 0)
    def NOT(self, rd, rs1):    self.XORI(rd, rs1, -1)
    def NEG(self, rd, rs1):    self.SUB(rd, 'x0', rs1)
    def J(self, label):        self.JAL('x0', label)
    def LI(self, rd, imm):
        """Load 32-bit immediate (LUI+ADDI if needed)."""
        imm = imm & 0xFFFFFFFF
        if imm == sext(imm & 0xFFF, 12) & 0xFFFFFFFF:
            self.ADDI(rd, 'x0', sext(imm & 0xFFF, 12))
        else:
            upper = imm >> 12
            lower = sext(imm & 0xFFF, 12)
            if lower < 0:
                upper = (upper + 1) & 0xFFFFF
            self.LUI(rd, upper)
            if (lower & 0xFFF) != 0:
                self.ADDI(rd, rd, lower)

    # === TOHOST helpers ===
    def PASS(self):
        """Write 1 to TOHOST — test passed."""
        self.LUI('x30', self.TOHOST_ADDR >> 12)
        self.ADDI('x31', 'x0', 1)
        self.SW('x31', 0, 'x30')
        self.label('_halt')
        self.J('_halt')

    def FAIL(self, test_num):
        """Write test_num to TOHOST — test failed."""
        Program._fail_cnt += 1
        halt_lbl = f'_halt_fail_{Program._fail_cnt}'
        self.LUI('x30', self.TOHOST_ADDR >> 12)
        self.ADDI('x31', 'x0', test_num)
        self.SW('x31', 0, 'x30')
        self.label(halt_lbl)
        self.J(halt_lbl)

    # === TEST MACRO ===
    def CHECK(self, test_num, rd, expected_reg, fail_label):
        """Branch to fail_label if rd != expected_reg. Sets gp=test_num."""
        self.ADDI('x3', 'x0', test_num)
        self.BNE(rd, expected_reg, fail_label)

    # --- Assembler ---
    def assemble(self):
        """Two-pass assembly. Returns list of 32-bit words."""
        # Pass 1: assign addresses, collect labels
        labels = {}
        addr = 0
        for lbl, fn, args in self.ops:
            if lbl is not None:
                labels[lbl] = addr
            if fn is not None:
                if fn in ('c16', 'cb', 'cj'):
                    addr += 2
                elif fn == 'align4':
                    if addr % 4 != 0:
                        addr += 2  # C.NOP padding
                elif fn == 'li_pseudo':
                    addr += args  # pre-calculated size
                else:
                    addr += 4

        # Pass 2: encode into (addr, value, size) entries
        entries = []
        addr = 0
        for lbl, fn, args in self.ops:
            if fn is None:
                continue
            if fn == 'r':
                funct7, rs2, rs1, funct3, rd, opcode = args
                entries.append((addr, encode_r(funct7, rs2, rs1, funct3, rd, opcode), 4))
            elif fn == 'i':
                imm, rs1, funct3, rd, opcode = args
                entries.append((addr, encode_i(imm, rs1, funct3, rd, opcode), 4))
            elif fn == 's':
                imm, rs2, rs1, funct3, opcode = args
                entries.append((addr, encode_s(imm, rs2, rs1, funct3, opcode), 4))
            elif fn == 'b':
                target_label, rs2, rs1, funct3, opcode = args
                target = labels[target_label]
                offset = target - addr
                entries.append((addr, encode_b(offset, rs2, rs1, funct3, opcode), 4))
            elif fn == 'u':
                imm, rd, opcode = args
                entries.append((addr, encode_u(imm, rd, opcode), 4))
            elif fn == 'raw':
                entries.append((addr, args[0] & 0xFFFFFFFF, 4))
            elif fn == 'j':
                target_label, rd, opcode = args
                target = labels[target_label]
                offset = target - addr
                entries.append((addr, encode_j(offset, rd, opcode), 4))
            elif fn == 'c16':
                entries.append((addr, args & 0xFFFF, 2))
            elif fn == 'cb':
                target_label, encode_func = args
                target = labels[target_label]
                offset = target - addr
                entries.append((addr, encode_func(offset) & 0xFFFF, 2))
            elif fn == 'cj':
                target_label, encode_func = args
                target = labels[target_label]
                offset = target - addr
                entries.append((addr, encode_func(offset) & 0xFFFF, 2))
            elif fn == 'align4':
                if addr % 4 != 0:
                    entries.append((addr, 0x0001, 2))  # C.NOP
                    addr += 2
                continue
            if fn in ('c16', 'cb', 'cj'):
                addr += 2
            elif fn == 'li_pseudo':
                addr += args
            else:
                addr += 4

        # Pack into 32-bit words (little-endian halfword ordering)
        total_bytes = addr
        total_words = (total_bytes + 3) // 4
        words = [0] * total_words
        for a, val, size in entries:
            if size == 2:
                word_idx = a // 4
                if a % 4 == 0:
                    words[word_idx] = (words[word_idx] & 0xFFFF0000) | (val & 0xFFFF)
                else:
                    words[word_idx] = (words[word_idx] & 0x0000FFFF) | ((val & 0xFFFF) << 16)
            else:  # size == 4
                word_idx = a // 4
                if a % 4 == 0:
                    words[word_idx] = val
                else:
                    # 32-bit instruction at halfword boundary (spanning two words)
                    words[word_idx] = (words[word_idx] & 0x0000FFFF) | ((val & 0xFFFF) << 16)
                    if word_idx + 1 < total_words:
                        words[word_idx + 1] = (words[word_idx + 1] & 0xFFFF0000) | ((val >> 16) & 0xFFFF)
                    else:
                        words.append((val >> 16) & 0xFFFF)
        return words

    def write_hex(self, filename):
        """Write assembled program as hex file for $readmemh."""
        words = self.assemble()
        with open(filename, 'w') as f:
            for w in words:
                f.write(f'{w & 0xFFFFFFFF:08x}\n')
        return len(words)

    def disasm_hex(self):
        """Return hex dump with addresses for debugging."""
        words = self.assemble()
        lines = []
        for i, w in enumerate(words):
            lines.append(f'  {i*4:04x}: {w & 0xFFFFFFFF:08x}')
        return '\n'.join(lines)


if __name__ == '__main__':
    # Quick self-test: encode ADDI x1, x0, 42 and verify
    p = Program()
    p.ADDI('x1', 'x0', 42)
    words = p.assemble()
    assert words[0] == 0x02a00093, f"Expected 0x02a00093, got {words[0]:08x}"
    # LUI x1, 0xDEADB
    p2 = Program()
    p2.LUI('x1', 0xDEADB)
    w2 = p2.assemble()
    assert w2[0] == 0xDEADB0B7, f"Expected 0xDEADB0B7, got {w2[0]:08x}"
    print("Assembler self-test PASSED")
